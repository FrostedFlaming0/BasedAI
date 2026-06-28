"""Main miner orchestration: chain watcher + P2P + inference + receipt batching."""

from __future__ import annotations

import asyncio
import json
import time

import structlog
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak
from web3 import Web3

from .config import MinerConfig
from .inference import InferenceEngine, InferenceRequest
from .p2p import P2PNode, PROTOCOL_INFER, PROTOCOL_CHALLENGE
from .receipts import Receipt, ReceiptBatcher, verify_user_signature

log = structlog.get_logger()

# Defensive bounds on untrusted network input (prevents memory/GPU exhaustion DoS).
MAX_PAYLOAD_BYTES = 256 * 1024
MAX_PROMPT_CHARS = 32 * 1024

# Minimal ABIs the miner needs. Defined inline so calls never silently no-op against an
# empty/missing ABI (the v1 fail-open defect).
_MARKET_ABI = [
    {"name": "balances", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "user", "type": "address"}], "outputs": [{"type": "uint256"}]},
    {"name": "usedNonces", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "user", "type": "address"}, {"name": "nonce", "type": "uint256"}],
     "outputs": [{"type": "bool"}]},
    {"name": "redeem", "type": "function", "stateMutability": "nonpayable",
     "inputs": [
         {"name": "r", "type": "tuple", "components": [
             {"name": "user", "type": "address"}, {"name": "miner", "type": "address"},
             {"name": "brainId", "type": "uint256"}, {"name": "promptHash", "type": "bytes32"},
             {"name": "responseHash", "type": "bytes32"}, {"name": "amount", "type": "uint256"},
             {"name": "expiry", "type": "uint64"}, {"name": "nonce", "type": "uint256"}]},
         {"name": "userSig", "type": "bytes"}],
     "outputs": []},
    # Metered pricing (the canonical, on-chain charge). The miner bills `quote(tokensIn, tokensOut)`
    # for delivered work instead of the whole budget — the user counter-signs only that.
    {"name": "pricePerByte", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
    {"name": "pricePerRequest", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
]
_REGISTRY_ABI = [
    {"name": "isMiner", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "brainId", "type": "uint256"}, {"name": "who", "type": "address"}],
     "outputs": [{"type": "bool"}]},
    {"name": "isValidator", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "brainId", "type": "uint256"}, {"name": "who", "type": "address"}],
     "outputs": [{"type": "bool"}]},
    {"name": "registerMiner", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "brainId", "type": "uint256"}, {"name": "maxFee", "type": "uint256"}], "outputs": []},
]


