// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";
import {ISubnetRegistry} from "../interfaces/ISubnetRegistry.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";

/// @title RewardDistributor
/// @notice Sink for the validator share (default 22%) of inference fees. The market transfers the
///         validator-share BASED here and calls {recordFees}; a permissionless keeper later calls
///         {distribute} with the Brain's complete validator set to push each validator's pro-rata
///         portion into the StakingVault, where it accrues to that validator's stakers as yield.
/// @dev    Design rationale (sealed in the Cypher Tempre design ring): the inference receipt names
///         only (brain, miner), so the validator share cannot be routed at redeem time. On-chain
///         enumeration of a Brain's validators is unbounded, so distribution is a separate,
///         pull-style call that takes the validator set as calldata and VALIDATES it is the full,
///         registered, sorted-distinct set — preventing reward concentration by omission. Bounded
///         by MAX_VALIDATORS_PER_BRAIN (256).
contract RewardDistributor is IRewardDistributor, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Held by the ComputeUnitMarket; the only caller allowed to record fees.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    IERC20 public immutable BASED;
    ISubnetRegistry public immutable REGISTRY;
    IStakingVault public immutable STAKING;

    /// @inheritdoc IRewardDistributor
    mapping(uint256 brainId => uint256) public pendingValidatorFees;

    constructor(IERC20 based, ISubnetRegistry registry, IStakingVault staking, address admin) {
        BASED = based;
        REGISTRY = registry;
        STAKING = staking;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IRewardDistributor
    function recordFees(uint256 brainId, uint256 amount) external {
        if (!hasRole(MARKET_ROLE, msg.sender)) revert NotMarket();
        if (amount == 0) revert ZeroAmount();
        // The market is expected to have transferred `amount` BASED to this contract already; we
        // only track the per-Brain accrual. Gating to MARKET_ROLE prevents an attacker inflating
        // the pending figure without funding it (which would brick distribution).
        pendingValidatorFees[brainId] += amount;
        emit ValidatorFeesRecorded(brainId, amount);
    }

    /// @inheritdoc IRewardDistributor
    function distribute(uint256 brainId, address[] calldata validators) external nonReentrant {
        uint256 pending = pendingValidatorFees[brainId];
        if (pending == 0) revert NothingToDistribute();

        uint256 n = REGISTRY.validatorCount(brainId);
        // Require the COMPLETE registered set so no validator can be omitted to concentrate rewards.
        if (n == 0 || validators.length != n) revert IncompleteValidatorSet();

        // Validate sorted-ascending (=> distinct) + registered, and sum stakes as the denominator.
        uint256[] memory stakes = new uint256[](n);
        uint256 totalStake;
        address last;
        for (uint256 i = 0; i < n; i++) {
            address v = validators[i];
            if (v <= last) revert ValidatorsNotSorted();
            last = v;
            if (!REGISTRY.isValidator(brainId, v)) revert NotAValidator();
            uint256 s = STAKING.validatorStake(brainId, v);
            stakes[i] = s;
            totalStake += s;
        }
        if (totalStake == 0) revert NoValidatorStake(); // nothing to weight by; fees stay pending

        // Zero the accrual up front (CEI); any rounding dust is carried forward below.
        pendingValidatorFees[brainId] = 0;

        // Approve exactly what we are about to push; StakingVault pulls per validator.
        BASED.forceApprove(address(STAKING), pending);

        uint256 distributed;
        uint256 paidValidators;
        for (uint256 i = 0; i < n; i++) {
            uint256 s = stakes[i];
            if (s == 0) continue; // zero-stake validator earns nothing this round
            uint256 share = (pending * s) / totalStake;
            if (share == 0) continue;
            distributed += share;
            paidValidators += 1;
            STAKING.notifyReward(brainId, validators[i], share);
        }

        // Reset the residual allowance to zero for hygiene (we approved `pending`, spent `distributed`).
        BASED.forceApprove(address(STAKING), 0);

        // Carry any sub-wei rounding dust forward to the next distribution.
        uint256 dust = pending - distributed;
        if (dust > 0) pendingValidatorFees[brainId] = dust;

        emit ValidatorFeesDistributed(brainId, distributed, paidValidators);
    }
}
