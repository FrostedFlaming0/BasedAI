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

    error InvalidAmount();
    error UnstakeNotReady();
    error InsufficientStake();
    error OnlyScoringRegistry();

    function UNSTAKE_COOLDOWN() external view returns (uint64);
    function CENTRALIZATION_CAP_BPS() external view returns (uint16);

    function stake(uint256 brainId, address validator, uint256 amount) external;
    function requestUnstake(uint256 brainId, address validator, uint256 amount) external;
    function claimUnstake(uint256 brainId, address validator) external;

    /// @notice Slashes stake from a validator. Only callable by ScoringRegistry on proven misbehavior.
    function slash(uint256 brainId, address validator, uint256 amount, bytes32 reason) external;

    function totalStaked() external view returns (uint256);
    function brainStake(uint256 brainId) external view returns (uint256);
    function validatorStake(uint256 brainId, address validator) external view returns (uint256);
    function stakerBalance(uint256 brainId, address validator, address staker) external view returns (uint256);

    /// @notice Effective stake for emission weighting, capped at CENTRALIZATION_CAP_BPS of total.
    function effectiveBrainStake(uint256 brainId) external view returns (uint256);
}
