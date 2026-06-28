"""Tests for the miner HTTP transport (route wrapping + announce signing)."""

import json

from aiohttp.test_utils import TestClient, TestServer
from basedai_miner.http_server import _announce_digest, make_miner_app, sign_announce
from eth_account import Account
from eth_account.messages import encode_defunct


async def test_routes_wrap_handlers():
    async def infer(body: bytes) -> bytes:
        data = json.loads(body)
        return json.dumps({"echo": data["prompt"]}).encode()

    async def challenge(body: bytes) -> bytes:
        return json.dumps({"text": "PING"}).encode()

    async def settle(body: bytes) -> bytes:
        return json.dumps({"ok": True}).encode()

    app = make_miner_app(infer, challenge, settle)
    client = TestClient(TestServer(app))
    await client.start_server()
    try:
        r = await client.post("/infer", json={"prompt": "hi"})
        assert (await r.json())["echo"] == "hi"
        r = await client.post("/challenge", json={})
        assert (await r.json())["text"] == "PING"
        r = await client.post("/settle", json={})
        assert (await r.json())["ok"] is True
        r = await client.get("/health")
        assert (await r.json())["ok"] is True
    finally:
        await client.close()


def test_announce_signature_recovers_signer():
    acct = Account.create()
    url = "https://miner.example:8801"
    ts = 1_700_000_000
    sig = sign_announce(acct, 1, url, ts)
    recovered = Account.recover_message(
        encode_defunct(primitive=_announce_digest(1, url, ts)), signature=sig
    )
    assert recovered.lower() == acct.address.lower()
