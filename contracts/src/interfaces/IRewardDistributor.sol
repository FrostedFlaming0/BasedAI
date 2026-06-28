// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRewardDistributor
/// @notice Accumulates the validator share of inference fees per Brain and distributes it,
///         pro-rata by stake, across that Brain's full active validator set (into StakingVault,
///         where it accrues to each validator's stakers).
interface IRewardDistributor {
    event ValidatorFeesRecorded(uint256 indexed brainId, uint256 amount);
    event ValidatorFeesDistributed(uint256 indexed brainId, uint256 amount, uint256 validatorCount);

    error NotMarket();
    error NothingToDistribute();
    error IncompleteValidatorSet();
    error ValidatorsNotSorted();
    error NotAValidator();
    error NoValidatorStake();
    error ZeroAmount();

    /// @notice Record (and take custody of) `amount` of validator-share fees for `brainId`.
    ///         Only the market (MARKET_ROLE) may call; the market must transfer the BASED first.
    function recordFees(uint256 brainId, uint256 amount) external;

    /// @notice Distribute the accrued validator fees for `brainId` across its FULL active validator
    ///         set, pro-rata by stake. `validators` must be the complete, sorted-ascending,
    ///         registered set (length == validatorCount) so no validator can be griefed by omission.
    function distribute(uint256 brainId, address[] calldata validators) external;

    function pendingValidatorFees(uint256 brainId) external view returns (uint256);
}
