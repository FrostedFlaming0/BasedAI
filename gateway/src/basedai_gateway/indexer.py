"""Membership + endpoint index for a Brain network.

Tracks miner/validator membership derived from on-chain registry events, joined with the HTTP
endpoints miners announce off-chain. The core is event-sourced and chain-agnostic (events are
applied as plain records), so it is fully unit-testable; `server.ChainPoller` feeds it real logs.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Optional


class MemberIndex:
    """Per-Brain miner/validator sets + announced miner endpoints."""

    def __init__(self, endpoint_ttl_seconds: int = 600):
        self._miners: dict[int, set[str]] = defaultdict(set)
        self._validators: dict[int, set[str]] = defaultdict(set)
        # (brain_id, address_lower) -> {"url", "score", "ts"}
        self._endpoints: dict[tuple[int, str], dict] = {}
        self._ttl = endpoint_ttl_seconds

    # --- membership (from registry events) ---

    def replace_membership(self, events: list[dict]) -> None:
        """Atomically rebuild canonical membership after restart or reorg."""
        self._miners.clear()
        self._validators.clear()
        for event in events:
            self.apply_event(event["name"], int(event["brain_id"]), event["address"])

    def apply_event(self, name: str, brain_id: int, address: str) -> None:
        addr = address.lower()
        if name == "MinerRegistered":
            self._miners[brain_id].add(addr)
        elif name == "MinerDeregistered":
            self._miners[brain_id].discard(addr)
            self._endpoints.pop((brain_id, addr), None)
        elif name == "ValidatorRegistered":
            self._validators[brain_id].add(addr)
        elif name == "ValidatorDeregistered":
            self._validators[brain_id].discard(addr)

    def is_miner(self, brain_id: int, address: str) -> bool:
        return address.lower() in self._miners.get(brain_id, set())

    def is_validator(self, brain_id: int, address: str) -> bool:
        return address.lower() in self._validators.get(brain_id, set())

    # --- announced endpoints ---

    def announce(self, brain_id: int, address: str, url: str, ts: int, score: float = 0.0) -> None:
        """Record a verified endpoint announcement. Caller MUST have verified the signature and
        on-chain membership first."""
        self._endpoints[(brain_id, address.lower())] = {"url": url, "score": float(score), "ts": int(ts)}

    def set_score(self, brain_id: int, address: str, score: float) -> None:
        ep = self._endpoints.get((brain_id, address.lower()))
        if ep is not None:
            ep["score"] = float(score)

    def miners(self, brain_id: int, now: Optional[int] = None) -> list[dict]:
        """Reachable miners: registered on-chain AND announcing a fresh endpoint."""
        out = []
        for addr in self._miners.get(brain_id, set()):
            ep = self._endpoints.get((brain_id, addr))
            if ep is None:
                continue
            if now is not None and self._ttl and now - ep["ts"] > self._ttl:
                continue  # stale announcement; miner is presumed offline
            out.append({"address": addr, "url": ep["url"], "score": ep["score"]})
        # Highest score first so clients' max-by-score pick is stable/cheap.
        out.sort(key=lambda m: m["score"], reverse=True)
        return out

    def endpoint_of(self, brain_id: int, address: str) -> Optional[str]:
        ep = self._endpoints.get((brain_id, address.lower()))
        return ep["url"] if ep else None
