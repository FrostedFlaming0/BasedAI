"""Validator configuration."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

import yaml
from pydantic import BaseModel, Field


class ChainConfig(BaseModel):
    rpc_url: str
    chain_id: int = 57073
    based_token: str
    subnet_registry: str
    scoring_registry: str
    staking_vault: str


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
