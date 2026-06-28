"""CLI for the BasedAI gateway/indexer."""

from __future__ import annotations

import asyncio
import re

import click
import structlog
from aiohttp import web
from web3 import Web3

from .indexer import MemberIndex
from .server import ChainPoller, CursorStore, make_app

log = structlog.get_logger()

_ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


@click.command()
@click.option("--rpc-url", envvar="GATEWAY_RPC_URL", required=True)
@click.option("--subnet-registry", envvar="GATEWAY_SUBNET_REGISTRY", required=True)
@click.option("--scoring-registry", envvar="GATEWAY_SCORING_REGISTRY", required=True)
@click.option("--cursor-file", envvar="GATEWAY_CURSOR_FILE", default="gateway-cursor.json")
@click.option("--host", default="0.0.0.0")
@click.option("--port", default=8800, type=int)
@click.option("--start-block", default=0, type=int, help="Block to begin indexing membership from.")
@click.option("--poll-interval", default=12.0, type=float)
@click.option("--endpoint-ttl", default=600, type=int, help="Seconds an announced endpoint stays fresh.")
def main(rpc_url: str, subnet_registry: str, scoring_registry: str, cursor_file: str, host: str, port: int, start_block: int, poll_interval: float, endpoint_ttl: int) -> None:
    structlog.configure(processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ])
    if not _ADDR_RE.match(subnet_registry) or not _ADDR_RE.match(scoring_registry):
        raise click.BadParameter("registry addresses must be 0x addresses")
    if not (rpc_url.startswith("https://") or rpc_url.startswith("http://localhost") or rpc_url.startswith("http://127.")):
        raise click.BadParameter("rpc-url must be https:// (or localhost)")

    w3 = Web3(Web3.HTTPProvider(rpc_url))
    index = MemberIndex(endpoint_ttl_seconds=endpoint_ttl)
    poller = ChainPoller(
        index, w3, subnet_registry, start_block=start_block, cursor_store=CursorStore(cursor_file)
    )
    scoring = w3.eth.contract(
        address=Web3.to_checksum_address(scoring_registry),
        abi=[{
            "name": "verifyScore", "type": "function", "stateMutability": "view",
            "inputs": [
                {"name": "epoch", "type": "uint64"}, {"name": "brainId", "type": "uint256"},
                {"name": "miner", "type": "address"}, {"name": "score", "type": "uint256"},
                {"name": "proof", "type": "bytes32[]"},
            ], "outputs": [{"type": "bool"}],
        }],
    )

    def verify_score(epoch: int, brain_id: int, miner: str, score: int, proof: list) -> bool:
        return bool(scoring.functions.verifyScore(epoch, brain_id, miner, score, proof).call())

    app = make_app(index, verify_score=verify_score)

    async def _poll_loop(_app: web.Application) -> None:
        async def loop() -> None:
            while True:
                try:
                    n = poller.poll_once()
                    if n:
                        log.info("gateway.indexed", events=n)
                except Exception as e:
                    log.warning("gateway.poll_failed", error=str(e))
                await asyncio.sleep(poll_interval)

        task = asyncio.create_task(loop())
        yield
        task.cancel()

    app.cleanup_ctx.append(_poll_loop)
    log.info("gateway.starting", host=host, port=port, subnet_registry=subnet_registry)
    web.run_app(app, host=host, port=port)


if __name__ == "__main__":
    main()
