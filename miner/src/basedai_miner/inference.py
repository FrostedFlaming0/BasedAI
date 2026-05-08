"""Inference backend. Wraps vLLM for serving; falls back to transformers for testing."""

from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass
from typing import Optional

import structlog

log = structlog.get_logger()


@dataclass
class InferenceRequest:
    prompt: str
    max_tokens: int = 256
    temperature: float = 0.7
    top_p: float = 0.95
    seed: Optional[int] = None


@dataclass
class InferenceResponse:
    text: str
    prompt_hash: str
    response_hash: str
    tokens_in: int
    tokens_out: int
    latency_ms: int


class InferenceEngine:
    """Production miners use vLLM; this class wraps the call surface so tests can stub it."""

    def __init__(self, model_name: str, **kwargs):
        self.model_name = model_name
        self._engine = None
        self._kwargs = kwargs

    async def start(self) -> None:
        """Lazy-load the model. Allows the miner to start its P2P stack first."""
        try:
            from vllm import AsyncLLMEngine, AsyncEngineArgs
        except ImportError:
            log.warning("vllm.not_available", fallback="transformers")
            self._engine = _TransformersFallback(self.model_name)
            return

        args = AsyncEngineArgs(
            model=self.model_name,
            quantization=self._kwargs.get("quantization"),
            max_model_len=self._kwargs.get("max_model_len", 8192),
            gpu_memory_utilization=self._kwargs.get("gpu_memory_utilization", 0.9),
            tensor_parallel_size=self._kwargs.get("tensor_parallel_size", 1),
        )
        self._engine = AsyncLLMEngine.from_engine_args(args)
        log.info("inference.started", model=self.model_name)

    async def generate(self, req: InferenceRequest) -> InferenceResponse:
        if self._engine is None:
            raise RuntimeError("Engine not started")

        import time
        t0 = time.monotonic()

        text = await self._engine.generate(req)  # delegated to backend
        latency_ms = int((time.monotonic() - t0) * 1000)

        prompt_hash = _h(req.prompt)
        response_hash = _h(text)

        return InferenceResponse(
            text=text,
            prompt_hash=prompt_hash,
            response_hash=response_hash,
            tokens_in=len(req.prompt.split()),  # approx; production uses tokenizer
            tokens_out=len(text.split()),
            latency_ms=latency_ms,
        )


class _TransformersFallback:
    """Minimal fallback for environments without vLLM (e.g., CI)."""

    def __init__(self, model_name: str):
        self.model_name = model_name
        # Lazy import to avoid loading transformers if not needed
        from transformers import AutoModelForCausalLM, AutoTokenizer
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        self.model = AutoModelForCausalLM.from_pretrained(model_name)

    async def generate(self, req: InferenceRequest) -> str:
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self._generate_sync, req)

    def _generate_sync(self, req: InferenceRequest) -> str:
        inputs = self.tokenizer(req.prompt, return_tensors="pt")
        outputs = self.model.generate(
            **inputs,
            max_new_tokens=req.max_tokens,
            temperature=req.temperature,
            top_p=req.top_p,
            do_sample=req.temperature > 0,
        )
        return self.tokenizer.decode(outputs[0], skip_special_tokens=True)


def _h(s: str) -> str:
    return "0x" + hashlib.sha256(s.encode()).hexdigest()
