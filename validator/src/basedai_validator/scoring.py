"""Scoring algorithm for miners.

Each epoch a validator scores the miners on its Brain along three axes:

  1. Latency — log-time response speed, normalized.
  2. Quality — agreement of the miner's response with a held-out reference set.
  3. Consistency — for deterministic challenge prompts (temperature=0), the miner
     must produce the same output as a majority of other miners on the same prompt.

The score is a weighted combination, clamped to [0, 1] and stored as a fixed-point
integer (score * 1e6) so it can fit in a Merkle leaf without floating-point.
"""

from __future__ import annotations

import math
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Iterable

import numpy as np


@dataclass
class MinerObservation:
    miner: str
    prompt_id: str
    response_hash: str
    response_text: str
    latency_ms: int
    is_challenge: bool          # True if validator-generated deterministic prompt
    reference_text: str | None  # for quality scoring


@dataclass
class MinerScore:
    miner: str
    score_fp: int   # fixed-point: score * 1_000_000
    samples: int
    components: dict


def score_miners(observations: Iterable[MinerObservation]) -> list[MinerScore]:
    by_miner: dict[str, list[MinerObservation]] = defaultdict(list)
    for o in observations:
        by_miner[o.miner].append(o)

    # For challenge prompts, find the modal response_hash per prompt.
    challenge_groups: dict[str, list[str]] = defaultdict(list)
    for o in observations:
        if o.is_challenge:
            challenge_groups[o.prompt_id].append(o.response_hash)
    modal_response: dict[str, str] = {
        pid: Counter(hashes).most_common(1)[0][0]
        for pid, hashes in challenge_groups.items()
    }

    scores: list[MinerScore] = []
    all_latencies = [o.latency_ms for o in observations]
    if not all_latencies:
        return []
    p50 = float(np.percentile(all_latencies, 50))

    for miner, obs in by_miner.items():
        latency_score = _latency_score(obs, p50)
        quality_score = _quality_score(obs)
        consistency_score = _consistency_score(obs, modal_response)

        # Weights: 20% latency, 50% quality, 30% consistency.
        composite = (
            0.20 * latency_score
            + 0.50 * quality_score
            + 0.30 * consistency_score
        )
        composite = max(0.0, min(1.0, composite))

        scores.append(MinerScore(
            miner=miner,
            score_fp=int(composite * 1_000_000),
            samples=len(obs),
            components={
                "latency": latency_score,
                "quality": quality_score,
                "consistency": consistency_score,
            },
        ))

    scores.sort(key=lambda s: s.score_fp, reverse=True)
    return scores


def _latency_score(obs: list[MinerObservation], p50: float) -> float:
    if not obs:
        return 0.0
    miner_p50 = float(np.percentile([o.latency_ms for o in obs], 50))
    if miner_p50 <= 0:
        return 1.0
    # Score is 1 if at or below network median, decays log-linearly above.
    ratio = p50 / miner_p50
    return min(1.0, max(0.0, math.log(1 + ratio) / math.log(2)))


def _quality_score(obs: list[MinerObservation]) -> float:
    """Quality is overlap with a reference text on observations that include one.
    For v1 we use a simple normalized token-set Jaccard. Production would use
    embedding similarity or a reference model perplexity comparison."""
    samples = [o for o in obs if o.reference_text]
    if not samples:
        return 0.5  # no signal => neutral
    scores = []
    for s in samples:
        a = set(s.response_text.lower().split())
        b = set(s.reference_text.lower().split())
        if not (a or b):
            scores.append(0.0)
            continue
        scores.append(len(a & b) / len(a | b))
    return float(np.mean(scores))


def _consistency_score(obs: list[MinerObservation], modal: dict[str, str]) -> float:
    """For deterministic challenge prompts, fraction where the miner agrees with
    the network mode. Miners with no challenge samples score 0.5."""
    challenges = [o for o in obs if o.is_challenge]
    if not challenges:
        return 0.5
    agreement = sum(
        1 for o in challenges
        if modal.get(o.prompt_id) == o.response_hash
    )
    return agreement / len(challenges)
