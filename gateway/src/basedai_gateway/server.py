"""HTTP gateway/indexer: miner discovery + inference proxy for a Brain network.

Routes (matching the reference client's expectations):
    GET  /brains/{id}/miners    -> [{address, url, score}]  (registered + freshly announced)
    POST /brains/{id}/announce  -> a miner registers its reachable URL (signed)
    POST /brains/{id}/infer     -> proxied to the target miner's /infer
    POST /brains/{id}/settle    -> proxied to the target miner's /settle

`make_app` builds the aiohttp application around a `MemberIndex` and an injectable async proxy
(so routes are testable without live miners). `ChainPoller` keeps the index's membership current
from on-chain registry events.
"""

from __future__ import annotations

import ipaddress
import socket
import time
from collections import defaultdict
from typing import Awaitable, Callable, Optional
from urllib.parse import urlparse

import structlog
from aiohttp import web
from web3 import Web3

from .announce import recover_announce
from .indexer import MemberIndex

log = structlog.get_logger()

# Reject announcements whose timestamp is older/newer than this (clock-skew + replay guard).
ANNOUNCE_MAX_AGE = 600

# --- DoS bounds (defense in depth; tune per deployment) ---
# Max accepted request body; aiohttp returns 413 above this.
MAX_BODY_BYTES = 512 * 1024
# Max concurrent in-flight proxied inferences before shedding load with 503.
DEFAULT_MAX_INFLIGHT = 64
# Per-client-IP fixed-window rate limit.
DEFAULT_RATE_LIMIT = 240
RATE_WINDOW = 60

# Async proxy: (url, path, json_body) -> (status, json_response).
Proxy = Callable[[str, str, dict], Awaitable[tuple[int, dict]]]
# URL guard: returns None if the URL is safe to dial, or a string reason if it must be blocked.
UrlGuard = Callable[[str], Optional[str]]
# Verify a (epoch, brainId, miner, score, proof) leaf against the on-chain finalized Merkle root.
ScoreVerifier = Callable[[int, int, str, int, list], bool]


