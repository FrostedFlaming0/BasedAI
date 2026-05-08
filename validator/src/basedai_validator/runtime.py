"""Validator runtime: issue challenges, observe miner responses, post epoch commitments."""

from __future__ import annotations

import asyncio
import json
import random
import time
from collections import defaultdict
from pathlib import Path
from typing import Optional

import structlog
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak
from web3 import Web3

from .config import ValidatorConfig
from .merkle import ScoreLeaf, build_merkle_root
from .scoring import MinerObservation, score_miners

log = structlog.get_logger()


class Validator:
    def __init__(self, config: ValidatorConfig):
        self.config = config
        self.account = Account.from_key(config.wallet.private_key)
        self.w3 = Web3(Web3.HTTPProvider(config.chain.rpc_url))
        self._observations: list[MinerObservation] = []
        self._eval_set = self._load_eval_set()
        self._scoring_contract = self._load_contract("ScoringRegistry", config.chain.scoring_registry)
        self._registry_contract = self._load_contract("SubnetRegistry", config.chain.subnet_registry)

    def _load_contract(self, name: str, address: str):
        from importlib.resources import files
        try:
            abi = json.loads(files("basedai_validator.abi").joinpath(f"{name}.json").read_text())
        except (FileNotFoundError, ModuleNotFoundError):
            abi = []
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)

    def _load_eval_set(self) -> list[dict]:
        path = self.config.scoring.eval_set_path
        if not path or not Path(path).exists():
            return []
        return json.loads(Path(path).read_text())

    async def run(self) -> None:
        log.info("validator.starting", brain_id=self.config.brain_id, address=self.account.address)
        await self._verify_registration()

        await asyncio.gather(
            self._challenge_loop(),
            self._epoch_loop(),
        )

    async def _verify_registration(self) -> None:
        try:
            is_v = self._registry_contract.functions.isValidator(
                self.config.brain_id, self.account.address
            ).call()
            if not is_v:
                tx = self._registry_contract.functions.registerValidator(
                    self.config.brain_id
                ).build_transaction({
                    "from": self.account.address,
                    "nonce": self.w3.eth.get_transaction_count(self.account.address),
                })
                signed = self.account.sign_transaction(tx)
                self.w3.eth.send_raw_transaction(signed.rawTransaction)
                log.info("validator.registered", brain_id=self.config.brain_id)
        except Exception as e:
            log.warning("validator.registration_check_failed", error=str(e))

    async def _challenge_loop(self) -> None:
        """Periodically issue deterministic challenge prompts to miners."""
        while True:
            await asyncio.sleep(self.config.scoring.challenge_interval_seconds)
            try:
                await self._issue_challenge()
            except Exception as e:
                log.exception("validator.challenge_loop_error")

    async def _issue_challenge(self) -> None:
        """Pick a random miner and a random eval prompt; record the response."""
        miners = self._discover_miners()
        if not miners:
            return
        miner = random.choice(miners)

        if self._eval_set:
            eval_item = random.choice(self._eval_set)
            prompt = eval_item["prompt"]
            reference = eval_item.get("reference")
        else:
            prompt = "Reply with the single word: PING"
            reference = "PING"

        prompt_id = "0x" + keccak(prompt.encode()).hex()
        seed = random.randint(0, 2**31 - 1)

        # In production this is a libp2p stream; here we record the abstract observation.
        # The actual P2P call would use PROTOCOL_CHALLENGE on the miner's address.
        response_text, response_hash, latency_ms = await self._call_miner_challenge(
            miner, prompt, seed
        )

        self._observations.append(MinerObservation(
            miner=miner,
            prompt_id=prompt_id,
            response_hash=response_hash,
            response_text=response_text,
            latency_ms=latency_ms,
            is_challenge=True,
            reference_text=reference,
        ))

    def _discover_miners(self) -> list[str]:
        """Pull current miner set from chain. v1: simple polling; production gossips."""
        try:
            count = self._registry_contract.functions.minerCount(self.config.brain_id).call()
            # Real impl: enumerate via events or an indexer. v1: stub returns empty.
            return []
        except Exception:
            return []

    async def _call_miner_challenge(
        self, miner: str, prompt: str, seed: int
    ) -> tuple[str, str, int]:
        """Send a challenge over P2P and time the response. v1 stub."""
        # Production: open libp2p stream to miner with PROTOCOL_CHALLENGE.
        return "", "0x" + "0" * 64, 0

    async def _epoch_loop(self) -> None:
        """At each epoch boundary, build a Merkle root from observations and post it."""
        while True:
            current_epoch = await self._read_current_epoch()
            await self._wait_for_epoch_end(current_epoch)
            try:
                await self._post_epoch_commitment(current_epoch)
            except Exception as e:
                log.exception("validator.epoch_post_failed")
            self._observations.clear()

    async def _read_current_epoch(self) -> int:
        try:
            return int(self._scoring_contract.functions.currentEpoch().call())
        except Exception:
            # Fallback to clock-based estimate.
            return int(time.time()) // 3600

    async def _wait_for_epoch_end(self, epoch: int) -> None:
        # 1-hour epochs by convention; sleep until next boundary.
        now = time.time()
        boundary = ((int(now) // 3600) + 1) * 3600
        await asyncio.sleep(max(1, boundary - now))

    async def _post_epoch_commitment(self, epoch: int) -> None:
        scores = score_miners(self._observations)
        if not scores:
            log.info("validator.no_observations", epoch=epoch)
            return

        leaves = [
            ScoreLeaf(
                brain_id=self.config.brain_id,
                miner=Web3.to_checksum_address(s.miner),
                score=s.score_fp,
            )
            for s in scores
        ]
        root, _ = build_merkle_root(leaves)

        digest = keccak(
            self.w3.codec.encode(["uint64", "bytes32"], [epoch, root])
        )
        msg = encode_defunct(digest)
        signature = self.account.sign_message(msg).signature

        log.info(
            "validator.epoch_signed",
            epoch=epoch,
            root="0x" + root.hex(),
            scores=len(scores),
        )

        # Submit to the aggregation service or directly to the chain via proposeEpoch
        # if we're acting as the proposer for this epoch. In a multi-validator setup
        # signatures are aggregated off-chain by a coordinator; v1 ships a simple aggregator.
        # See ./aggregator.py.
