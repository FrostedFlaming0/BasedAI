// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStakingVault
/// @notice Stakes BASED to (Brain, validator) tuples. Emissions accrue to validators
///         which then distribute to their stakers proportionally.
interface IStakingVault {
    event Staked(uint256 indexed brainId, address indexed validator, address indexed staker, uint256 amount);
    event UnstakeRequested(
        uint256 indexed brainId, address indexed validator, address indexed staker, uint256 amount, uint64 unlockAt
    );
    event UnstakeClaimed(uint256 indexed brainId, address indexed validator, address indexed staker, uint256 amount);
    event Slashed(uint256 indexed brainId, address indexed validator, uint256 amount, bytes32 reason);
    event RewardAccrued(uint256 indexed brainId, address indexed validator, uint256 amount);

    error InvalidAmount();
    error UnstakeNotReady();
    error InsufficientStake();
    error OnlyScoringRegistry();
    error NoPendingUnstake();
    error PendingUnstakeExists();
    error NoStakeToReward();
    /// @notice A fully-slashed pool (zero assets, nonzero shares) cannot accept new deposits: a 1:1
    ///         mint would let the stale, valueless shares confiscate part of the new deposit.
    error PoolInsolvent();
    /// @notice The deposit would mint zero shares (dust vs. a reward-grown pool); reject so a
    ///         depositor never forfeits their stake to existing holders.
    error ZeroShares();

    function UNSTAKE_COOLDOWN() external view returns (uint64);
    function CENTRALIZATION_CAP_BPS() external view returns (uint16);
    function REWARDER_ROLE() external view returns (bytes32);

    /// @notice Accrue fee reward into a (brain, validator) pool; raises every staker's share value
    ///         pro-rata. Only callable by a REWARDER_ROLE holder (the RewardDistributor).
    function notifyReward(uint256 brainId, address validator, uint256 amount) external;

    function stake(uint256 brainId, address validator, uint256 amount) external;
    function requestUnstake(uint256 brainId, address validator, uint256 amount) external;
    function claimUnstake(uint256 brainId, address validator) external;

    /// @notice Slashes stake from a validator. Only callable by ScoringRegistry on proven misbehavior.
    function slash(uint256 brainId, address validator, uint256 amount, bytes32 reason) external;

    function totalStaked() external view returns (uint256);
    function brainStake(uint256 brainId) external view returns (uint256);
    function validatorStake(uint256 brainId, address validator) external view returns (uint256);
    function stakerBalance(uint256 brainId, address validator, address staker) external view returns (uint256);

    /// @notice Asset value of a staker's pending (cooldown) unstake; still slashable until claimed.
    function pendingBalance(uint256 brainId, address validator, address staker) external view returns (uint256);

    /// @notice Effective stake for emission weighting, capped at CENTRALIZATION_CAP_BPS of total.
    function effectiveBrainStake(uint256 brainId) external view returns (uint256);

    // --- Historical snapshots (timestamp clock; for snapshot-based governance) ---

    /// @notice The clock used for checkpoints — wall-clock seconds (ERC-6372 mode=timestamp).
    function clock() external view returns (uint48);

    /// @notice Brain stake (assets) as of a past timepoint, for snapshot voting.
    function getPastBrainStake(uint256 brainId, uint48 timepoint) external view returns (uint256);

    /// @notice Total stake (assets) as of a past timepoint, for snapshot voting.
    function getPastTotalStaked(uint48 timepoint) external view returns (uint256);
}
