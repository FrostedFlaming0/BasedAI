"""Main miner orchestration: chain watcher + P2P + inference + receipt batching."""

from __future__ import annotations

import asyncio
import json
import time
from typing import Optional

import structlog
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3

from .config import MinerConfig
from .inference import InferenceEngine, InferenceRequest
from .p2p import P2PNode, PROTOCOL_INFER, PROTOCOL_CHALLENGE
from .receipts import Receipt, ReceiptBatcher, verify_user_signature

log = structlog.get_logger()


class Miner:
    def __init__(self, config: MinerConfig):
        self.config = config
        self.account = Account.from_key(config.wallet.private_key)
        self.w3 = Web3(Web3.HTTPProvider(config.chain.rpc_url))
        self.engine = InferenceEngine(
            config.model.name,
            quantization=config.model.quantization,
            max_model_len=config.model.max_model_len,
            gpu_memory_utilization=config.model.gpu_memory_utilization,
            tensor_parallel_size=config.model.tensor_parallel_size,
        )
        self.p2p = P2PNode(
            listen_addrs=config.p2p.listen_addrs,
            bootstrap_peers=config.p2p.bootstrap_peers,
            topic=f"{config.p2p.gossip_topic_prefix}/brain/{config.brain_id}",
        )
        self._market_contract = self._load_contract("ComputeUnitMarket", config.chain.market)
        self._registry_contract = self._load_contract("SubnetRegistry", config.chain.subnet_registry)
        self._batcher = ReceiptBatcher(self._market_contract, self.account, config.receipt_batch_size)

    def _load_contract(self, name: str, address: str):
        # ABI files would ship with the package in a real build.
        from importlib.resources import files
        try:
            abi = json.loads(files("basedai_miner.abi").joinpath(f"{name}.json").read_text())
        except (FileNotFoundError, ModuleNotFoundError):
            abi = []
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)

    async def run(self) -> None:
        log.info("miner.starting", brain_id=self.config.brain_id, address=self.account.address)
        await self._verify_registration()
        await self.engine.start()
        await self.p2p.start()
        self.p2p.on_request(PROTOCOL_INFER, self._handle_infer)
        self.p2p.on_request(PROTOCOL_CHALLENGE, self._handle_challenge)

        await asyncio.gather(
            self._receipt_flusher(),
            self._heartbeat(),
        )

    async def _verify_registration(self) -> None:
        """Confirm we're registered as a miner on this Brain. Auto-register if not."""
        try:
            is_miner = self._registry_contract.functions.isMiner(
                self.config.brain_id, self.account.address
            ).call()
            if not is_miner:
                log.info("miner.registering", brain_id=self.config.brain_id)
                tx = self._registry_contract.functions.registerMiner(
                    self.config.brain_id
                ).build_transaction({
                    "from": self.account.address,
                    "nonce": self.w3.eth.get_transaction_count(self.account.address),
                })
                signed = self.account.sign_transaction(tx)
                self.w3.eth.send_raw_transaction(signed.rawTransaction)
        except Exception as e:
            log.warning("miner.registration_check_failed", error=str(e))

    async def _handle_infer(self, payload: bytes) -> bytes:
        """Handle an incoming inference request from a user."""
        try:
            req_data = json.loads(payload)
            user_sig = req_data["user_signature"]
            receipt_data = req_data["receipt"]
            prompt = req_data["prompt"]

            # Build a Receipt from the user's pre-signed envelope (they sign before knowing
            # the response_hash; the response_hash is filled in below and a follow-up signature
            # would normally be expected for amount finalization. v1 simplification:
            # the user signs the max budget receipt up front).
            r = Receipt(**receipt_data)
            if r.miner.lower() != self.account.address.lower():
                return _err("wrong miner")
            if not verify_user_signature(
                self.config.chain.market, self.config.chain.chain_id, r, user_sig
            ):
                return _err("bad signature")

            inference_req = InferenceRequest(prompt=prompt)
            response = await self.engine.generate(inference_req)

            # Update the receipt with the actual response hash; user must counter-sign for
            # final amount before redemption (handled in the higher layer).
            r.response_hash = response.response_hash

            self._batcher.add(r, user_sig)

            return json.dumps({
                "text": response.text,
                "prompt_hash": response.prompt_hash,
                "response_hash": response.response_hash,
                "tokens_in": response.tokens_in,
                "tokens_out": response.tokens_out,
                "miner_signature": self._sign_response(response),
            }).encode()
        except Exception as e:
            log.exception("miner.infer_failed")
            return _err(str(e))

    async def _handle_challenge(self, payload: bytes) -> bytes:
        """Handle a validator challenge: a known prompt sent for deterministic comparison."""
        try:
            data = json.loads(payload)
            prompt = data["prompt"]
            seed = data.get("seed", 0)
            req = InferenceRequest(prompt=prompt, temperature=0.0, seed=seed)
            response = await self.engine.generate(req)
            return json.dumps({
                "text": response.text,
                "response_hash": response.response_hash,
                "miner_signature": self._sign_response(response),
            }).encode()
        except Exception as e:
            log.exception("miner.challenge_failed")
            return _err(str(e))

    def _sign_response(self, response) -> str:
        msg = encode_defunct(text=response.response_hash)
        return self.account.sign_message(msg).signature.hex()

    async def _receipt_flusher(self) -> None:
        while True:
            await asyncio.sleep(self.config.receipt_batch_interval_seconds)
            if self._batcher.should_flush() or len(self._batcher._pending) > 0:
                tx_hashes = await self._batcher.flush()
                if tx_hashes:
                    log.info("miner.receipts_flushed", count=len(tx_hashes))

    async def _heartbeat(self) -> None:
        while True:
            await asyncio.sleep(60)
            await self.p2p.gossip({
                "type": "heartbeat",
                "miner": self.account.address,
                "brain_id": self.config.brain_id,
                "ts": int(time.time()),
            })


def _err(msg: str) -> bytes:
    return json.dumps({"error": msg}).encode()
