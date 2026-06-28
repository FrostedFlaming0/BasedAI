"""Python client for BasedAI."""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass
from typing import Optional

import httpx
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3

from .types import InferenceRequest, InferenceResponse, Receipt

# Default pre-authorization reservation (the bounded no-delivery fallback) when the request does
# not set one: 0.01 BASED. Must not exceed the market's on-chain `maxReservation`. Operators tune
# per their pricing; the budget (the full, counter-signed charge) is separate and set per request.
DEFAULT_RESERVATION = 10**16


@dataclass
class ClientConfig:
    rpc_url: str
    chain_id: int
    based: str
    subnet_registry: str
    market: str
    gateway_url: str
    private_key: Optional[str] = None


class BasedClient:
    def __init__(self, config: ClientConfig):
        self.config = config
        self.w3 = Web3(Web3.HTTPProvider(config.rpc_url))
        self.account = Account.from_key(config.private_key) if config.private_key else None
        self._http = httpx.Client(timeout=120.0)

    # --- Account ---

    def balance(self) -> int:
        self._require_account()
        return _erc20(self.w3, self.config.based).functions.balanceOf(self.account.address).call()

    def spending_balance(self) -> int:
        self._require_account()
        return _market(self.w3, self.config.market).functions.balances(self.account.address).call()

    def deposit(self, amount: int) -> str:
        self._require_account()
        token = _erc20(self.w3, self.config.based)
        market = _market(self.w3, self.config.market)

        # approve
        nonce = self.w3.eth.get_transaction_count(self.account.address)
        tx = token.functions.approve(self.config.market, amount).build_transaction(
            {"from": self.account.address, "nonce": nonce}
        )
        signed = self.account.sign_transaction(tx)
        approve_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)
        self.w3.eth.wait_for_transaction_receipt(approve_hash)

        # deposit
        tx = market.functions.deposit(amount).build_transaction(
            {"from": self.account.address, "nonce": nonce + 1}
        )
        signed = self.account.sign_transaction(tx)
        return self.w3.eth.send_raw_transaction(signed.rawTransaction).hex()

    def request_withdraw(self, amount: int) -> str:
        """Begin a withdrawal (step 1 of 2). Funds stay redeemable by miners during the delay."""
        self._require_account()
        market = _market(self.w3, self.config.market)
        nonce = self.w3.eth.get_transaction_count(self.account.address)
        tx = market.functions.requestWithdraw(amount).build_transaction(
            {"from": self.account.address, "nonce": nonce}
        )
        signed = self.account.sign_transaction(tx)
        return self.w3.eth.send_raw_transaction(signed.rawTransaction).hex()

    def withdraw(self) -> str:
        """Complete a withdrawal (step 2 of 2) after the delay has elapsed. Takes no amount: the
        contract pays out min(requested, current balance)."""
        self._require_account()
        market = _market(self.w3, self.config.market)
        nonce = self.w3.eth.get_transaction_count(self.account.address)
        tx = market.functions.withdraw().build_transaction(
            {"from": self.account.address, "nonce": nonce}
        )
        signed = self.account.sign_transaction(tx)
        return self.w3.eth.send_raw_transaction(signed.rawTransaction).hex()

    # --- Inference ---

    def infer(self, req: InferenceRequest) -> InferenceResponse:
        self._require_account()

        miners = self._list_miners(req.brain_id)
        if not miners:
            raise RuntimeError(f"No miners available for brain {req.brain_id}")
        miner = max(miners, key=lambda m: m.get("score", 0))

        prompt_hash = "0x" + Web3.keccak(text=req.prompt).hex()
        expiry = req.expiry or (int(time.time()) + 3600)
        nonce = secrets.randbits(64)

        # The pre-authorization is only a bounded no-delivery FALLBACK now (not the full budget):
        # its amount is capped at the market's `maxReservation` on-chain, so a miner can never draw
        # the whole budget from a receipt signed before any output exists. Full payment goes through
        # the counter-signed FINAL receipt below, which we sign only after verifying the response.
        reservation = req.reservation or min(req.budget, DEFAULT_RESERVATION)
        if reservation > req.budget:
            reservation = req.budget

        # NON-ZERO sentinel responseHash bound to (prompt, nonce) — must match the contract's
        # keccak256(abi.encodePacked(promptHash, bytes32(nonce))).
        sentinel = "0x" + Web3.keccak(
            hexstr=prompt_hash[2:] + format(nonce, "064x")
        ).hex()
        preauth = Receipt(
            user=self.account.address,
            miner=miner["address"],
            brain_id=req.brain_id,
            prompt_hash=prompt_hash,
            response_hash=sentinel,
            amount=reservation,
            expiry=expiry,
            nonce=nonce,
        )
        preauth_sig = self._sign_receipt(preauth)

        url = f"{self.config.gateway_url}/brains/{req.brain_id}/infer"
        body = {
            "prompt": req.prompt,
            "max_tokens": req.max_tokens,
            "temperature": req.temperature,
            "budget": req.budget,  # the ceiling for the FINAL charge; the miner bills <= this
            "receipt": _serialize_receipt(preauth),
            "user_signature": preauth_sig,
            "target_miner": miner["address"],
        }

        r = self._http.post(url, json=body)
        r.raise_for_status()
        data = r.json()
        if "error" in data:
            raise RuntimeError(f"miner error: {data['error']}")

        # Verify the delivered output matches the committed response hash before paying.
        expected_rh = "0x" + Web3.keccak(text=data["text"]).hex()
        if data["response_hash"].lower() != expected_rh.lower():
            raise RuntimeError("response hash does not match returned text")

        # Counter-sign the FINAL receipt (binds the delivered output) and settle it. Only this
        # receipt — signed after verifying the response — authorizes the full charge.
        charged = reservation  # what the miner can draw if settlement never happens
        final = data.get("final_receipt")
        if final:
            final_receipt = Receipt(
                user=final["user"], miner=final["miner"], brain_id=int(final["brain_id"]),
                prompt_hash=final["prompt_hash"], response_hash=final["response_hash"],
                amount=int(final["amount"]), expiry=int(final["expiry"]), nonce=int(final["nonce"]),
            )
            # A final receipt may change only the response hash and amount. Every identity/replay
            # field must remain identical to the preauthorization; otherwise a miner could retain
            # nonce A and induce the client to sign nonce B, then redeem both.
            _assert_final_receipt_identity(preauth, final_receipt)
            if final_receipt.amount > req.budget:
                raise RuntimeError("final amount exceeds budget")
            # Bytes are independently measurable by both parties; unlike token counts they do not
            # require trusting the miner or reproducing a model-specific tokenizer.
            ppt, ppr = self._read_pricing()
            if ppt <= 0 and ppr <= 0:
                raise RuntimeError("market pricing is disabled")
            expected = ppr + ppt * (len(req.prompt.encode("utf-8")) + len(data["text"].encode("utf-8")))
            expected = min(expected, req.budget)
            if final_receipt.amount != expected:
                raise RuntimeError(
                    f"incorrect metered charge: amount {final_receipt.amount}, expected {expected}"
                )
            # The final must bind the DELIVERED output, not the pre-auth sentinel.
            if final_receipt.response_hash.lower() != expected_rh.lower():
                raise RuntimeError("final receipt response hash does not match delivered text")
            final_sig = self._sign_receipt(final_receipt)
            charged = final_receipt.amount
            settle_url = f"{self.config.gateway_url}/brains/{req.brain_id}/settle"
            try:
                self._http.post(
                    settle_url,
                    json={"receipt": _serialize_receipt(final_receipt), "user_signature": final_sig},
                ).raise_for_status()
            except Exception:
                # Settlement is best-effort; the signed pre-auth remains the miner's bounded fallback.
                pass

        return InferenceResponse(
            text=data["text"],
            miner=miner["address"],
            prompt_hash=data["prompt_hash"],
            response_hash=data["response_hash"],
            tokens_in=data["tokens_in"],
            tokens_out=data["tokens_out"],
            amount=charged,
            miner_signature=data["miner_signature"],
        )

    # --- Helpers ---

    def _list_miners(self, brain_id: int) -> list[dict]:
        url = f"{self.config.gateway_url}/brains/{brain_id}/miners"
        r = self._http.get(url)
        if r.status_code != 200:
            return []
        return r.json()

    def _sign_receipt(self, r: Receipt) -> str:
        digest = Web3.keccak(
            self.w3.codec.encode(
                ["address", "uint256", "address", "address", "uint256",
                 "bytes32", "bytes32", "uint256", "uint64", "uint256"],
                [
                    self.config.market,
                    self.config.chain_id,
                    r.user,
                    r.miner,
                    r.brain_id,
                    bytes.fromhex(r.prompt_hash[2:]),
                    bytes.fromhex(r.response_hash[2:]),
                    r.amount,
                    r.expiry,
                    r.nonce,
                ],
            )
        )
        msg = encode_defunct(digest)
        return self.account.sign_message(msg).signature.hex()

    def _read_pricing(self) -> tuple[int, int]:
        """(pricePerByte, pricePerRequest) from the market contract."""
        try:
            market = _market(self.w3, self.config.market)
            ppt = int(market.functions.pricePerByte().call())
            ppr = int(market.functions.pricePerRequest().call())
            return (ppt, ppr)
        except Exception:
            return (0, 0)

    def _require_account(self) -> None:
        if self.account is None:
            raise RuntimeError("Client requires private_key for this operation")


