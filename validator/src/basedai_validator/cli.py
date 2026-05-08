"""CLI for the BasedAI validator."""

from __future__ import annotations

import asyncio
import sys

import click
import structlog

from .config import ValidatorConfig
from .runtime import Validator


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


if __name__ == "__main__":
    main()
