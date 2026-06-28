"""Route tests for the gateway HTTP app (injected proxy + index; no live chain or miners)."""

from aiohttp.test_utils import TestClient, TestServer
from basedai_gateway.announce import sign_announce
from basedai_gateway.indexer import MemberIndex
from basedai_gateway.server import make_app
from eth_account import Account

BRAIN = 1


# The transport tests dial the RFC-reserved host `miner.example` (which does not resolve), so they
# opt out of the SSRF resolver with a permissive guard; the SSRF behavior is covered separately below.
_ALLOW_ALL = lambda url: None  # noqa: E731


async def _client(index, proxy=None, url_guard=_ALLOW_ALL, **kw):
    app = make_app(index, proxy=proxy, now_fn=lambda: 1000, url_guard=url_guard, **kw)
    client = TestClient(TestServer(app))
    await client.start_server()
    return client


async def test_announce_requires_registration_and_valid_sig():
    idx = MemberIndex()
    acct = Account.create()
    client = await _client(idx)
    try:
        url = "https://miner.example"
        sig = sign_announce(acct, BRAIN, url, 1000)
        body = {"address": acct.address, "url": url, "ts": 1000, "signature": sig}

        # Not registered on-chain yet -> 403.
        r = await client.post(f"/brains/{BRAIN}/announce", json=body)
        assert r.status == 403

        # Register, then announce succeeds and shows up in /miners.
        idx.apply_event("MinerRegistered", BRAIN, acct.address)
        r = await client.post(f"/brains/{BRAIN}/announce", json=body)
        assert r.status == 200
        r = await client.get(f"/brains/{BRAIN}/miners")
        miners = await r.json()
        assert len(miners) == 1 and miners[0]["url"] == url
    finally:
        await client.close()


async def test_announce_rejects_forged_signature():
    idx = MemberIndex()
    acct = Account.create()
    other = Account.create()
    idx.apply_event("MinerRegistered", BRAIN, acct.address)
    client = await _client(idx)
    try:
        url = "https://miner.example"
        sig = sign_announce(other, BRAIN, url, 1000)  # signed by the wrong key
        body = {"address": acct.address, "url": url, "ts": 1000, "signature": sig}
        r = await client.post(f"/brains/{BRAIN}/announce", json=body)
        assert r.status == 401
    finally:
        await client.close()


async def test_announce_rejects_stale_timestamp():
    idx = MemberIndex()
    acct = Account.create()
    idx.apply_event("MinerRegistered", BRAIN, acct.address)
    client = await _client(idx)
    try:
        url = "https://miner.example"
        sig = sign_announce(acct, BRAIN, url, 1)  # far in the past vs now=1000
        body = {"address": acct.address, "url": url, "ts": 1, "signature": sig}
        r = await client.post(f"/brains/{BRAIN}/announce", json=body)
        assert r.status == 400
    finally:
        await client.close()


async def test_infer_proxies_to_target_miner():
    idx = MemberIndex()
    acct = Account.create()
    idx.apply_event("MinerRegistered", BRAIN, acct.address)
    idx.announce(BRAIN, acct.address, "https://miner.example", ts=1000)

    seen = {}

    async def fake_proxy(url, path, body):
        seen["url"] = url
        seen["path"] = path
        return 200, {"text": "hello", "echo": body.get("prompt")}

    client = await _client(idx, proxy=fake_proxy)
    try:
        r = await client.post(
            f"/brains/{BRAIN}/infer",
            json={"prompt": "hi", "target_miner": acct.address},
        )
        data = await r.json()
        assert r.status == 200 and data["text"] == "hello" and data["echo"] == "hi"
        assert seen["url"] == "https://miner.example" and seen["path"] == "/infer"
    finally:
        await client.close()


async def test_infer_503_when_no_miners():
    idx = MemberIndex()
    client = await _client(idx)
    try:
        r = await client.post(f"/brains/{BRAIN}/infer", json={"prompt": "hi"})
        assert r.status == 503
    finally:
        await client.close()


async def test_default_url_guard_blocks_ssrf_targets():
    # The production default guard rejects loopback / private / cloud-metadata destinations.
    from basedai_gateway.server import _public_url_guard

    assert _public_url_guard("http://127.0.0.1:8801") is not None
    assert _public_url_guard("http://169.254.169.254/latest/meta-data/") is not None  # cloud metadata
    assert _public_url_guard("http://10.0.0.5") is not None
    assert _public_url_guard("http://192.168.1.10:9000") is not None
    assert _public_url_guard("ftp://example.com") is not None  # bad scheme
    assert _public_url_guard("https://93.184.216.34") is None  # a public IP literal is allowed


async def test_announce_with_strict_guard_rejects_private_url():
    idx = MemberIndex()
    acct = Account.create()
    idx.apply_event("MinerRegistered", BRAIN, acct.address)
    # Strict guard (production default): a registered miner announcing a loopback URL is rejected.
    client = await _client(idx, url_guard=None)
    try:
        url = "http://127.0.0.1:8801"
        sig = sign_announce(acct, BRAIN, url, 1000)
        body = {"address": acct.address, "url": url, "ts": 1000, "signature": sig}
        r = await client.post(f"/brains/{BRAIN}/announce", json=body)
        assert r.status == 400
    finally:
        await client.close()


async def test_submit_scores_populates_from_verified_root():
    idx = MemberIndex()
    acct = Account.create()
    idx.apply_event("MinerRegistered", BRAIN, acct.address)
    idx.announce(BRAIN, acct.address, "https://miner.example", ts=1000)

    # Injected verifier stands in for ScoringRegistry.verifyScore against the finalized root.
    def verify(epoch, brain_id, miner, score, proof):
        return epoch == 7 and score == 42 and miner.lower() == acct.address.lower()

    client = await _client(idx, verify_score=verify)
    try:
        r = await client.post(
            f"/brains/{BRAIN}/scores",
            json={
                "epoch": 7,
                "entries": [
                    {"miner": acct.address, "score": 42, "proof": []},  # verifies -> applied
                    {"miner": acct.address, "score": 999, "proof": []},  # fails verify -> ignored
                ],
            },
        )
        data = await r.json()
        assert r.status == 200 and data["applied"] == 1
        miners = await (await client.get(f"/brains/{BRAIN}/miners")).json()
        assert miners[0]["score"] == 42.0  # no longer the 0.0 default
    finally:
        await client.close()


async def test_submit_scores_503_when_scoring_not_configured():
    idx = MemberIndex()
    client = await _client(idx)  # no verify_score -> scoring disabled
    try:
        r = await client.post(f"/brains/{BRAIN}/scores", json={"epoch": 1, "entries": []})
        assert r.status == 503
    finally:
        await client.close()


async def test_rate_limit_returns_429_when_exceeded():
    idx = MemberIndex()
    client = await _client(idx, rate_limit=3, rate_window=60)
    try:
        statuses = [(await client.get(f"/brains/{BRAIN}/miners")).status for _ in range(5)]
        # First 3 allowed (200), the rest shed with 429.
        assert statuses[:3] == [200, 200, 200]
        assert 429 in statuses[3:]
    finally:
        await client.close()
