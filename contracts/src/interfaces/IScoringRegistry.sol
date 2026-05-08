// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IScoringRegistry
/// @notice Per-epoch Merkle-rooted miner scores. Validators co-sign roots; fraud proofs
///         can challenge equivocation or out-of-bounds scores.
interface IScoringRegistry {
    struct EpochCommitment {
        bytes32 merkleRoot;          // root over (brainId, miner, score) leaves
        uint64 finalizedAt;          // 0 until challenge window passes
        uint32 signerCount;          // number of validator signatures included
        uint256 signerStake;         // total stake of signers
    }

    event EpochProposed(uint64 indexed epoch, bytes32 merkleRoot, uint256 signerStake);
    event EpochFinalized(uint64 indexed epoch, bytes32 merkleRoot);
    event EpochChallenged(uint64 indexed epoch, address indexed challenger, bytes32 reason);
    event ValidatorSlashed(uint64 indexed epoch, address indexed validator, bytes32 reason);

    error EpochAlreadyProposed();
    error EpochNotProposed();
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error InsufficientSignerStake();
    error InvalidSignature();
    error InvalidProof();

    function EPOCH_LENGTH() external view returns (uint64);
    function CHALLENGE_WINDOW() external view returns (uint64);
    function MIN_QUORUM_BPS() external view returns (uint16);

    function currentEpoch() external view returns (uint64);

    /// @notice Posts a Merkle root with validator signatures. Starts challenge window.
    /// @param epoch Epoch number this commitment is for.
    /// @param merkleRoot Root committing to (brainId, miner, score) leaves.
    /// @param signers Sorted list of validator addresses (ascending).
    /// @param signatures EIP-191 signatures from each signer over (epoch, merkleRoot).
    function proposeEpoch(
        uint64 epoch,
        bytes32 merkleRoot,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external;

    /// @notice Finalizes an epoch after the challenge window has elapsed.
    function finalizeEpoch(uint64 epoch) external;

    /// @notice Submits a fraud proof that two contradictory commitments were signed by the same validator.
    function challengeEquivocation(
        uint64 epoch,
        bytes32 rootA,
        bytes calldata sigA,
        bytes32 rootB,
        bytes calldata sigB,
        address validator
    ) external;

    /// @notice Verifies a (brainId, miner, score) leaf against a finalized epoch root.
    function verifyScore(
        uint64 epoch,
        uint256 brainId,
        address miner,
        uint256 score,
        bytes32[] calldata proof
    ) external view returns (bool);

    function getEpoch(uint64 epoch) external view returns (EpochCommitment memory);
}
