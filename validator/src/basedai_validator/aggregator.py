"""Signature aggregator — collects per-validator epoch-commitment signatures and submits the
co-signed Merkle root to `ScoringRegistry.proposeEpoch`.

Architecture (whitepaper 6.2): each validator independently builds and signs a domain-separated
commitment over (epoch, root). They POST the signature here. The aggregator groups signatures by
root, and once the signers backing a root exceed the on-chain quorum (>50% of total validator
stake) it assembles them in the ascending-address order `proposeEpoch` requires and submits.

The core (`CommitmentAggregator`) is chain-agnostic: stake lookups and the on-chain submission are
injected as callables, so it is fully unit-testable. `from_chain` wires the real web3 contracts.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Callable, Optional

import structlog
from web3 import Web3

from .commitment import recover_commitment_signer
from .merkle import ScoreLeaf, build_merkle_root

log = structlog.get_logger()

# Mirrors ScoringRegistry.MIN_QUORUM_BPS (strictly greater than 50%).
MIN_QUORUM_BPS = 5_001
# Mirrors ScoringRegistry.MAX_BRAINS (the capped Brain id space scanned for signer stake).
MAX_BRAINS = 64


def _normalize_root(root: str | bytes) -> str:
    if isinstance(root, bytes):
        root = "0x" + root.hex()
    return root.lower()


class CommitmentAggregator:
    """Collects signatures and proposes the best-supported root once quorum is reached."""

    def __init__(
        self,
        chain_id: int,
        scoring_registry: str,
        stake_of: Callable[[int, str], int],
        total_stake: Callable[[int], int],
        propose_fn: Callable[[int, int, bytes, list[str], list[str]], str],
        min_quorum_bps: int = MIN_QUORUM_BPS,
    ):
        self.chain_id = chain_id
        self.scoring_registry = scoring_registry
        self._stake_of = stake_of
        self._total_stake = total_stake
        self._propose_fn = propose_fn
        self._min_quorum_bps = min_quorum_bps
        # (epoch, brain, normalized_root) -> {signer_address: signature}
        self._pending: dict[tuple[int, int, str], dict[str, str]] = {}
        # epochs already proposed, so we don't double-submit.
        self._proposed: set[tuple[int, int]] = set()

    def add_commitment(self, epoch: int, brain_id: int, root: str | bytes, signer: str, signature: str) -> bool:
        """Verify and store a validator's signature. Returns False on a forged/mismatched signature."""
        recovered = recover_commitment_signer(self.chain_id, self.scoring_registry, epoch, brain_id, root, signature)
        if recovered.lower() != signer.lower():
            log.warning("aggregator.signature_mismatch", epoch=epoch, claimed=signer, recovered=recovered)
            return False
        key = (int(epoch), int(brain_id), _normalize_root(root))
        self._pending.setdefault(key, {})[Web3.to_checksum_address(recovered)] = (
            signature if signature.startswith("0x") else "0x" + signature
        )
        return True

    def backing_stake(self, epoch: int, brain_id: int, root: str | bytes) -> int:
        signers = self._pending.get((int(epoch), int(brain_id), _normalize_root(root)), {})
        return sum(self._stake_of(brain_id, s) for s in signers)

    def quorum_met(self, epoch: int, brain_id: int, root: str | bytes) -> bool:
        total = self._total_stake(brain_id)
        if total == 0:
            return False
        # CEIL-round to mirror ScoringRegistry exactly, so we never assemble a root that the contract
        # would then reject for falling a wei short of the quorum.
        need = (total * self._min_quorum_bps + 9_999) // 10_000
        return self.backing_stake(epoch, brain_id, root) >= need

    def assemble(self, epoch: int, brain_id: int, root: str | bytes) -> tuple[list[str], list[str]]:
        """Return (signers, signatures) sorted by ascending signer address, as proposeEpoch wants."""
        signers = self._pending.get((int(epoch), int(brain_id), _normalize_root(root)), {})
        ordered = sorted(signers.keys(), key=lambda a: int(a, 16))
        return ordered, [signers[a] for a in ordered]

    def best_root(self, epoch: int, brain_id: int) -> Optional[str]:
        """The root for `epoch` with the greatest backing stake (None if no signatures)."""
        roots = [r for (e, b, r) in self._pending if e == int(epoch) and b == int(brain_id)]
        if not roots:
            return None
        return max(roots, key=lambda r: self.backing_stake(epoch, brain_id, r))

    def try_propose(self, epoch: int, brain_id: int) -> Optional[str]:
        """If the best-supported root for `epoch` meets quorum, submit it. Returns the tx hash."""
        key = (int(epoch), int(brain_id))
        if key in self._proposed:
            return None
        root = self.best_root(epoch, brain_id)
        if root is None or not self.quorum_met(epoch, brain_id, root):
            return None
        signers, sigs = self.assemble(epoch, brain_id, root)
        root_bytes = bytes.fromhex(root[2:])
        tx = self._propose_fn(int(epoch), int(brain_id), root_bytes, signers, sigs)
        self._proposed.add(key)
        log.info("aggregator.proposed", epoch=epoch, root=root, signers=len(signers), tx=tx)
        return tx

    @classmethod
    def from_chain(cls, chain_id: int, scoring_registry: str, staking_vault: str, w3: Web3, account) -> "CommitmentAggregator":
        """Wire a chain-backed aggregator. `account` sends the proposeEpoch transaction."""
        staking = w3.eth.contract(
            address=Web3.to_checksum_address(staking_vault),
            abi=[
                {"name": "validatorStake", "type": "function", "stateMutability": "view",
                 "inputs": [{"name": "brainId", "type": "uint256"}, {"name": "validator", "type": "address"}],
                 "outputs": [{"type": "uint256"}]},
                {"name": "brainStake", "type": "function", "stateMutability": "view",
                 "inputs": [{"name": "brainId", "type": "uint256"}], "outputs": [{"type": "uint256"}]},
            ],
        )
        scoring = w3.eth.contract(
            address=Web3.to_checksum_address(scoring_registry),
            abi=[
                {"name": "proposeEpoch", "type": "function", "stateMutability": "nonpayable",
                 "inputs": [
                     {"name": "epoch", "type": "uint64"}, {"name": "brainId", "type": "uint256"}, {"name": "merkleRoot", "type": "bytes32"},
                     {"name": "signers", "type": "address[]"}, {"name": "signatures", "type": "bytes[]"}],
                 "outputs": []},
            ],
        )

        def stake_of(brain_id: int, addr: str) -> int:
            checksum = Web3.to_checksum_address(addr)
            return staking.functions.validatorStake(brain_id, checksum).call()

        def total_stake(brain_id: int) -> int:
            return staking.functions.brainStake(brain_id).call()

        def propose_fn(epoch: int, brain_id: int, root_bytes: bytes, signers: list[str], sigs: list[str]) -> str:
            sig_bytes = [bytes.fromhex(s[2:] if s.startswith("0x") else s) for s in sigs]
            tx = scoring.functions.proposeEpoch(epoch, brain_id, root_bytes, signers, sig_bytes).build_transaction({
                "from": account.address,
                "nonce": w3.eth.get_transaction_count(account.address, "pending"),
            })
            signed = account.sign_transaction(tx)
            raw = getattr(signed, "rawTransaction", None) or signed.raw_transaction
            return w3.eth.send_raw_transaction(raw).hex()

        return cls(chain_id, scoring_registry, stake_of, total_stake, propose_fn)


