"""HTTP transport for the miner: exposes /infer, /challenge, /settle for the gateway to proxy to,
and announces the miner's reachable endpoint to the gateway.

This is the testnet transport. The libp2p path (p2p.py) remains the intended production gossip
layer; HTTP is a real, deployable alternative that needs no libp2p stack. The request/response
handlers are the SAME `bytes -> bytes` functions used by the p2p layer, so business logic is shared.
"""

from __future__ import annotations

import time
from typing import Awaitable, Callable

import httpx
import structlog
from aiohttp import web
from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak

log = structlog.get_logger()

Handler = Callable[[bytes], Awaitable[bytes]]

# Mirrors basedai_gateway.announce — keep the two signing conventions in lockstep.
_ANNOUNCE_DOMAIN = keccak(text="BasedAI:MinerAnnounce:v1")


def _announce_digest(brain_id: int, url: str, ts: int) -> bytes:
    return keccak(abi_encode(["bytes32", "uint256", "string", "uint256"], [_ANNOUNCE_DOMAIN, int(brain_id), url, int(ts)]))


def sign_announce(account: Account, brain_id: int, url: str, ts: int) -> str:
    sig = account.sign_message(encode_defunct(primitive=_announce_digest(brain_id, url, ts))).signature
    return sig.hex() if isinstance(sig, (bytes, bytearray)) else sig


def make_miner_app(infer: Handler, challenge: Handler, settle: Handler) -> web.Application:
    """Build the miner's HTTP app from the three bytes->bytes handlers."""

    def _route(handler: Handler):
        async def _h(request: web.Request) -> web.Response:
            body = await request.read()
            result = await handler(body)
            return web.Response(body=result, content_type="application/json")

        return _h

    async def _health(_request: web.Request) -> web.Response:
        return web.json_response({"ok": True})

    app = web.Application()
    app.router.add_post("/infer", _route(infer))
    app.router.add_post("/challenge", _route(challenge))
    app.router.add_post("/settle", _route(settle))
    app.router.add_get("/health", _health)
    return app


async def announce_once(account: Account, gateway_url: str, brain_id: int, public_url: str) -> bool:
    """Announce this miner's reachable URL to the gateway (signed). Returns True on success."""
    ts = int(time.time())
    sig = sign_announce(account, brain_id, public_url, ts)
    if not sig.startswith("0x"):
        sig = "0x" + sig
    payload = {"address": account.address, "url": public_url, "ts": ts, "signature": sig}
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(f"{gateway_url.rstrip('/')}/brains/{brain_id}/announce", json=payload)
            resp.raise_for_status()
        return True
    except Exception as e:
        log.warning("miner.announce_failed", error=str(e))
        return False
