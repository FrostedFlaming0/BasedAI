"""Validator runtime: issue challenges, observe miner responses, post epoch commitments."""

from __future__ import annotations

import asyncio
import json
import random
import time
from pathlib import Path

import httpx
import structlog
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak
from web3 import Web3

from .commitment import sign_commitment
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

    # Minimal ABIs defined inline so calls never silently no-op against a missing/empty ABI.
    _ABIS = {
        "ScoringRegistry": [
            {"name": "currentEpoch", "type": "function", "stateMutability": "view",
             "inputs": [], "outputs": [{"type": "uint64"}]},
        ],
        "SubnetRegistry": [
            {"name": "isValidator", "type": "function", "stateMutability": "view",
             "inputs": [{"name": "brainId", "type": "uint256"}, {"name": "who", "type": "address"}],
             "outputs": [{"type": "bool"}]},
            {"name": "minerCount", "type": "function", "stateMutability": "view",
             "inputs": [{"name": "brainId", "type": "uint256"}], "outputs": [{"type": "uint256"}]},
            {"name": "registerValidator", "type": "function", "stateMutability": "nonpayable",
             "inputs": [{"name": "brainId", "type": "uint256"}, {"name": "maxFee", "type": "uint256"}],
             "outputs": []},
        ],
    }

    def _load_contract(self, name: str, address: str):
        abi = self._ABIS.get(name)
        if not abi:
            raise ValueError(f"no ABI configured for {name}")
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
                max_fee = int(getattr(self.config.scoring, "max_registration_fee", 0)) or (1 << 255)
                tx = self._registry_contract.functions.registerValidator(
                    self.config.brain_id, max_fee
                ).build_transaction({
                    "from": self.account.address,
                    "nonce": self.w3.eth.get_transaction_count(self.account.address, "pending"),
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
            except Exception:
                log.exception("validator.challenge_loop_error")

    async def _issue_challenge(self) -> None:
        """Pick a random miner and a random eval prompt; record the response."""
        miners = self._discover_miners()
        if not miners:
            return
        chosen = random.choice(miners)
        miner = chosen["address"]
        miner_url = chosen.get("url")

        if self._eval_set:
            eval_item = random.choice(self._eval_set)
            prompt = eval_item["prompt"]
            reference = eval_item.get("reference")
        else:
            prompt = "Reply with the single word: PING"
            reference = "PING"

        prompt_id = "0x" + keccak(prompt.encode()).hex()
        seed = random.randint(0, 2**31 - 1)

        # Send an authenticated challenge to the miner's announced HTTP endpoint and time it.
        response_text, response_hash, latency_ms = await self._call_miner_challenge(
            miner_url, prompt, seed
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

    def _discover_miners(self) -> list[dict]:
        """Discover the current reachable miner set from the gateway/indexer.

        Returns dicts of {address, url, score}. The gateway derives membership from on-chain
        registry events and joins it with miners' signed endpoint announcements, so the validator
        no longer needs to enumerate logs itself (the v1 stub returned an empty list)."""
        url = self.config.scoring.gateway_url
        if not url:
            log.warning("validator.no_gateway_configured")
            return []
        try:
            resp = httpx.get(f"{url.rstrip('/')}/brains/{self.config.brain_id}/miners", timeout=15.0)
            resp.raise_for_status()
            miners = resp.json()
            return [m for m in miners if m.get("url") and m.get("address")]
        except Exception as e:
            log.warning("validator.miner_discovery_failed", error=str(e))
            return []

    def _build_challenge_payload(self, prompt: str, seed: int) -> dict:
        """Construct an AUTHENTICATED challenge the miner will accept: signed by this validator
        over (brain_id, keccak(prompt), seed), matching the miner's verification."""
        digest = keccak(
            self.w3.codec.encode(
                ["uint256", "bytes32", "uint256"],
                [self.config.brain_id, keccak(text=prompt), seed],
            )
        )
        sig = self.account.sign_message(encode_defunct(primitive=digest)).signature.hex()
        return {
            "prompt": prompt,
            "seed": seed,
            "validator": self.account.address,
            "validator_signature": sig,
        }

    async def _call_miner_challenge(
        self, miner_url: str | None, prompt: str, seed: int
    ) -> tuple[str, str, int]:
        """Send an authenticated challenge to the miner's HTTP endpoint and time the response.

        Returns (response_text, response_hash, latency_ms). On any failure the miner is recorded as
        non-responsive (empty text, zero hash) so the scorer penalizes it rather than crashing."""
        if not miner_url:
            return "", "0x" + "0" * 64, 0
        payload = self._build_challenge_payload(prompt, seed)
        start = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                resp = await client.post(f"{miner_url.rstrip('/')}/challenge", json=payload)
                resp.raise_for_status()
                data = resp.json()
            latency_ms = int((time.monotonic() - start) * 1000)
            if "error" in data:
                log.warning("validator.challenge_error", error=data["error"])
                return "", "0x" + "0" * 64, latency_ms
            return data.get("text", ""), data.get("response_hash", "0x" + "0" * 64), latency_ms
        except Exception as e:
            log.warning("validator.challenge_call_failed", error=str(e))
            return "", "0x" + "0" * 64, int((time.monotonic() - start) * 1000)

    async def _epoch_loop(self) -> None:
        """At each epoch boundary, build a Merkle root from observations and post it."""
        while True:
            current_epoch = await self._read_current_epoch()
            await self._wait_for_epoch_end(current_epoch)
            try:
                await self._post_epoch_commitment(current_epoch)
            except Exception:
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
        own_root, _ = build_merkle_root(leaves)
        candidate_sig = sign_commitment(
            self.account,
            self.config.chain.chain_id,
            self.config.chain.scoring_registry,
            epoch,
            self.config.brain_id,
            own_root,
        )

        # Submit observations first. The aggregator freezes a stake-weighted-median canonical root
        # once candidate contributors reach Brain-local quorum. All validators then sign that same
        # root, rather than assuming independent observations produce identical Merkle trees.
        canonical = await self._submit_candidate(
            epoch,
            [{"miner": s.miner, "score": s.score_fp} for s in scores],
            candidate_sig,
        )
        if canonical is None:
            log.warning("validator.canonical_root_unavailable", epoch=epoch)
            return
        signature = sign_commitment(
            self.account,
            self.config.chain.chain_id,
            self.config.chain.scoring_registry,
            epoch,
            self.config.brain_id,
            canonical,
        )
        await self._submit_commitment(epoch, canonical, signature)

    async def _submit_candidate(self, epoch: int, scores: list[dict], signature: str) -> str | None:
        url = self.config.scoring.aggregator_url
        if not url:
            return None
        payload = {
            "epoch": epoch,
            "brain_id": self.config.brain_id,
            "signer": self.account.address,
            "scores": scores,
            "signature": signature if signature.startswith("0x") else "0x" + signature,
        }
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(f"{url.rstrip('/')}/candidates", json=payload)
            response.raise_for_status()
            data = response.json()
            if data.get("canonical"):
                return str(data["root"])
            # Other validators may still be submitting. Poll briefly for the frozen quorum root.
            for _ in range(60):
                await asyncio.sleep(2)
                response = await client.get(
                    f"{url.rstrip('/')}/candidates/{epoch}/{self.config.brain_id}"
                )
                if response.status_code == 200 and response.json().get("canonical"):
                    return str(response.json()["root"])
        return None

    async def _submit_commitment(self, epoch: int, root_hex: str, signature: str) -> None:
        url = self.config.scoring.aggregator_url
        if not url:
            log.warning("validator.no_aggregator_configured", epoch=epoch)
            return
        payload = {
            "epoch": int(epoch),
            "brain_id": self.config.brain_id,
            "root": root_hex,
            "signer": self.account.address,
            "signature": signature if signature.startswith("0x") else "0x" + signature,
        }
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post(f"{url.rstrip('/')}/commitments", json=payload)
                resp.raise_for_status()
            log.info("validator.commitment_submitted", epoch=epoch, root=root_hex)
        except Exception as e:
            log.warning("validator.commitment_submit_failed", epoch=epoch, error=str(e))
