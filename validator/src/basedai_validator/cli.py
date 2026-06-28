"""CLI for the BasedAI validator."""

from __future__ import annotations

import asyncio
import sys

import click
import structlog
from aiohttp import web
from eth_account import Account
from web3 import Web3

from .config import ValidatorConfig
from .runtime import Validator
from .aggregator import CanonicalCandidatePool, CommitmentAggregator
from .service import make_aggregator_app


@click.group()
def main() -> None:
    structlog.configure(
        processors=[
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.add_log_level,
            structlog.processors.JSONRenderer(),
        ]
    )


@main.command()
@click.option("--config", "-c", type=click.Path(exists=True), required=True)
def run(config: str) -> None:
    """Run the validator."""
    cfg = ValidatorConfig.from_file(config)
    v = Validator(cfg)
    try:
        asyncio.run(v.run())
    except KeyboardInterrupt:
        sys.exit(0)


@main.command("aggregator")
@click.option("--config", "-c", type=click.Path(exists=True), required=True)
@click.option("--host", default="127.0.0.1")
@click.option("--port", default=8810, type=int)
def aggregator_command(config: str, host: str, port: int) -> None:
    """Run the canonical-score and signature aggregation HTTP service."""
    cfg = ValidatorConfig.from_file(config)
    w3 = Web3(Web3.HTTPProvider(cfg.chain.rpc_url))
    account = Account.from_key(cfg.wallet.private_key)
    agg = CommitmentAggregator.from_chain(
        cfg.chain.chain_id, cfg.chain.scoring_registry, cfg.chain.staking_vault, w3, account
    )
    candidates = CanonicalCandidatePool(agg._stake_of, agg._total_stake)
    scoring = w3.eth.contract(
        address=Web3.to_checksum_address(cfg.chain.scoring_registry),
        abi=[{"name": "currentEpoch", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint64"}]}],
    )
    app = make_aggregator_app(agg, candidates, lambda: int(scoring.functions.currentEpoch().call()))
    web.run_app(app, host=host, port=port)


if __name__ == "__main__":
    main()
