"""Tests for Merkle tree construction matching on-chain verification."""

from basedai_validator.merkle import ScoreLeaf, build_merkle_root, build_proof
from eth_utils import keccak


def test_root_is_deterministic():
    leaves = [
        ScoreLeaf(1, "0x" + "11" * 20, 500_000),
        ScoreLeaf(1, "0x" + "22" * 20, 750_000),
        ScoreLeaf(2, "0x" + "33" * 20, 250_000),
    ]
    root1, _ = build_merkle_root(leaves)
    root2, _ = build_merkle_root(leaves)
    assert root1 == root2
    assert len(root1) == 32


def test_proof_validates_against_root():
    leaves = [
        ScoreLeaf(1, "0x" + f"{i:040x}", i * 1000)
        for i in range(1, 9)
    ]
    root, _ = build_merkle_root(leaves)

    target = leaves[3]
    proof = build_proof(leaves, target)

    # Manually verify the proof using the same sorted-pair rule as OZ MerkleProof.
    leaf_hash = target.hash()
    computed = leaf_hash
    for sibling in proof:
        pair = (computed + sibling) if computed <= sibling else (sibling + computed)
        computed = keccak(pair)

    assert computed == root


def test_empty_tree_is_zero_root():
    root, _ = build_merkle_root([])
    assert root == b"\x00" * 32
