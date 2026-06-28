"""Tests for the domain-separated epoch-commitment digest (off-chain mirror of
ScoringRegistry.commitmentDigest)."""

from basedai_validator.commitment import (
    DOMAIN_TAG,
    commitment_digest,
    recover_commitment_signer,
    sign_commitment,
)
from eth_abi import encode as abi_encode
from eth_account import Account
from eth_utils import keccak

SCORING = "0x" + "ab" * 20
CHAIN_ID = 57073


def test_domain_tag_matches_contract():
    # Must equal keccak256("BasedAI:ScoringRegistry:v2") in ScoringRegistry.sol.
    assert DOMAIN_TAG == keccak(text="BasedAI:ScoringRegistry:v2")
    assert len(DOMAIN_TAG) == 32


def test_digest_matches_independent_abi_encode():
    epoch = 42
    root = bytes.fromhex("cd" * 32)
    from web3 import Web3

    expected = keccak(
        abi_encode(
            ["bytes32", "uint256", "address", "uint64", "uint256", "bytes32"],
            [DOMAIN_TAG, CHAIN_ID, Web3.to_checksum_address(SCORING), epoch, 8, root],
        )
    )
    assert commitment_digest(CHAIN_ID, SCORING, epoch, 8, root) == expected


def test_sign_recover_roundtrip():
    acct = Account.create()
    epoch = 7
    root = "0x" + "12" * 32
    sig = sign_commitment(acct, CHAIN_ID, SCORING, epoch, 8, root)
    recovered = recover_commitment_signer(CHAIN_ID, SCORING, epoch, 8, root, sig)
    assert recovered.lower() == acct.address.lower()


def test_signature_is_bound_to_epoch_and_root():
    acct = Account.create()
    root = "0x" + "12" * 32
    sig = sign_commitment(acct, CHAIN_ID, SCORING, 7, 8, root)
    # A different epoch recovers to a different (wrong) address — the binding holds.
    other = recover_commitment_signer(CHAIN_ID, SCORING, 8, 8, root, sig)
    assert other.lower() != acct.address.lower()


def test_signature_is_bound_to_chain_and_registry():
    acct = Account.create()
    root = "0x" + "12" * 32
    sig = sign_commitment(acct, CHAIN_ID, SCORING, 7, 8, root)
    # Replaying the signature against another deployment / chain does not recover the signer.
    assert recover_commitment_signer(1, SCORING, 7, 8, root, sig).lower() != acct.address.lower()
    assert recover_commitment_signer(CHAIN_ID, "0x" + "ff" * 20, 7, 8, root, sig).lower() != acct.address.lower()
