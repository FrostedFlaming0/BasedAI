"""Receipt construction, signing, and on-chain redemption."""

from __future__ import annotations

from dataclasses import dataclass

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

    def add_or_replace(self, receipt: Receipt, user_sig: str) -> None:
        """Add a receipt, replacing any pending one with the same (user, nonce). Used by /settle so
        the counter-signed FINAL receipt (actual cost) supersedes the queued pre-authorization."""
        self._pending = [
            (r, s) for (r, s) in self._pending
            if not (r.user.lower() == receipt.user.lower() and r.nonce == receipt.nonce)
        ]
        self._pending.append((receipt, user_sig))

    def should_flush(self) -> bool:
        return len(self._pending) >= self.batch_size

    async def flush(self) -> list[str]:
        """Submit pending receipts on-chain. Returns list of tx hashes.

        Failures are logged (not silently swallowed) and the failing receipt is retained for the
        next flush, so transient RPC errors do not silently forfeit miner revenue.
        """
        import structlog

        log = structlog.get_logger()
        tx_hashes: list[str] = []
        retained: list[tuple[Receipt, str]] = []
        for receipt, sig in self._pending:
            try:
                tx = self.market.functions.redeem(
                    receipt.to_tuple(), sig
                ).build_transaction({"from": self.account.address, "nonce": _next_nonce(self.market.w3, self.account.address)})
                signed = self.account.sign_transaction(tx)
                tx_hash = self.market.w3.eth.send_raw_transaction(signed.rawTransaction)
                tx_hashes.append(tx_hash.hex())
            except Exception as e:
                log.warning("receipt.redeem_failed", user=receipt.user, nonce=receipt.nonce, error=str(e))
                retained.append((receipt, sig))
        self._pending = retained
        return tx_hashes


def _next_nonce(w3, address):
    return w3.eth.get_transaction_count(address, "pending")