class Miner:
    def __init__(self, config: MinerConfig):
        self.config = config
        self.account = Account.from_key(config.wallet.private_key)
        self.w3 = Web3(Web3.HTTPProvider(config.chain.rpc_url))
        self.engine = InferenceEngine(
            config.model.name,
            revision=config.model.revision,
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
        self._market_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(config.chain.market), abi=_MARKET_ABI
        )
        self._registry_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(config.chain.subnet_registry), abi=_REGISTRY_ABI
        )
        self._batcher = ReceiptBatcher(self._market_contract, self.account, config.receipt_batch_size)

    def _quote(self, prompt: str, response: str) -> int:
        """Canonical byte-metered charge. UTF-8 byte lengths are independently reproducible by the
        client, unlike miner-reported tokenizer counts."""
        try:
            ppt = int(self._market_contract.functions.pricePerByte().call())
            ppr = int(self._market_contract.functions.pricePerRequest().call())
        except Exception as exc:
            raise RuntimeError("market pricing unavailable") from exc
        if ppt <= 0 and ppr <= 0:
            raise RuntimeError("market pricing is disabled")
        return ppr + ppt * (len(prompt.encode("utf-8")) + len(response.encode("utf-8")))

    async def run(self) -> None:
        log.info("miner.starting", brain_id=self.config.brain_id, address=self.account.address)
        await self.verify_registration()
        await self.engine.start()
        await self.p2p.start()
        self.p2p.on_request(PROTOCOL_INFER, self._handle_infer)
        self.p2p.on_request(PROTOCOL_CHALLENGE, self._handle_challenge)

        tasks = [self._receipt_flusher(), self._heartbeat()]
        # HTTP transport: serve the request handlers and announce to the gateway so clients and
        # validators can discover and reach this miner without libp2p.
        if self.config.gateway.gateway_url and self.config.gateway.public_url:
            await self._serve_http()
            tasks.append(self._announce_loop())

        await asyncio.gather(*tasks)

    async def _serve_http(self) -> None:
        from aiohttp import web

        from .http_server import make_miner_app

        app = make_miner_app(self._handle_infer, self._handle_challenge, self._handle_settle)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(
            runner, self.config.gateway.http_listen_host, self.config.gateway.http_listen_port
        )
        await site.start()
        log.info(
            "miner.http_listening",
            host=self.config.gateway.http_listen_host,
            port=self.config.gateway.http_listen_port,
        )

    async def _announce_loop(self) -> None:
        from .http_server import announce_once

        while True:
            ok = await announce_once(
                self.account,
                self.config.gateway.gateway_url,
                self.config.brain_id,
                self.config.gateway.public_url,
            )
            if ok:
                log.info("miner.announced", url=self.config.gateway.public_url)
            await asyncio.sleep(self.config.gateway.announce_interval_seconds)

    async def verify_registration(self) -> bool:
        """Confirm we're registered as a miner on this Brain. Auto-register if not.

        Returns True only if the miner is registered at the end. Raises on RPC failure so the
        caller does not falsely report success (the v1 register CLI swallowed all errors).
        """
        is_miner = self._registry_contract.functions.isMiner(
            self.config.brain_id, self.account.address
        ).call()
        if is_miner:
            return True
        log.info("miner.registering", brain_id=self.config.brain_id)
        # maxFee guards against a registration-fee front-run; operators may tune via config.
        max_fee = int(getattr(self.config, "max_registration_fee", 0)) or (1 << 255)
        tx = self._registry_contract.functions.registerMiner(
            self.config.brain_id, max_fee
        ).build_transaction({
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address, "pending"),
        })
        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)
        self.w3.eth.wait_for_transaction_receipt(tx_hash)
        return self._registry_contract.functions.isMiner(
            self.config.brain_id, self.account.address
        ).call()

    # --- Eligibility (verify BEFORE spending GPU) ---

    def _check_eligibility(self, r: Receipt, min_balance: int | None = None) -> str | None:
        """Return an error string if the receipt is not redeemable, else None.

        `min_balance` is the balance the user must hold to cover the eventual FINAL charge (the
        budget), which can exceed the pre-auth reservation `r.amount`. We verify it BEFORE serving
        so we never do work the user cannot pay for."""
        if r.brain_id != self.config.brain_id:
            return "wrong brain"
        if r.miner.lower() != self.account.address.lower():
            return "wrong miner"
        if r.expiry <= int(time.time()):
            return "expired"
        try:
            if self._market_contract.functions.usedNonces(
                Web3.to_checksum_address(r.user), r.nonce
            ).call():
                return "nonce used"
            balance = self._market_contract.functions.balances(
                Web3.to_checksum_address(r.user)
            ).call()
        except Exception as e:  # RPC failure => fail closed, do not serve for free
            log.warning("miner.eligibility_rpc_failed", error=str(e))
            return "eligibility check failed"
        required = min_balance if min_balance is not None else r.amount
        if balance < required:
            return "insufficient user balance"
        return None

    async def _handle_infer(self, payload: bytes) -> bytes:
        """Handle an incoming inference request.

        Protocol: the client sends a pre-authorization receipt (its `responseHash` is a
        deterministic non-zero sentinel and `amount` is the max budget). The miner verifies the
        signature AND on-chain eligibility BEFORE doing any work, then serves the inference and
        returns the proposed FINAL receipt for the client to counter-sign. The pre-auth is a
        redeemable fallback so the miner is never unpaid for delivered work.
        """
        try:
            if len(payload) > MAX_PAYLOAD_BYTES:
                return _err("payload too large")
            req_data = json.loads(payload)
            user_sig = req_data["user_signature"]
            receipt_data = req_data["receipt"]
            prompt = req_data["prompt"]
            if not isinstance(prompt, str) or len(prompt) > MAX_PROMPT_CHARS:
                return _err("invalid or oversized prompt")

            r = Receipt(
                user=Web3.to_checksum_address(receipt_data["user"]),
                miner=Web3.to_checksum_address(receipt_data["miner"]),
                brain_id=int(receipt_data["brain_id"]),
                prompt_hash=receipt_data["prompt_hash"],
                response_hash=receipt_data["response_hash"],
                amount=int(receipt_data["amount"]),
                expiry=int(receipt_data["expiry"]),
                nonce=int(receipt_data["nonce"]),
            )

            # Verify the prompt hash binds the receipt to the actual prompt (keccak, matching client).
            expected_ph = "0x" + keccak(text=prompt).hex()
            if r.prompt_hash.lower() != expected_ph.lower():
                return _err("prompt hash mismatch")

            if not verify_user_signature(
                self.config.chain.market, self.config.chain.chain_id, r, user_sig
            ):
                return _err("bad signature")

            # `budget` is the ceiling for the FINAL charge (the pre-auth `r.amount` is only the
            # bounded fallback). The user must be able to cover the budget before we spend GPU.
            budget = int(req_data.get("budget", r.amount))
            if budget < r.amount:
                budget = r.amount

            err = self._check_eligibility(r, min_balance=budget)
            if err:
                return _err(err)

            # Eligibility proven — now (and only now) spend GPU.
            response = await self.engine.generate(InferenceRequest(prompt=prompt))

            # Queue the signed pre-auth as a bounded, redeemable fallback (sentinel responseHash,
            # capped on-chain at maxReservation). Full payment comes from the counter-signed final.
            self._batcher.add(r, user_sig)

            # The FINAL charge is the metered cost of the delivered work (on-chain `quote`), NOT the
            # whole budget — bounded by budget. This is the fix for the full-budget overcharge: the
            # client independently re-derives this same quote and counter-signs only if it matches.
            charge = min(self._quote(prompt, response.text), budget)

            return json.dumps({
                "text": response.text,
                "prompt_hash": response.prompt_hash,
                "response_hash": response.response_hash,
                "tokens_in": response.tokens_in,
                "tokens_out": response.tokens_out,
                # Proposed final receipt for the client to counter-sign (binds delivered output).
                # `amount` is the metered charge (<= budget); the client verifies the output AND
                # re-derives this charge from the on-chain price before counter-signing.
                "final_receipt": {
                    "user": r.user, "miner": r.miner, "brain_id": r.brain_id,
                    "prompt_hash": r.prompt_hash, "response_hash": response.response_hash,
                    "amount": charge, "expiry": r.expiry, "nonce": r.nonce,
                },
                "miner_signature": self._sign_response(response),
            }).encode()
        except (KeyError, ValueError, TypeError) as e:
            return _err(f"malformed request: {e}")
        except Exception as e:
            log.exception("miner.infer_failed")
            return _err(str(e))

    async def _handle_settle(self, payload: bytes) -> bytes:
        """Accept a client's counter-signed FINAL receipt (the actual cost, bound to the delivered
        output) and queue it for redemption in place of the pre-authorization. Verifies the user
        signature and on-chain eligibility before queuing; never serves work here."""
        try:
            data = json.loads(payload)
            receipt_data = data["receipt"]
            user_sig = data["user_signature"]
            r = Receipt(
                user=Web3.to_checksum_address(receipt_data["user"]),
                miner=Web3.to_checksum_address(receipt_data["miner"]),
                brain_id=int(receipt_data["brain_id"]),
                prompt_hash=receipt_data["prompt_hash"],
                response_hash=receipt_data["response_hash"],
                amount=int(receipt_data["amount"]),
                expiry=int(receipt_data["expiry"]),
                nonce=int(receipt_data["nonce"]),
            )
            if r.response_hash == "0x" + "00" * 32:
                return _err("final receipt must bind a delivered response")
            if not verify_user_signature(self.config.chain.market, self.config.chain.chain_id, r, user_sig):
                return _err("bad signature")
            err = self._check_eligibility(r)
            if err:
                return _err(err)
            self._batcher.add_or_replace(r, user_sig)
            return json.dumps({"ok": True}).encode()
        except (KeyError, ValueError, TypeError) as e:
            return _err(f"malformed settle: {e}")
        except Exception as e:
            log.exception("miner.settle_failed")
            return _err(str(e))

    async def _handle_challenge(self, payload: bytes) -> bytes:
        """Handle a validator challenge. The challenge MUST be signed by a registered validator
        of this Brain — unauthenticated free compute is refused."""
        try:
            if len(payload) > MAX_PAYLOAD_BYTES:
                return _err("payload too large")
            data = json.loads(payload)
            prompt = data["prompt"]
            validator = Web3.to_checksum_address(data["validator"])
            challenge_sig = data["validator_signature"]
            seed = int(data.get("seed", 0))
            if not isinstance(prompt, str) or len(prompt) > MAX_PROMPT_CHARS:
                return _err("invalid or oversized prompt")

            # Authenticate: signature over (brain_id, prompt, seed) by a registered validator.
            msg = encode_defunct(
                primitive=keccak(
                    Web3().codec.encode(
                        ["uint256", "bytes32", "uint256"],
                        [self.config.brain_id, keccak(text=prompt), seed],
                    )
                )
            )
            recovered = Account.recover_message(msg, signature=challenge_sig)
            if recovered.lower() != validator.lower():
                return _err("bad validator signature")
            try:
                if not self._registry_contract.functions.isValidator(
                    self.config.brain_id, validator
                ).call():
                    return _err("not a registered validator")
            except Exception as e:
                log.warning("miner.challenge_auth_rpc_failed", error=str(e))
                return _err("validator check failed")

            response = await self.engine.generate(
                InferenceRequest(prompt=prompt, temperature=0.0, seed=seed)
            )
            return json.dumps({
                "text": response.text,
                "response_hash": response.response_hash,
                "miner_signature": self._sign_response(response),
            }).encode()
        except (KeyError, ValueError, TypeError) as e:
            return _err(f"malformed challenge: {e}")
        except Exception as e:
            log.exception("miner.challenge_failed")
            return _err(str(e))

    def _sign_response(self, response) -> str:
        # Domain-separate the response signature by brain id and prompt hash so it cannot be
        # replayed as a signature for a different request.
        digest = keccak(
            Web3().codec.encode(
                ["uint256", "bytes32", "bytes32"],
                [self.config.brain_id,
                 bytes.fromhex(response.prompt_hash[2:]),
                 bytes.fromhex(response.response_hash[2:])],
            )
        )
        return self.account.sign_message(encode_defunct(primitive=digest)).signature.hex()

    async def _receipt_flusher(self) -> None:
        while True:
            await asyncio.sleep(self.config.receipt_batch_interval_seconds)
            if len(self._batcher._pending) > 0:
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
