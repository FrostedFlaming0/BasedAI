"""Command-line interface for the BasedAI miner."""

from __future__ import annotations

import asyncio
import sys

import click
import structlog

from .config import MinerConfig
from .runtime import Miner


@click.group()
def main() -> None:
    """BasedAI miner CLI."""
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
    """Run the miner."""
    cfg = MinerConfig.from_file(config)
    miner = Miner(cfg)
    try:
        asyncio.run(miner.run())
    except KeyboardInterrupt:
        sys.exit(0)


@main.command()
@click.option("--config", "-c", type=click.Path(exists=True), required=True)
def register(config: str) -> None:
    """Register as a miner on the configured Brain."""
    cfg = MinerConfig.from_file(config)
    miner = Miner(cfg)
    asyncio.run(miner._verify_registration())
    click.echo(f"Registered miner {miner.account.address} on Brain {cfg.brain_id}")


if __name__ == "__main__":
    main()
