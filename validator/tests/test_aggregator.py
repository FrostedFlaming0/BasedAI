"""Tests for the signature aggregator core (chain-agnostic; stake + submission injected)."""

from basedai_validator.aggregator import CanonicalCandidatePool, CommitmentAggregator
from basedai_validator.commitment import sign_commitment
from eth_account import Account

SCORING = "0x" + "ab" * 20
CHAIN_ID = 57073
ROOT_A = "0x" + "11" * 32
ROOT_B = "0x" + "22" * 32


def _agg(stakes: dict[str, int], total: int, proposals: list):
    return CommitmentAggregator(
        chain_id=CHAIN_ID,
        scoring_registry=SCORING,
        stake_of=lambda _b, a: stakes.get(a.lower(), 0),
        total_stake=lambda _b: total,
        propose_fn=lambda e, b, r, s, sg: proposals.append((e, b, r, s, sg)) or "0xdeadbeef",
    )


def test_add_commitment_rejects_forged_signature():
    a = Account.create()
    b = Account.create()
    agg = _agg({}, 0, [])
    sig = sign_commitment(a, CHAIN_ID, SCORING, 1, 8, ROOT_A)
    # Claiming the signature belongs to b (it is really a's) must be rejected.
    assert agg.add_commitment(1, 8, ROOT_A, b.address, sig) is False
    # Honest claim is accepted.
    assert agg.add_commitment(1, 8, ROOT_A, a.address, sig) is True


def test_quorum_requires_majority_stake():
    a = Account.create()
    stakes = {a.address.lower(): 4000}
    proposals: list = []
    agg = _agg(stakes, total=10_000, proposals=proposals)
    agg.add_commitment(1, 8, ROOT_A, a.address, sign_commitment(a, CHAIN_ID, SCORING, 1, 8, ROOT_A))
    # 4000 / 10000 = 40% < 50.01% -> no quorum, no proposal.
    assert agg.quorum_met(1, 8, ROOT_A) is False
    assert agg.try_propose(1, 8) is None
    assert proposals == []


def test_quorum_met_triggers_proposal_with_sorted_signers():
    a = Account.create()
    b = Account.create()
    stakes = {a.address.lower(): 3000, b.address.lower(): 3000}
    proposals: list = []
    agg = _agg(stakes, total=10_000, proposals=proposals)
    agg.add_commitment(5, 8, ROOT_A, a.address, sign_commitment(a, CHAIN_ID, SCORING, 5, 8, ROOT_A))
    agg.add_commitment(5, 8, ROOT_A, b.address, sign_commitment(b, CHAIN_ID, SCORING, 5, 8, ROOT_A))
    # 6000 / 10000 = 60% > 50.01% -> quorum.
    assert agg.quorum_met(5, 8, ROOT_A) is True
    tx = agg.try_propose(5, 8)
    assert tx == "0xdeadbeef"
    assert len(proposals) == 1
    epoch, brain_id, root, signers, sigs = proposals[0]
    assert brain_id == 8
    assert epoch == 5
    assert root == bytes.fromhex(ROOT_A[2:])
    # Signers strictly ascending by address integer (proposeEpoch requirement).
    assert signers == sorted(signers, key=lambda x: int(x, 16))
    assert len(sigs) == 2


def test_best_root_picks_higher_stake():
    a = Account.create()  # backs ROOT_A
    b = Account.create()  # backs ROOT_B
    stakes = {a.address.lower(): 2000, b.address.lower(): 6000}
    proposals: list = []
    agg = _agg(stakes, total=10_000, proposals=proposals)
    agg.add_commitment(9, 8, ROOT_A, a.address, sign_commitment(a, CHAIN_ID, SCORING, 9, 8, ROOT_A))
    agg.add_commitment(9, 8, ROOT_B, b.address, sign_commitment(b, CHAIN_ID, SCORING, 9, 8, ROOT_B))
    # ROOT_B has more stake and clears quorum on its own.
    assert agg.best_root(9, 8) == ROOT_B.lower()
    agg.try_propose(9, 8)
    assert proposals[0][2] == bytes.fromhex(ROOT_B[2:])


def test_no_double_propose():
    a = Account.create()
    stakes = {a.address.lower(): 9000}
    proposals: list = []
    agg = _agg(stakes, total=10_000, proposals=proposals)
    agg.add_commitment(3, 8, ROOT_A, a.address, sign_commitment(a, CHAIN_ID, SCORING, 3, 8, ROOT_A))
    assert agg.try_propose(3, 8) == "0xdeadbeef"
    assert agg.try_propose(3, 8) is None  # already proposed
    assert len(proposals) == 1


def test_candidate_pool_freezes_stake_weighted_median_root():
    a, b = Account.create(), Account.create()
    stakes = {a.address.lower(): 3000, b.address.lower(): 3000}
    pool = CanonicalCandidatePool(
        lambda _brain, signer: stakes.get(signer.lower(), 0),
        lambda _brain: 10_000,
    )
    miner = Account.create().address
    assert pool.add(4, 8, a.address, [{"miner": miner, "score": 100}]) is None
    frozen = pool.add(4, 8, b.address, [{"miner": miner, "score": 300}])
    assert frozen is not None
    root, rows = frozen
    assert root.startswith("0x") and len(root) == 66
    assert rows == [{"miner": miner, "score": 100}]
    # Frozen means a later conflicting candidate cannot move the canonical root.
    assert pool.add(4, 8, Account.create().address, [{"miner": miner, "score": 999}]) == frozen
