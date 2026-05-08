"""Receipt construction, signing, and on-chain redemption."""

from __future__ import annotations

import time
from dataclasses import dataclass, asdict
from typing import Optional

from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3


@dataclass
class Receipt:
    user: str
    miner: str
    brain_id: int
    prompt_hash: str
    response_hash: str
    amount: int           # in wei of BASED
    expiry: int           # unix timestamp
    nonce: int

    def to_tuple(self) -> tuple:
        return (
            self.user,
            self.miner,
            self.brain_id,
            bytes.fromhex(self.prompt_hash[2:]),
            bytes.fromhex(self.response_hash[2:]),
            self.amount,
            self.expiry,
            self.nonce,
        )


def receipt_digest(market_address: str, chain_id: int, r: Receipt) -> bytes:
    """Mirror of the on-chain digest in ComputeUnitMarket.redeem."""
    encoded = Web3().codec.encode(
        ["address", "uint256", "address", "address", "uint256",
         "bytes32", "bytes32", "uint256", "uint64", "uint256"],
        [
            market_address,
            chain_id,
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
    return Web3.keccak(encoded)


def verify_user_signature(market_address: str, chain_id: int, r: Receipt, sig: str) -> bool:
    digest = receipt_digest(market_address, chain_id, r)
    msg = encode_defunct(digest)
    recovered = Account.recover_message(msg, signature=sig)
    return recovered.lower() == r.user.lower()


class ReceiptBatcher:
    """Holds receipts and submits them on-chain in batches to amortize gas."""

    def __init__(self, market_contract, miner_account, batch_size: int = 50):
        self.market = market_contract
        self.account = miner_account
        self.batch_size = batch_size
        self._pending: list[tuple[Receipt, str]] = []

    def add(self, receipt: Receipt, user_sig: str) -> None:
        self._pending.append((receipt, user_sig))

    def should_flush(self) -> bool:
        return len(self._pending) >= self.batch_size

    async def flush(self) -> list[str]:
        """Submit pending receipts on-chain. Returns list of tx hashes."""
        tx_hashes: list[str] = []
        for receipt, sig in self._pending:
            try:
                tx = self.market.functions.redeem(
                    receipt.to_tuple(), sig
                ).build_transaction({"from": self.account.address, "nonce": _next_nonce(self.market.w3, self.account.address)})
                signed = self.account.sign_transaction(tx)
                tx_hash = self.market.w3.eth.send_raw_transaction(signed.rawTransaction)
                tx_hashes.append(tx_hash.hex())
            except Exception as e:
                # Receipt may have expired or been double-spent; drop and continue.
                continue
        self._pending.clear()
        return tx_hashes


def _next_nonce(w3, address):
    return w3.eth.get_transaction_count(address, "pending")
