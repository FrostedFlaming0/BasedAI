"""Miner configuration — read from YAML or environment."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

import yaml
from pydantic import BaseModel, Field


class ChainConfig(BaseModel):
    rpc_url: str = Field(..., description="Ink L2 RPC endpoint")
    chain_id: int = 57073
    based_token: str
    subnet_registry: str
    market: str
    scoring_registry: str


class WalletConfig(BaseModel):
    private_key: str = Field(..., description="Hex-encoded miner private key")


class ModelConfig(BaseModel):
    name: str = Field(..., description="HuggingFace model ID, e.g., 'meta-llama/Llama-3-8b'")
    revision: Optional[str] = None
    quantization: Optional[str] = None  # e.g., "awq", "gptq"
    max_model_len: int = 8192
    gpu_memory_utilization: float = 0.9
    tensor_parallel_size: int = 1


class P2PConfig(BaseModel):
    listen_addrs: list[str] = Field(
        default_factory=lambda: ["/ip4/0.0.0.0/tcp/0"]
    )
    bootstrap_peers: list[str] = Field(default_factory=list)
    gossip_topic_prefix: str = "basedai/v1"


class MinerConfig(BaseModel):
    brain_id: int
    chain: ChainConfig
    wallet: WalletConfig
    model: ModelConfig
    p2p: P2PConfig = P2PConfig()
    receipt_batch_size: int = 50
    receipt_batch_interval_seconds: int = 300

    @classmethod
    def from_file(cls, path: str | Path) -> "MinerConfig":
        with open(path) as f:
            raw = yaml.safe_load(f)
        # Allow ${ENV_VAR} substitution.
        return cls(**_expand_env(raw))


def _expand_env(obj):
    if isinstance(obj, dict):
        return {k: _expand_env(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_expand_env(v) for v in obj]
    if isinstance(obj, str) and obj.startswith("${") and obj.endswith("}"):
        return os.environ[obj[2:-1]]
    return obj
