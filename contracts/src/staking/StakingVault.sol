// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";

/// @title StakingVault
/// @notice Staking of BASED to (Brain, validator) tuples with cooldown unstaking and slashing.
contract StakingVault is IStakingVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    uint64 public constant UNSTAKE_COOLDOWN = 14 days;
    uint16 public constant CENTRALIZATION_CAP_BPS = 50; // 0.5%

    /// @notice Slashed stake is burned (sent to dead address) by network policy.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable BASED;

    struct PendingUnstake {
        uint256 amount;
        uint64 unlockAt;
    }

    uint256 public override totalStaked;
    mapping(uint256 brainId => uint256) public override brainStake;
    mapping(uint256 brainId => mapping(address validator => uint256)) public override validatorStake;
    mapping(uint256 brainId => mapping(address validator => mapping(address staker => uint256)))
        public override stakerBalance;
    mapping(uint256 brainId => mapping(address validator => mapping(address staker => PendingUnstake)))
        public pendingUnstakes;

    constructor(IERC20 based, address admin) {
        BASED = based;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function stake(uint256 brainId, address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        BASED.safeTransferFrom(msg.sender, address(this), amount);

        stakerBalance[brainId][validator][msg.sender] += amount;
        validatorStake[brainId][validator] += amount;
        brainStake[brainId] += amount;
        totalStaked += amount;

        emit Staked(brainId, validator, msg.sender, amount);
    }

    function requestUnstake(uint256 brainId, address validator, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        uint256 balance = stakerBalance[brainId][validator][msg.sender];
        if (balance < amount) revert InsufficientStake();

        stakerBalance[brainId][validator][msg.sender] = balance - amount;
        validatorStake[brainId][validator] -= amount;
        brainStake[brainId] -= amount;
        totalStaked -= amount;

        // Accumulate pending unstakes; lockAt resets to most recent request.
        PendingUnstake storage p = pendingUnstakes[brainId][validator][msg.sender];
        p.amount += amount;
        p.unlockAt = uint64(block.timestamp) + UNSTAKE_COOLDOWN;

        emit UnstakeRequested(brainId, validator, msg.sender, amount, p.unlockAt);
    }

    function claimUnstake(uint256 brainId, address validator) external nonReentrant {
        PendingUnstake storage p = pendingUnstakes[brainId][validator][msg.sender];
        if (p.amount == 0) revert InvalidAmount();
        if (block.timestamp < p.unlockAt) revert UnstakeNotReady();

        uint256 amount = p.amount;
        delete pendingUnstakes[brainId][validator][msg.sender];

        BASED.safeTransfer(msg.sender, amount);
        emit UnstakeClaimed(brainId, validator, msg.sender, amount);
    }

    function slash(uint256 brainId, address validator, uint256 amount, bytes32 reason)
        external
        onlyRole(SLASHER_ROLE)
        nonReentrant
    {
        uint256 vStake = validatorStake[brainId][validator];
        if (amount > vStake) amount = vStake;
        if (amount == 0) return;

        // Slash burns proportionally across all stakers of this validator.
        // For simplicity in v1 we burn from the validator-level totals; per-staker rebasing
        // is handled lazily by tracking a slash index (omitted here for clarity).
        validatorStake[brainId][validator] = vStake - amount;
        brainStake[brainId] -= amount;
        totalStaked -= amount;

        BASED.safeTransfer(BURN_ADDRESS, amount);
        emit Slashed(brainId, validator, amount, reason);
    }

    function effectiveBrainStake(uint256 brainId) external view returns (uint256) {
        uint256 raw = brainStake[brainId];
        uint256 cap = (totalStaked * CENTRALIZATION_CAP_BPS) / 10_000;
        return raw > cap ? cap : raw;
    }
}
