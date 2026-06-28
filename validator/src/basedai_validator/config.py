"""Validator configuration."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Optional

import yaml
from pydantic import BaseModel, Field, field_validator

_ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
_ZERO_ADDR = "0x" + "0" * 40


class ChainConfig(BaseModel):
    rpc_url: str
    chain_id: int = 57073
    based_token: str
    subnet_registry: str
    scoring_registry: str
    staking_vault: str

    @field_validator("rpc_url")
    @classmethod
    def _https_rpc(cls, v: str) -> str:
        if not (v.startswith("https://") or v.startswith("http://localhost") or v.startswith("http://127.")):
            raise ValueError("rpc_url must be https:// (or localhost) to avoid plaintext key exposure")
        return v

    @field_validator("based_token", "subnet_registry", "scoring_registry", "staking_vault")
    @classmethod
    def _valid_addr(cls, v: str) -> str:
        if not _ADDR_RE.match(v) or v.lower() == _ZERO_ADDR:
            raise ValueError(f"invalid or zero contract address: {v}")
        return v


class WalletConfig(BaseModel):
    private_key: str


class P2PConfig(BaseModel):
    listen_addrs: list[str] = Field(default_factory=lambda: ["/ip4/0.0.0.0/tcp/0"])
    bootstrap_peers: list[str] = Field(default_factory=list)
    gossip_topic_prefix: str = "basedai/v1"


class ScoringConfig(BaseModel):
    challenge_interval_seconds: int = 60
    challenges_per_epoch: int = 60
    eval_set_path: Optional[str] = None  # JSON file with reference Q/A pairs
    # Aggregator endpoint that collects per-validator epoch signatures and submits the
    # co-signed root via ScoringRegistry.proposeEpoch. Required to actually finalize epochs.
    aggregator_url: Optional[str] = None
    # Gateway/indexer used to discover the current miner set for a Brain.
    gateway_url: Optional[str] = None
    # Slippage guard for auto-registration; 0 = accept the current fee.
    max_registration_fee: int = 0


class ValidatorConfig(BaseModel):
    brain_id: int
    chain: ChainConfig
    wallet: WalletConfig
    p2p: P2PConfig = P2PConfig()
    scoring: ScoringConfig = ScoringConfig()

    @classmethod
    def from_file(cls, path: str | Path) -> "ValidatorConfig":
        with open(path) as f:
            raw = yaml.safe_load(f)
        return cls(**_expand_env(raw))


def _expand_env(obj):
    if isinstance(obj, dict):
        return {k: _expand_env(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_expand_env(v) for v in obj]
    if isinstance(obj, str) and obj.startswith("${") and obj.endswith("}"):
        return os.environ[obj[2:-1]]
    return obj