class CanonicalCandidatePool:
    """Build one quorum-backed canonical score root per (epoch, Brain).

    Validators submit independently observed score maps. Once the submitters represent quorum,
    scores are combined by stake-weighted median and the resulting root is frozen. Every validator
    then signs this same root through CommitmentAggregator.
    """

    def __init__(self, stake_of: Callable[[int, str], int], total_stake: Callable[[int], int], min_quorum_bps: int = MIN_QUORUM_BPS):
        self._stake_of = stake_of
        self._total_stake = total_stake
        self._min_quorum_bps = min_quorum_bps
        self._candidates: dict[tuple[int, int], dict[str, dict[str, int]]] = defaultdict(dict)
        self._frozen: dict[tuple[int, int], tuple[str, list[dict]]] = {}

    def add(self, epoch: int, brain_id: int, signer: str, scores: list[dict]) -> Optional[tuple[str, list[dict]]]:
        key = (int(epoch), int(brain_id))
        if key in self._frozen:
            return self._frozen[key]
        if self._stake_of(brain_id, signer) <= 0:
            raise ValueError("candidate signer has no Brain-local stake")
        normalized: dict[str, int] = {}
        for row in scores:
            miner = Web3.to_checksum_address(row["miner"])
            score = int(row["score"])
            if score < 0 or score > 1_000_000:
                raise ValueError("score out of range")
            normalized[miner] = score
        if not normalized:
            raise ValueError("empty score candidate")
        self._candidates[key][Web3.to_checksum_address(signer)] = normalized

        contributors = self._candidates[key]
        total = self._total_stake(brain_id)
        need = (total * self._min_quorum_bps + 9_999) // 10_000 if total else 1
        if sum(self._stake_of(brain_id, s) for s in contributors) < need:
            return None

        miners = sorted({m for candidate in contributors.values() for m in candidate})
        rows: list[dict] = []
        for miner in miners:
            weighted = sorted(
                (candidate[miner], self._stake_of(brain_id, signer))
                for signer, candidate in contributors.items()
                if miner in candidate and self._stake_of(brain_id, signer) > 0
            )
            weight = sum(w for _, w in weighted)
            if not weighted or weight < need:
                continue  # omission by a minority cannot create a canonical leaf
            acc = 0
            median = weighted[-1][0]
            for score, w in weighted:
                acc += w
                if acc * 2 >= weight:
                    median = score
                    break
            rows.append({"miner": miner, "score": median})
        if not rows:
            raise ValueError("no score has quorum coverage")
        root, _ = build_merkle_root([ScoreLeaf(brain_id, r["miner"], r["score"]) for r in rows])
        frozen = ("0x" + root.hex(), rows)
        self._frozen[key] = frozen
        return frozen

    def get(self, epoch: int, brain_id: int) -> Optional[tuple[str, list[dict]]]:
        return self._frozen.get((int(epoch), int(brain_id)))
