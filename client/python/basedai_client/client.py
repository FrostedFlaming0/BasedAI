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

        receipt = Receipt(
            user=self.account.address,
            miner=miner["address"],
            brain_id=req.brain_id,
            prompt_hash=prompt_hash,
            response_hash="0x" + "00" * 32,
            amount=req.budget,
            expiry=expiry,
            nonce=nonce,
        )

        user_sig = self._sign_receipt(receipt)

        url = f"{self.config.gateway_url}/brains/{req.brain_id}/infer"
        body = {
            "prompt": req.prompt,
            "max_tokens": req.max_tokens,
            "temperature": req.temperature,
            "receipt": {
                "user": receipt.user,
                "miner": receipt.miner,
                "brain_id": receipt.brain_id,
                "prompt_hash": receipt.prompt_hash,
                "response_hash": receipt.response_hash,
                "amount": str(receipt.amount),
                "expiry": receipt.expiry,
                "nonce": str(receipt.nonce),
            },
            "user_signature": user_sig,
            "target_miner": miner["address"],
        }

        r = self._http.post(url, json=body)
        r.raise_for_status()
        data = r.json()

        return InferenceResponse(
            text=data["text"],
            miner=miner["address"],
            prompt_hash=data["prompt_hash"],
            response_hash=data["response_hash"],
            tokens_in=data["tokens_in"],
            tokens_out=data["tokens_out"],
            amount=req.budget,
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

    def _require_account(self) -> None:
        if self.account is None:
            raise RuntimeError("Client requires private_key for this operation")


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
        {"name": "withdraw", "type": "function", "stateMutability": "nonpayable",
         "inputs": [{"name": "amount", "type": "uint256"}], "outputs": []},
        {"name": "balances", "type": "function", "stateMutability": "view",
         "inputs": [{"name": "user", "type": "address"}],
         "outputs": [{"type": "uint256"}]},
    ]
    return w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)
