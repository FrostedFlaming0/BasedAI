// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IScoringRegistry} from "../interfaces/IScoringRegistry.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";

/// @title ScoringRegistry
/// @notice Per-epoch Merkle commitments to miner scores with validator co-signatures
///         and an equivocation-based fraud proof system.
contract ScoringRegistry is IScoringRegistry {
    using MessageHashUtils for bytes32;

    uint64 public constant EPOCH_LENGTH = 1 hours;
    uint64 public constant CHALLENGE_WINDOW = 1 hours;
    uint16 public constant MIN_QUORUM_BPS = 5_001; // strictly greater than 50%

    IStakingVault public immutable STAKING;
    uint64 public immutable GENESIS_TIMESTAMP;

    mapping(uint64 epoch => EpochCommitment) private _epochs;
    /// @dev tracks per-validator signed root for equivocation proofs
    mapping(uint64 epoch => mapping(address validator => bytes32 signedRoot)) public signedRoots;

    constructor(IStakingVault staking, uint64 genesisTimestamp) {
        STAKING = staking;
        GENESIS_TIMESTAMP = genesisTimestamp;
    }

    function currentEpoch() public view returns (uint64) {
        if (block.timestamp < GENESIS_TIMESTAMP) return 0;
        return uint64((block.timestamp - GENESIS_TIMESTAMP) / EPOCH_LENGTH);
    }

    function getEpoch(uint64 epoch) external view returns (EpochCommitment memory) {
        return _epochs[epoch];
    }

    function proposeEpoch(
        uint64 epoch,
        bytes32 merkleRoot,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external {
        if (_epochs[epoch].merkleRoot != bytes32(0)) revert EpochAlreadyProposed();
        require(signers.length == signatures.length, "length mismatch");

        bytes32 digest = keccak256(abi.encode(epoch, merkleRoot)).toEthSignedMessageHash();

        uint256 stakeSum;
        address last;
        for (uint256 i = 0; i < signers.length; i++) {
            address signer = signers[i];
            // require sorted ascending to prevent duplicates
            require(signer > last, "signers not sorted");
            last = signer;

            address recovered = ECDSA.recover(digest, signatures[i]);
            if (recovered != signer) revert InvalidSignature();

            // Sum signer stake across all brains. (More rigorous schemes restrict to per-Brain
            // signers; v1 accepts any registered validator with stake.)
            uint256 totalSignerStake = _signerStakeAcrossBrains(signer);
            stakeSum += totalSignerStake;

            // Record the signed root for equivocation detection.
            signedRoots[epoch][signer] = merkleRoot;
        }

        uint256 minStake = (STAKING.totalStaked() * MIN_QUORUM_BPS) / 10_000;
        if (stakeSum < minStake) revert InsufficientSignerStake();

        _epochs[epoch] = EpochCommitment({
            merkleRoot: merkleRoot,
            finalizedAt: 0,
            signerCount: uint32(signers.length),
            signerStake: stakeSum
        });

        emit EpochProposed(epoch, merkleRoot, stakeSum);
    }

    function finalizeEpoch(uint64 epoch) external {
        EpochCommitment storage c = _epochs[epoch];
        if (c.merkleRoot == bytes32(0)) revert EpochNotProposed();
        if (c.finalizedAt != 0) return;

        uint64 epochEnd = GENESIS_TIMESTAMP + (epoch + 1) * EPOCH_LENGTH;
        if (block.timestamp < epochEnd + CHALLENGE_WINDOW) revert ChallengeWindowOpen();

        c.finalizedAt = uint64(block.timestamp);
        emit EpochFinalized(epoch, c.merkleRoot);
    }

    function challengeEquivocation(
        uint64 epoch,
        bytes32 rootA,
        bytes calldata sigA,
        bytes32 rootB,
        bytes calldata sigB,
        address validator
    ) external {
        require(rootA != rootB, "same root");

        bytes32 digestA = keccak256(abi.encode(epoch, rootA)).toEthSignedMessageHash();
        bytes32 digestB = keccak256(abi.encode(epoch, rootB)).toEthSignedMessageHash();

        if (ECDSA.recover(digestA, sigA) != validator) revert InvalidSignature();
        if (ECDSA.recover(digestB, sigB) != validator) revert InvalidSignature();

        // Slash this validator across all brains they have stake on. v1 simplification: slash 100%
        // of their stake on Brain 0; production would iterate the validator's brains via an indexer.
        uint256 slashed = STAKING.validatorStake(0, validator);
        if (slashed > 0) {
            STAKING.slash(0, validator, slashed, "EQUIVOCATION");
        }

        // Invalidate any commitment that included this validator's signature for this epoch.
        // (v1 simplification — production would track signer set per epoch.)
        emit ValidatorSlashed(epoch, validator, "EQUIVOCATION");
        emit EpochChallenged(epoch, msg.sender, "EQUIVOCATION");
    }

    function verifyScore(
        uint64 epoch,
        uint256 brainId,
        address miner,
        uint256 score,
        bytes32[] calldata proof
    ) external view returns (bool) {
        EpochCommitment storage c = _epochs[epoch];
        if (c.merkleRoot == bytes32(0) || c.finalizedAt == 0) return false;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(brainId, miner, score))));
        return MerkleProof.verify(proof, c.merkleRoot, leaf);
    }

    /// @dev v1 placeholder — production would track validator memberships across brains.
    function _signerStakeAcrossBrains(address signer) internal view returns (uint256) {
        // Sum a fixed-size scan of brain IDs; a real implementation uses an indexer or
        // requires signers to declare which Brain they're signing for.
        uint256 total;
        for (uint256 i = 0; i < 8; i++) {
            total += STAKING.validatorStake(i, signer);
        }
        return total;
    }
}
