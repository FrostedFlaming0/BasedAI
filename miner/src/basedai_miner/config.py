"""Miner configuration — read from YAML or environment."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

import re

import yaml
from pydantic import BaseModel, Field, field_validator

_ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
_ZERO_ADDR = "0x" + "0" * 40


class ChainConfig(BaseModel):
    rpc_url: str = Field(..., description="Ink L2 RPC endpoint")
    chain_id: int = 57073
    based_token: str
    subnet_registry: str
    market: str
    scoring_registry: str

    @field_validator("rpc_url")
    @classmethod
    def _https_rpc(cls, v: str) -> str:
        if not (v.startswith("https://") or v.startswith("http://localhost") or v.startswith("http://127.")):
            raise ValueError("rpc_url must be https:// (or localhost) to avoid plaintext key exposure")
        return v

    @field_validator("based_token", "subnet_registry", "market", "scoring_registry")
    @classmethod
    def _valid_addr(cls, v: str) -> str:
        if not _ADDR_RE.match(v) or v.lower() == _ZERO_ADDR:
            raise ValueError(f"invalid or zero contract address: {v}")
        return v

    @field_validator("chain_id")
    @classmethod
    def _positive_chain(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("chain_id must be positive")
        return v


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


class GatewayConfig(BaseModel):
    # Gateway/indexer the miner announces its endpoint to (and that routes clients to it).
    gateway_url: Optional[str] = None
    # Publicly reachable base URL of THIS miner's HTTP server (what clients/validators dial).
    public_url: Optional[str] = None
    http_listen_host: str = "0.0.0.0"
    http_listen_port: int = 8801
    announce_interval_seconds: int = 120


class MinerConfig(BaseModel):
    brain_id: int
    chain: ChainConfig
    wallet: WalletConfig
    model: ModelConfig
    p2p: P2PConfig = P2PConfig()
    gateway: GatewayConfig = GatewayConfig()
    receipt_batch_size: int = 50
    receipt_batch_interval_seconds: int = 300
    # Slippage guard for auto-registration; 0 = no cap (accept current fee).
    max_registration_fee: int = 0

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
