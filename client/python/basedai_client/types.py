"""Public type definitions for the Python client."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class InferenceRequest:
    brain_id: int
    prompt: str
    budget: int                       # wei of BASED
    max_tokens: int = 256
    temperature: float = 0.7
    expiry: Optional[int] = None      # unix seconds; defaults to now + 1h


@dataclass
class InferenceResponse:
    text: str
    miner: str
    prompt_hash: str
    response_hash: str
    tokens_in: int
    tokens_out: int
    amount: int
    miner_signature: str


@dataclass
class Receipt:
    user: str
    miner: str
    brain_id: int
    prompt_hash: str
    response_hash: str
    amount: int
    expiry: int
    nonce: int
