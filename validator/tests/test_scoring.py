"""Tests for the scoring algorithm."""

from basedai_validator.scoring import MinerObservation, score_miners


def test_score_miners_handles_empty():
    assert score_miners([]) == []


def test_consistent_miner_scores_higher():
    obs = []
    # Three miners; miner_a always agrees with the modal answer; miner_c diverges.
    for prompt_id in ["p1", "p2", "p3"]:
        obs.extend([
            MinerObservation("a", prompt_id, "0xagree", "yes", 100, True, None),
            MinerObservation("b", prompt_id, "0xagree", "yes", 100, True, None),
            MinerObservation("c", prompt_id, "0xdisagree", "no", 100, True, None),
        ])

    scores = score_miners(obs)
    by_name = {s.miner: s for s in scores}

    assert by_name["a"].score_fp > by_name["c"].score_fp
    assert by_name["a"].components["consistency"] == 1.0
    assert by_name["c"].components["consistency"] == 0.0


def test_quality_uses_jaccard():
    obs = [
        MinerObservation("a", "p1", "0xa", "the quick brown fox", 100, False, "the quick brown fox"),
        MinerObservation("b", "p1", "0xb", "completely unrelated text", 100, False, "the quick brown fox"),
    ]
    scores = score_miners(obs)
    by_name = {s.miner: s for s in scores}
    assert by_name["a"].components["quality"] == 1.0
    assert by_name["b"].components["quality"] < 0.2


def test_score_fixed_point_in_range():
    obs = [MinerObservation("a", "p1", "0xa", "x", 100, True, None)]
    scores = score_miners(obs)
    assert 0 <= scores[0].score_fp <= 1_000_000
