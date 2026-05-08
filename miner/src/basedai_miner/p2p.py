"""libp2p coordination layer for miners.

Each Brain has its own gossip topic. Miners subscribe to their Brain's topic and accept
direct request/response streams from users and validators.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import asdict
from typing import Awaitable, Callable, Optional

import structlog

log = structlog.get_logger()

# We import lazily so the module is loadable in environments without py-libp2p.
PROTOCOL_INFER = "/basedai/infer/1.0.0"
PROTOCOL_CHALLENGE = "/basedai/challenge/1.0.0"


class P2PNode:
    """Wraps a libp2p host. Handles peer discovery, gossip, and request/response."""

    def __init__(
        self,
        listen_addrs: list[str],
        bootstrap_peers: list[str],
        topic: str,
    ):
        self.listen_addrs = listen_addrs
        self.bootstrap_peers = bootstrap_peers
        self.topic = topic
        self._host = None
        self._handlers: dict[str, Callable] = {}

    async def start(self) -> None:
        """Bring the host online and dial bootstrap peers."""
        try:
            from libp2p import new_host
            from libp2p.peer.peerinfo import info_from_p2p_addr
            from multiaddr import Multiaddr
        except ImportError:
            log.warning("libp2p.unavailable", running="stub mode")
            return

        self._host = new_host()
        await self._host.get_network().listen(*[Multiaddr(a) for a in self.listen_addrs])
        for addr in self.bootstrap_peers:
            try:
                info = info_from_p2p_addr(Multiaddr(addr))
                await self._host.connect(info)
            except Exception as e:
                log.warning("p2p.bootstrap_failed", peer=addr, error=str(e))

        log.info("p2p.started", peer_id=str(self._host.get_id()), topic=self.topic)

    def on_request(self, protocol: str, handler: Callable[[bytes], Awaitable[bytes]]) -> None:
        """Register a handler for incoming streams of a given protocol."""
        self._handlers[protocol] = handler
        if self._host is not None:
            self._host.set_stream_handler(protocol, self._wrap_handler(handler))

    def _wrap_handler(self, handler):
        async def _stream_handler(stream):
            try:
                data = await stream.read()
                result = await handler(data)
                await stream.write(result)
            finally:
                await stream.close()
        return _stream_handler

    async def gossip(self, message: dict) -> None:
        """Publish a message to the Brain's gossip topic."""
        if self._host is None:
            log.debug("p2p.gossip_stub", topic=self.topic, message=message)
            return
        # GossipSub publish (omitted for brevity; see py-libp2p pubsub API).

    async def stop(self) -> None:
        if self._host is not None:
            await self._host.close()