def _public_url_guard(url: str) -> Optional[str]:
    """SSRF guard: permit only http(s) URLs whose host resolves EXCLUSIVELY to public IPs. Blocks
    loopback, private, link-local (incl. the 169.254.169.254 cloud-metadata endpoint), multicast,
    reserved, and unspecified ranges. Returns None if allowed, else a reason string."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return "url scheme must be http or https"
    host = parsed.hostname
    if not host:
        return "url has no host"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        return "url host does not resolve"
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        ):
            return f"url resolves to non-public address {ip}"
    return None


async def _httpx_proxy(url: str, path: str, body: dict) -> tuple[int, dict]:
    import httpx

    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(f"{url.rstrip('/')}{path}", json=body)
        try:
            data = resp.json()
        except Exception:
            data = {"error": f"miner returned non-JSON ({resp.status_code})"}
        return resp.status_code, data


def make_app(
    index: MemberIndex,
    proxy: Optional[Proxy] = None,
    now_fn: Callable[[], int] = lambda: int(time.time()),
    url_guard: Optional[UrlGuard] = None,
    max_inflight: int = DEFAULT_MAX_INFLIGHT,
    rate_limit: int = DEFAULT_RATE_LIMIT,
    rate_window: int = RATE_WINDOW,
    max_body_bytes: int = MAX_BODY_BYTES,
    verify_score: Optional[ScoreVerifier] = None,
) -> web.Application:
    proxy = proxy or _httpx_proxy
    url_guard = url_guard if url_guard is not None else _public_url_guard

    # Per-IP fixed-window rate limiter (in-memory; sufficient for a single-process gateway).
    _hits: dict[str, list[int]] = defaultdict(lambda: [0, 0])  # ip -> [window_start, count]

    @web.middleware
    async def rate_limit_mw(request: web.Request, handler):
        ip = request.remote or "unknown"
        now = now_fn()
        win, count = _hits[ip]
        if now - win >= rate_window:
            _hits[ip] = [now, 1]
        else:
            if count >= rate_limit:
                return web.json_response({"error": "rate limit exceeded"}, status=429)
            _hits[ip][1] = count + 1
        return await handler(request)

    app = web.Application(client_max_size=max_body_bytes, middlewares=[rate_limit_mw])
    # Bounded concurrency for the outbound proxy (load shedding rather than unbounded fan-out).
    inflight = {"n": 0}

    async def list_miners(request: web.Request) -> web.Response:
        brain_id = int(request.match_info["id"])
        return web.json_response(index.miners(brain_id, now=now_fn()))

    async def announce(request: web.Request) -> web.Response:
        brain_id = int(request.match_info["id"])
        body = await request.json()
        try:
            address = Web3.to_checksum_address(body["address"])
            url = str(body["url"])
            ts = int(body["ts"])
            signature = body["signature"]
        except (KeyError, ValueError, TypeError):
            return web.json_response({"error": "malformed announce"}, status=400)

        now = now_fn()
        if abs(now - ts) > ANNOUNCE_MAX_AGE:
            return web.json_response({"error": "stale announce timestamp"}, status=400)
        guard_reason = url_guard(url)
        if guard_reason is not None:
            # SSRF defense: refuse to register a URL that targets a non-public destination.
            return web.json_response({"error": f"invalid url: {guard_reason}"}, status=400)

        try:
            recovered = recover_announce(brain_id, url, ts, signature)
        except Exception:
            return web.json_response({"error": "bad signature"}, status=400)
        if recovered.lower() != address.lower():
            return web.json_response({"error": "signature does not match address"}, status=401)
        if not index.is_miner(brain_id, address):
            return web.json_response({"error": "not a registered miner"}, status=403)

        index.announce(brain_id, address, url, ts)
        return web.json_response({"ok": True})

    async def _proxy_to_target(request: web.Request, path: str) -> web.Response:
        brain_id = int(request.match_info["id"])
        body = await request.json()
        target = body.get("target_miner")
        url = index.endpoint_of(brain_id, target) if target else None
        if url is None:
            miners = index.miners(brain_id, now=now_fn())
            if not miners:
                return web.json_response({"error": f"no miners available for brain {brain_id}"}, status=503)
            url = miners[0]["url"]  # best-scored

        # Re-validate at the dial site (defends DNS rebinding between announce and proxy).
        guard_reason = url_guard(url)
        if guard_reason is not None:
            return web.json_response({"error": f"miner url blocked: {guard_reason}"}, status=502)

        # Shed load rather than fan out unboundedly to miners.
        if inflight["n"] >= max_inflight:
            return web.json_response({"error": "gateway at capacity"}, status=503)
        inflight["n"] += 1
        try:
            status, data = await proxy(url, path, body)
        finally:
            inflight["n"] -= 1
        return web.json_response(data, status=status)

    async def infer(request: web.Request) -> web.Response:
        return await _proxy_to_target(request, "/infer")

    async def settle(request: web.Request) -> web.Response:
        return await _proxy_to_target(request, "/settle")

    async def submit_scores(request: web.Request) -> web.Response:
        """Populate miner scores from a FINALIZED epoch. Each (miner, score) leaf is verified against
        the on-chain finalized Merkle root (via `verify_score`) before it is trusted, so the gateway's
        ranking is sourced from finalized score roots rather than left at the 0.0 default."""
        if verify_score is None:
            return web.json_response({"error": "scoring not configured"}, status=503)
        brain_id = int(request.match_info["id"])
        body = await request.json()
        try:
            epoch = int(body["epoch"])
            entries = body["entries"]
        except (KeyError, ValueError, TypeError):
            return web.json_response({"error": "malformed scores"}, status=400)

        applied = 0
        for e in entries:
            try:
                miner = Web3.to_checksum_address(e["miner"])
                score = int(e["score"])
                proof = list(e.get("proof", []))
            except (KeyError, ValueError, TypeError):
                continue
            # Only trust a score that verifies against the finalized on-chain root.
            if verify_score(epoch, brain_id, miner, score, proof):
                index.set_score(brain_id, miner, float(score))
                applied += 1
        return web.json_response({"ok": True, "applied": applied})

    app.router.add_get("/brains/{id}/miners", list_miners)
    app.router.add_post("/brains/{id}/announce", announce)
    app.router.add_post("/brains/{id}/infer", infer)
    app.router.add_post("/brains/{id}/settle", settle)
    app.router.add_post("/brains/{id}/scores", submit_scores)
    return app


class ChainPoller:
    """Polls the SubnetRegistry for membership events and updates a MemberIndex."""

    _EVENTS = ["MinerRegistered", "MinerDeregistered", "ValidatorRegistered", "ValidatorDeregistered"]
    # Minimal event ABI (indexed brainId + member address) for log decoding.
    _ABI = [
        {"type": "event", "name": n, "anonymous": False, "inputs": [
            {"name": "brainId", "type": "uint256", "indexed": True},
            {"name": ("validator" if "Validator" in n else "miner"), "type": "address", "indexed": True},
        ]}
        for n in _EVENTS
    ]

    def __init__(
        self,
        index: MemberIndex,
        w3: Web3,
        subnet_registry: str,
        start_block: int = 0,
        confirmations: int = 2,
        cursor_store: "Optional[CursorStore]" = None,
        reorg_buffer: int = 12,
    ):
        self.index = index
        self.w3 = w3
        self.contract = w3.eth.contract(address=Web3.to_checksum_address(subnet_registry), abi=self._ABI)
        self._confirmations = confirmations
        self._reorg_buffer = reorg_buffer
        self._store = cursor_store
        # Resume from the durable cursor across restarts, so membership is never silently lost or
        # re-derived from block 0 on every boot.
        state = cursor_store.load_state() if cursor_store is not None else None
        self._events = list(state.get("events", [])) if state else []
        self._hashes = dict(state.get("hashes", {})) if state else {}
        self.index.replace_membership(self._events)
        self._next_block = int(state["next_block"]) if state else start_block

    def poll_once(self) -> int:
        """Scan new blocks for membership events. Returns the number of events applied. Scans only
        `confirmations`-deep blocks (shallow-reorg avoidance) and re-scans a `reorg_buffer` overlap so
        a reorg shallower than the buffer is re-applied from canonical logs; membership apply is
        idempotent (set add/discard), so re-scanning the overlap never double-counts state."""
        head = self.w3.eth.block_number - self._confirmations
        if head < self._next_block:
            return 0
        # Rewind and REBUILD that suffix. Merely re-applying canonical events cannot remove an
        # orphaned registration that disappeared from the replacement chain.
        from_block = max(0, self._next_block - self._reorg_buffer)
        # If the reorg crosses the normal buffer, walk stored block hashes backward to the common
        # ancestor and rebuild the entire divergent suffix instead of retaining orphaned state.
        probe = from_block - 1
        while probe >= 0 and str(probe) in self._hashes:
            canonical = Web3.to_hex(self.w3.eth.get_block(probe)["hash"])
            if canonical == self._hashes[str(probe)]:
                break
            probe -= 1
        if probe < from_block - 1:
            from_block = probe + 1
        canonical_hashes: dict[str, str] = {}
        for block_number in range(from_block, head + 1):
            block_hash = self.w3.eth.get_block(block_number)["hash"]
            canonical_hashes[str(block_number)] = Web3.to_hex(block_hash)

        self._events = [e for e in self._events if int(e["block_number"]) < from_block]
        applied_events: list[dict] = []
        for name in self._EVENTS:
            event = getattr(self.contract.events, name)
            for entry in event().get_logs(from_block=from_block, to_block=head):
                member = entry["args"].get("miner") or entry["args"].get("validator")
                applied_events.append({
                    "name": name,
                    "brain_id": int(entry["args"]["brainId"]),
                    "address": member,
                    "block_number": int(entry["blockNumber"]),
                    "log_index": int(entry.get("logIndex", 0)),
                })
        applied_events.sort(key=lambda e: (e["block_number"], e["log_index"]))
        self._events.extend(applied_events)
        self.index.replace_membership(self._events)
        self._hashes = {k: v for k, v in self._hashes.items() if int(k) < from_block}
        self._hashes.update(canonical_hashes)
        self._next_block = head + 1
        # Persist the cursor so a restart resumes here instead of rescanning from genesis.
        if self._store is not None:
            self._store.save_state(self._next_block, self._events, self._hashes)
        return len(applied_events)


class CursorStore:
    """Durable poller cursor backed by a JSON file. `load()` returns the saved next-block (or None
    on first run); `save(n)` persists it atomically so a gateway restart resumes where it left off."""

    def __init__(self, path: str):
        self.path = path

    def load(self) -> Optional[int]:
        import json
        import os

        if not os.path.exists(self.path):
            return None
        try:
            with open(self.path) as f:
                return int(json.load(f)["next_block"])
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def save(self, next_block: int) -> None:
        self.save_state(next_block, [], {})

    def load_state(self) -> Optional[dict]:
        import json
        import os

        if not os.path.exists(self.path):
            return None
        try:
            with open(self.path) as f:
                state = json.load(f)
            return {
                "next_block": int(state["next_block"]),
                "events": list(state.get("events", [])),
                "hashes": dict(state.get("hashes", {})),
            }
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def save_state(self, next_block: int, events: list[dict], hashes: dict[str, str]) -> None:
        import json
        import os

        tmp = f"{self.path}.tmp"
        with open(tmp, "w") as f:
            json.dump({"next_block": int(next_block), "events": events, "hashes": hashes}, f)
        os.replace(tmp, self.path)  # atomic on POSIX
