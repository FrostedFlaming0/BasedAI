"""Domain-separated epoch-commitment digest — the off-chain mirror of
`ScoringRegistry.commitmentDigest`.

The on-chain contract (ScoringRegistry.sol) computes, for a validator's epoch signature:

    digest = keccak256(abi.encode(
        DOMAIN_TAG,        // keccak256("BasedAI:ScoringRegistry:v2")
        block.chainid,     // uint256
        address(this),     // the ScoringRegistry address
        epoch,             // uint64
        brainId,           // uint256
        merkleRoot         // bytes32
    )).toEthSignedMessageHash();

A signature produced over any OTHER preimage will not recover to the signer on-chain, so the
epoch can never be proposed. The v1 validator signed `keccak(abi.encode(epoch, root))` with NO
domain separation, which would have been rejected by `proposeEpoch`. This module is the single
source of truth both the validator and the aggregator sign/recover against.
"""

from __future__ import annotations

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak
from web3 import Web3

# keccak256("BasedAI:ScoringRegistry:v2") — must match ScoringRegistry.DOMAIN_TAG.
DOMAIN_TAG = keccak(text="BasedAI:ScoringRegistry:v2")


def _as_root_bytes(root: bytes | str) -> bytes:
    if isinstance(root, str):
        root = bytes.fromhex(root[2:] if root.startswith("0x") else root)
    if len(root) != 32:
        raise ValueError("merkle root must be 32 bytes")
    return root


def commitment_digest(chain_id: int, scoring_registry: str, epoch: int, brain_id: int, root: bytes | str) -> bytes:
    """The inner keccak digest (pre-EIP-191), matching `ScoringRegistry.commitmentDigest`."""
    return keccak(
        abi_encode(
            ["bytes32", "uint256", "address", "uint64", "uint256", "bytes32"],
            [
                DOMAIN_TAG,
                int(chain_id),
                Web3.to_checksum_address(scoring_registry),
                int(epoch),
                int(brain_id),
                _as_root_bytes(root),
            ],
        )
    )


def sign_commitment(account: Account, chain_id: int, scoring_registry: str, epoch: int, brain_id: int, root: bytes | str) -> str:
    """Sign the domain-separated commitment with EIP-191 prefixing (matches toEthSignedMessageHash).

    Returns a 0x-prefixed hex signature accepted by `ScoringRegistry.proposeEpoch`.
    """
    digest = commitment_digest(chain_id, scoring_registry, epoch, brain_id, root)
    sig = account.sign_message(encode_defunct(primitive=digest)).signature
    return sig.hex() if isinstance(sig, (bytes, bytearray)) else sig


def recover_commitment_signer(
    chain_id: int, scoring_registry: str, epoch: int, brain_id: int, root: bytes | str, signature: str | bytes
) -> str:
    """Recover the signer address from a commitment signature (the aggregator's verification)."""
    digest = commitment_digest(chain_id, scoring_registry, epoch, brain_id, root)
    return Account.recover_message(encode_defunct(primitive=digest), signature=signature)
