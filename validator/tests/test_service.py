"""Tests for the aggregator HTTP service (the deployed /commitments endpoint)."""

from aiohttp.test_utils import TestClient, TestServer
from basedai_validator.aggregator import CommitmentAggregator
from basedai_validator.commitment import sign_commitment
from basedai_validator.service import make_aggregator_app
from eth_account import Account

SCORING = "0x" + "ab" * 20
CHAIN_ID = 57073
ROOT_A = "0x" + "11" * 32


def _agg(stakes, total, proposals):
    return CommitmentAggregator(
        chain_id=CHAIN_ID,
        scoring_registry=SCORING,
        stake_of=lambda _b, a: stakes.get(a.lower(), 0),
        total_stake=lambda _b: total,
        propose_fn=lambda e, b, r, s, sg: proposals.append((e, b, r, s, sg)) or "0xfeed",
    )


async def _client(app):
    client = TestClient(TestServer(app))
    await client.start_server()
    return client


async def test_commitments_endpoint_accepts_and_proposes_on_quorum():
    a = Account.create()
    proposals: list = []
    agg = _agg({a.address.lower(): 9000}, total=10_000, proposals=proposals)
    # current_epoch_fn=10 so epoch 5 is a COMPLETED epoch and may be proposed.
    client = await _client(make_aggregator_app(agg, current_epoch_fn=lambda: 10))
    try:
        sig = sign_commitment(a, CHAIN_ID, SCORING, 5, 1, ROOT_A)
        body = {"epoch": 5, "brain_id": 1, "root": ROOT_A, "signer": a.address, "signature": sig}
        r = await client.post("/commitments", json=body)
        data = await r.json()
        assert r.status == 200 and data["ok"] is True and data["quorum_met"] is True
        assert data.get("proposed_tx") == "0xfeed"
        assert len(proposals) == 1 and proposals[0][0] == 5
    finally:
        await client.close()


async def test_commitments_endpoint_rejects_forged_signature():
    a = Account.create()
    b = Account.create()
    agg = _agg({}, 0, [])
    client = await _client(make_aggregator_app(agg))
    try:
        sig = sign_commitment(a, CHAIN_ID, SCORING, 1, 1, ROOT_A)  # really a's signature
        body = {"epoch": 1, "brain_id": 1, "root": ROOT_A, "signer": b.address, "signature": sig}
        r = await client.post("/commitments", json=body)
        assert r.status == 401
    finally:
        await client.close()


async def test_commitments_endpoint_does_not_propose_incomplete_epoch():
    a = Account.create()
    proposals: list = []
    agg = _agg({a.address.lower(): 9000}, total=10_000, proposals=proposals)
    # current epoch is 5; committing epoch 5 (still in progress) must NOT submit on-chain.
    client = await _client(make_aggregator_app(agg, current_epoch_fn=lambda: 5))
    try:
        sig = sign_commitment(a, CHAIN_ID, SCORING, 5, 1, ROOT_A)
        body = {"epoch": 5, "brain_id": 1, "root": ROOT_A, "signer": a.address, "signature": sig}
        r = await client.post("/commitments", json=body)
        data = await r.json()
        assert r.status == 200 and "proposed_tx" not in data
        assert proposals == []
    finally:
        await client.close()


async def test_health():
    agg = _agg({}, 0, [])
    client = await _client(make_aggregator_app(agg))
    try:
        r = await client.get("/health")
        assert (await r.json())["ok"] is True
    finally:
        await client.close()
