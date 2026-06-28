"""HTTP aggregator service — the deployed endpoint validators POST signed commitments to.

`aggregator.py` provides the chain-agnostic `CommitmentAggregator`; this module wraps it in an
aiohttp app exposing the `POST /commitments` route the validator runtime dials (see
`runtime._submit_commitment`). Once co-signing stake crosses quorum, the aggregator assembles the
sorted signer set and submits `proposeEpoch` on-chain.

    POST /commitments   {epoch, brain_id, root, signer, signature}  -> {ok, proposed_tx?}
    GET  /health        -> {ok: true}

`make_aggregator_app(...)` keeps the app testable: the aggregator's
stake lookups and submission are injected, and `current_epoch_fn` (optional) gates submission to
COMPLETED epochs so the service never spends a tx the contract will reject.
"""

from __future__ import annotations

from typing import Callable, Optional

import structlog
from aiohttp import web

from .aggregator import CanonicalCandidatePool, CommitmentAggregator
from .commitment import recover_commitment_signer
from .merkle import ScoreLeaf, build_merkle_root

log = structlog.get_logger()

# Bound the commitment body; signatures + a root are well under this.
MAX_BODY_BYTES = 64 * 1024


def make_aggregator_app(
    aggregator: CommitmentAggregator,
    candidates: Optional[CanonicalCandidatePool] = None,
    current_epoch_fn: Optional[Callable[[], int]] = None,
    max_body_bytes: int = MAX_BODY_BYTES,
) -> web.Application:
    async def submit_candidate(request: web.Request) -> web.Response:
        if candidates is None:
            return web.json_response({"error": "candidate aggregation not configured"}, status=503)
        try:
            body = await request.json()
            epoch = int(body["epoch"])
            brain_id = int(body["brain_id"])
            signer = str(body["signer"])
            scores = list(body["scores"])
            signature = str(body["signature"])
            own_root, _ = build_merkle_root(
                [ScoreLeaf(brain_id, str(r["miner"]), int(r["score"])) for r in scores]
            )
            recovered = recover_commitment_signer(
                aggregator.chain_id, aggregator.scoring_registry, epoch, brain_id, own_root, signature
            )
            if recovered.lower() != signer.lower():
                return web.json_response({"error": "candidate signature mismatch"}, status=401)
            frozen = candidates.add(epoch, brain_id, signer, scores)
        except (KeyError, ValueError, TypeError):
            return web.json_response({"error": "malformed candidate"}, status=400)
        response = {"ok": True, "canonical": frozen is not None}
        if frozen is not None:
            response["root"], response["scores"] = frozen
        return web.json_response(response)

    async def get_candidate(request: web.Request) -> web.Response:
        if candidates is None:
            return web.json_response({"error": "candidate aggregation not configured"}, status=503)
        frozen = candidates.get(int(request.match_info["epoch"]), int(request.match_info["brain_id"]))
        if frozen is None:
            return web.json_response({"canonical": False}, status=202)
        return web.json_response({"canonical": True, "root": frozen[0], "scores": frozen[1]})

    async def commitments(request: web.Request) -> web.Response:
        try:
            body = await request.json()
            epoch = int(body["epoch"])
            brain_id = int(body["brain_id"])
            root = str(body["root"])
            signer = str(body["signer"])
            signature = str(body["signature"])
        except (KeyError, ValueError, TypeError):
            return web.json_response({"error": "malformed commitment"}, status=400)

        # Verify-and-store. A forged/mismatched signature is rejected at the aggregator.
        if not aggregator.add_commitment(epoch, brain_id, root, signer, signature):
            return web.json_response({"error": "signature does not match signer"}, status=401)

        # Only attempt to propose a COMPLETED epoch (the contract rejects the in-progress one).
        proposed_tx = None
        if current_epoch_fn is None or epoch < current_epoch_fn():
            try:
                proposed_tx = aggregator.try_propose(epoch, brain_id)
            except Exception as e:  # a failed on-chain submit must not 500 the validator's POST
                log.warning("aggregator.propose_failed", epoch=epoch, error=str(e))

        resp = {"ok": True, "quorum_met": aggregator.quorum_met(epoch, brain_id, root)}
        if proposed_tx:
            resp["proposed_tx"] = proposed_tx
        return web.json_response(resp)

    async def health(_: web.Request) -> web.Response:
        return web.json_response({"ok": True})

    app = web.Application(client_max_size=max_body_bytes)
    app.router.add_post("/commitments", commitments)
    app.router.add_post("/candidates", submit_candidate)
    app.router.add_get("/candidates/{epoch}/{brain_id}", get_candidate)
    app.router.add_get("/health", health)
    return app
