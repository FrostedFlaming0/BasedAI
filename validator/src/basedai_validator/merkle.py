"""Merkle tree construction matching the on-chain leaf encoding.

Leaf format (matching ScoringRegistry.verifyScore):
    leaf = keccak256(keccak256(abi.encode(brainId, miner, score)))

This double-hash pattern is OpenZeppelin's standard for protecting against
second-preimage attacks on internal nodes.
"""

from __future__ import annotations

from dataclasses import dataclass

from eth_abi import encode as abi_encode
from eth_utils import keccak


@dataclass
class ScoreLeaf:
    brain_id: int
    miner: str   # checksum address
    score: int   # fixed-point (score_fp)

    def hash(self) -> bytes:
        inner = keccak(abi_encode(["uint256", "address", "uint256"],
                                  [self.brain_id, self.miner, self.score]))
        return keccak(inner)


def build_merkle_root(leaves: list[ScoreLeaf]) -> tuple[bytes, list[bytes]]:
    """Build a Merkle root and return (root, sorted_leaf_hashes).

    Uses sorted-pairs hashing (OZ MerkleProof default).
    """
    if not leaves:
        return b"\x00" * 32, []

    hashed = sorted(leaf.hash() for leaf in leaves)
    layer = list(hashed)

    while len(layer) > 1:
        if len(layer) % 2 == 1:
            layer.append(layer[-1])
        next_layer = []
        for i in range(0, len(layer), 2):
            a, b = layer[i], layer[i + 1]
            pair = (a + b) if a <= b else (b + a)
            next_layer.append(keccak(pair))
        layer = next_layer

    return layer[0], hashed


def build_proof(leaves: list[ScoreLeaf], target: ScoreLeaf) -> list[bytes]:
    """Build a Merkle proof for `target` against the tree of `leaves`."""
    target_hash = target.hash()
    hashed = sorted(leaf.hash() for leaf in leaves)
    if target_hash not in hashed:
        raise ValueError("target leaf not in set")

    idx = hashed.index(target_hash)
    layer = list(hashed)
    proof: list[bytes] = []

    while len(layer) > 1:
        if len(layer) % 2 == 1:
            layer.append(layer[-1])
        sibling_idx = idx ^ 1
        proof.append(layer[sibling_idx])

        next_layer = []
        for i in range(0, len(layer), 2):
            a, b = layer[i], layer[i + 1]
            pair = (a + b) if a <= b else (b + a)
            next_layer.append(keccak(pair))
        layer = next_layer
        idx //= 2

    return proof
