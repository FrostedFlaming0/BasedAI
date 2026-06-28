"""Miner endpoint-announcement protocol.

On-chain registration records only a miner's ADDRESS, not where to reach it. For an HTTP
transport, a miner announces its reachable URL to the gateway, signed by its registration key, so
the gateway can bind address -> URL without trusting an unauthenticated claim. The signature is
domain-separated and timestamped; the gateway additionally checks `isMiner` on-chain and rejects
stale timestamps, so an announce cannot be forged or replayed indefinitely.

This signing convention is mirrored by the miner (basedai_miner). Keep the two in lockstep.
"""

from __future__ import annotations

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak

DOMAIN_TAG = keccak(text="BasedAI:MinerAnnounce:v1")


def announce_digest(brain_id: int, url: str, ts: int) -> bytes:
    return keccak(abi_encode(["bytes32", "uint256", "string", "uint256"], [DOMAIN_TAG, int(brain_id), url, int(ts)]))


def sign_announce(account: Account, brain_id: int, url: str, ts: int) -> str:
    sig = account.sign_message(encode_defunct(primitive=announce_digest(brain_id, url, ts))).signature
    return sig.hex() if isinstance(sig, (bytes, bytearray)) else sig


def recover_announce(brain_id: int, url: str, ts: int, signature: str | bytes) -> str:
    return Account.recover_message(encode_defunct(primitive=announce_digest(brain_id, url, ts)), signature=signature)