def _serialize_receipt(r: Receipt) -> dict:
    """Serialize a receipt for transport. Numeric fields stay integers so the miner's
    `Receipt(**data)` and ABI encoding receive the correct types."""
    return {
        "user": r.user,
        "miner": r.miner,
        "brain_id": int(r.brain_id),
        "prompt_hash": r.prompt_hash,
        "response_hash": r.response_hash,
        "amount": int(r.amount),
        "expiry": int(r.expiry),
        "nonce": int(r.nonce),
    }


def _assert_final_receipt_identity(preauth: Receipt, final: Receipt) -> None:
    if (
        final.user.lower() != preauth.user.lower()
        or final.miner.lower() != preauth.miner.lower()
        or final.brain_id != preauth.brain_id
        or final.prompt_hash.lower() != preauth.prompt_hash.lower()
        or final.expiry != preauth.expiry
        or final.nonce != preauth.nonce
    ):
        raise RuntimeError("final receipt identity does not match preauthorization")


def _erc20(w3: Web3, address: str):
    abi = [
        {"name": "approve", "type": "function", "stateMutability": "nonpayable",
         "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}],
         "outputs": [{"type": "bool"}]},
        {"name": "balanceOf", "type": "function", "stateMutability": "view",
         "inputs": [{"name": "account", "type": "address"}],
         "outputs": [{"type": "uint256"}]},
    ]
    return w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)


def _market(w3: Web3, address: str):
    abi = [
        {"name": "deposit", "type": "function", "stateMutability": "nonpayable",
         "inputs": [{"name": "amount", "type": "uint256"}], "outputs": []},
        # Two-step withdrawal: requestWithdraw(amount) starts the delay, withdraw() (no args) completes
        # it. The single-step withdraw(amount) interface no longer exists on the contract.
        {"name": "requestWithdraw", "type": "function", "stateMutability": "nonpayable",
         "inputs": [{"name": "amount", "type": "uint256"}], "outputs": []},
        {"name": "withdraw", "type": "function", "stateMutability": "nonpayable",
         "inputs": [], "outputs": []},
        {"name": "balances", "type": "function", "stateMutability": "view",
         "inputs": [{"name": "user", "type": "address"}],
         "outputs": [{"type": "uint256"}]},
        # Byte pricing — independently measurable without trusting model tokenizer output.
        {"name": "pricePerByte", "type": "function", "stateMutability": "view",
         "inputs": [], "outputs": [{"type": "uint256"}]},
        {"name": "pricePerRequest", "type": "function", "stateMutability": "view",
         "inputs": [], "outputs": [{"type": "uint256"}]},
    ]
    return w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)
