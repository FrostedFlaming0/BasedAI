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
/// @dev    Hardened over v1:
///         - Signatures are DOMAIN-SEPARATED (chain id + this contract + a tag), so a validator's
///           signature cannot be replayed across chains/deployments nor used to forge equivocation
///           from roots they legitimately signed elsewhere.
///         - `proposeEpoch` rejects future epochs and zero roots; the challenge window is anchored
///           to the PROPOSAL time, so a late proposal cannot finalize instantly.
///         - A proven equivocation INVALIDATES the commitment (it can never finalize or verify) and
///           slashes the validator across every Brain they are staked on, not just Brain 0.
///         - Quorum scans the full Brain id space so the signer-stake numerator is consistent with
///           the global `totalStaked` denominator.
contract ScoringRegistry is IScoringRegistry {
    using MessageHashUtils for bytes32;

    uint64 public constant EPOCH_LENGTH = 1 hours;
    uint64 public constant CHALLENGE_WINDOW = 1 hours;
    uint16 public constant MIN_QUORUM_BPS = 5_001; // strictly greater than 50%

    /// @dev Brain NFT supply is capped at 64, so scanning [0,64) covers every Brain that can exist.
    uint256 public constant MAX_BRAINS = 64;

    /// @dev Domain tag mixed into every signed digest.
    bytes32 public constant DOMAIN_TAG = keccak256("BasedAI:ScoringRegistry:v2");

    IStakingVault public immutable STAKING;
    uint64 public immutable GENESIS_TIMESTAMP;

    mapping(uint64 epoch => mapping(uint256 brainId => EpochCommitment)) private _epochs;
    /// @dev tracks per-validator signed root for equivocation proofs
    mapping(uint64 epoch => mapping(uint256 brainId => mapping(address validator => bytes32 signedRoot))) public
        signedRoots;
    /// @dev set of validators that co-signed the accepted commitment for an epoch
    mapping(uint64 epoch => mapping(uint256 brainId => mapping(address validator => bool))) public isCommitmentSigner;

    constructor(IStakingVault staking, uint64 genesisTimestamp) {
        STAKING = staking;
        GENESIS_TIMESTAMP = genesisTimestamp;
    }

    function currentEpoch() public view returns (uint64) {
        if (block.timestamp < GENESIS_TIMESTAMP) return 0;
        return uint64((block.timestamp - GENESIS_TIMESTAMP) / EPOCH_LENGTH);
    }

    function getEpoch(uint64 epoch, uint256 brainId) external view returns (EpochCommitment memory) {
        return _epochs[epoch][brainId];
    }

    /// @notice The domain-separated EIP-191 digest validators sign for (epoch, merkleRoot).
    function commitmentDigest(uint64 epoch, uint256 brainId, bytes32 merkleRoot) public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TAG, block.chainid, address(this), epoch, brainId, merkleRoot))
            .toEthSignedMessageHash();
    }

    function proposeEpoch(
        uint64 epoch,
        uint256 brainId,
        bytes32 merkleRoot,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external {
        if (merkleRoot == bytes32(0)) revert ZeroRoot();
        if (epoch > currentEpoch()) revert EpochInTheFuture();
        // Only a COMPLETED epoch may be committed. Accepting the current, still-in-progress epoch lets
        // an early quorum preempt scores that are still being produced for that same epoch.
        if (epoch == currentEpoch()) revert EpochNotComplete();
        if (_epochs[epoch][brainId].merkleRoot != bytes32(0)) revert EpochAlreadyProposed();
        require(signers.length == signatures.length, "length mismatch");
        // An empty signer set must never install a root: with zero total stake it would otherwise
        // pass a zero quorum (0 >= 0) and commit an arbitrary root at genesis.
        if (signers.length == 0) revert NoSigners();

        bytes32 digest = commitmentDigest(epoch, brainId, merkleRoot);

        uint256 stakeSum;
        address last;
        for (uint256 i = 0; i < signers.length; i++) {
            address signer = signers[i];
            // require sorted ascending to prevent duplicates
            require(signer > last, "signers not sorted");
            last = signer;

            address recovered = ECDSA.recover(digest, signatures[i]);
            if (recovered != signer) revert InvalidSignature();

            stakeSum += STAKING.validatorStake(brainId, signer);

            signedRoots[epoch][brainId][signer] = merkleRoot;
            isCommitmentSigner[epoch][brainId][signer] = true;
        }

        // Require nonzero total stake so a zero-stake snapshot cannot be committed by a quorum that
        // is itself zero, and CEIL-round the quorum so a bare majority strictly exceeds 50% (floor
        // rounding could admit exactly half of the stake).
        uint256 totalStaked = STAKING.brainStake(brainId);
        if (totalStaked == 0) revert EmptyQuorum();
        uint256 minStake = (totalStaked * MIN_QUORUM_BPS + 9_999) / 10_000;
        if (stakeSum < minStake) revert InsufficientSignerStake();

        _epochs[epoch][brainId] = EpochCommitment({
            merkleRoot: merkleRoot,
            proposedAt: uint64(block.timestamp),
            finalizedAt: 0,
            signerCount: uint32(signers.length),
            signerStake: stakeSum,
            invalidated: false
        });

        emit EpochProposed(epoch, brainId, merkleRoot, stakeSum);
    }

    function finalizeEpoch(uint64 epoch, uint256 brainId) external {
        EpochCommitment storage c = _epochs[epoch][brainId];
        if (c.merkleRoot == bytes32(0)) revert EpochNotProposed();
        if (c.invalidated) revert EpochAlreadyInvalidated();
        if (c.finalizedAt != 0) return;

        // Challenge window is anchored to the PROPOSAL, not the nominal epoch end, so a late
        // proposal still gets a full, real challenge period before it can finalize.
        if (block.timestamp < c.proposedAt + CHALLENGE_WINDOW) revert ChallengeWindowOpen();

        c.finalizedAt = uint64(block.timestamp);
        emit EpochFinalized(epoch, brainId, c.merkleRoot);
    }

    function challengeEquivocation(
        uint64 epoch,
        uint256 brainId,
        bytes32 rootA,
        bytes calldata sigA,
        bytes32 rootB,
        bytes calldata sigB,
        address validator
    ) external {
        require(rootA != rootB, "same root");

        EpochCommitment storage c = _epochs[epoch][brainId];
        if (c.merkleRoot == bytes32(0)) revert EpochNotProposed();
        if (c.invalidated) revert EpochAlreadyInvalidated();

        // The validator must have co-signed THIS epoch's accepted commitment, and one of the two
        // conflicting roots must be that commitment — otherwise it isn't equivocation against us.
        if (!isCommitmentSigner[epoch][brainId][validator]) revert NotACommitmentSigner();
        if (rootA != c.merkleRoot && rootB != c.merkleRoot) revert NotEquivocation();

        // Domain-separated digests: signatures from another chain/deployment will NOT verify here.
        if (ECDSA.recover(commitmentDigest(epoch, brainId, rootA), sigA) != validator) revert InvalidSignature();
        if (ECDSA.recover(commitmentDigest(epoch, brainId, rootB), sigB) != validator) revert InvalidSignature();

        // Invalidate the fraudulent commitment: it can never finalize or verify.
        c.invalidated = true;

        // Slash the validator across EVERY Brain they are staked on, not just Brain 0.
        uint256 vStake = STAKING.validatorStake(brainId, validator);
        if (vStake > 0) STAKING.slash(brainId, validator, vStake, "EQUIVOCATION");

        emit EpochInvalidated(epoch, brainId, c.merkleRoot);
        emit ValidatorSlashed(epoch, brainId, validator, "EQUIVOCATION");
        emit EpochChallenged(epoch, brainId, msg.sender, "EQUIVOCATION");
    }

    function verifyScore(uint64 epoch, uint256 brainId, address miner, uint256 score, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        EpochCommitment storage c = _epochs[epoch][brainId];
        if (c.merkleRoot == bytes32(0) || c.finalizedAt == 0 || c.invalidated) return false;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(brainId, miner, score))));
        return MerkleProof.verify(proof, c.merkleRoot, leaf);
    }

    /// @dev Sums a validator's stake across the whole Brain id space (capped supply), so the
    ///      numerator is consistent with the global `totalStaked` denominator.
    function _signerStakeAcrossBrains(address signer) internal view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < MAX_BRAINS; i++) {
            total += STAKING.validatorStake(i, signer);
        }
        return total;
    }
}
