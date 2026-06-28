// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";

/// @title StakingVault
/// @notice Staking of BASED to (Brain, validator) tuples with cooldown unstaking and slashing.
/// @dev    Share-based accounting (ERC-4626-style, per validator). Slashing reduces the asset
///         pool only, so every staker — INCLUDING those in the unstake cooldown — bears the loss
///         pro-rata. This removes the v1 defect where slashing could be evaded by unstaking first
///         and where the last withdrawer was bricked by underflow. Brain/total stake is
///         checkpointed (timestamp clock) so governance can read snapshotted voting power.
contract StakingVault is IStakingVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    /// @notice May accrue fee rewards into a validator's pool (the RewardDistributor / market path).
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    uint64 public constant UNSTAKE_COOLDOWN = 14 days;
    uint16 public constant CENTRALIZATION_CAP_BPS = 50; // 0.5%

    /// @notice Slashed stake is burned (sent to dead address) by network policy.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable BASED;

    struct PendingUnstake {
        uint256 shares; // exiting shares — remain in the pool (slashable) until claimed
        uint64 unlockAt;
    }

    // --- Per-validator share pools ---
    // assets backing a (brain, validator) pool
    mapping(uint256 brainId => mapping(address validator => uint256)) private _vAssets;
    // total shares in a (brain, validator) pool (active + pending)
    mapping(uint256 brainId => mapping(address validator => uint256)) private _vShares;
    // a staker's active (non-exiting) shares
    mapping(uint256 brainId => mapping(address validator => mapping(address staker => uint256))) private _stakerShares;
    // a staker's pending (cooldown) unstake
    mapping(uint256 brainId => mapping(address validator => mapping(address staker => PendingUnstake))) private
        _pending;

    // --- Aggregate asset totals (kept in sync incrementally) ---
    uint256 private _totalAssets;
    mapping(uint256 brainId => uint256) private _brainAssets;

    // --- Historical checkpoints (timestamp clock) ---
    Checkpoints.Trace208 private _totalHistory;
    mapping(uint256 brainId => Checkpoints.Trace208) private _brainHistory;

    constructor(IERC20 based, address admin) {
        BASED = based;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // --- Clock (ERC-6372) ---

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    // --- Mutations ---

    function stake(uint256 brainId, address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (validator == address(0)) revert InvalidAmount();

        // A fully-slashed pool (assets == 0) that still has outstanding shares is INSOLVENT: a fresh
        // 1:1 mint here would hand the stale, valueless shares a pro-rata cut of this deposit. Refuse
        // rather than confiscate — the pool is dead, so stake to a new (brain, validator) pool instead.
        if (_vShares[brainId][validator] != 0 && _vAssets[brainId][validator] == 0) revert PoolInsolvent();

        BASED.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares = _assetsToShares(brainId, validator, amount);
        // After reward growth a dust deposit can round down to zero shares, which would silently gift
        // the deposit to existing stakers. Reject it so every depositor receives a real claim.
        if (shares == 0) revert ZeroShares();

        _stakerShares[brainId][validator][msg.sender] += shares;
        _vShares[brainId][validator] += shares;
        _vAssets[brainId][validator] += amount;
        _brainAssets[brainId] += amount;
        _totalAssets += amount;

        _checkpoint(brainId);
        emit Staked(brainId, validator, msg.sender, amount);
    }

    function requestUnstake(uint256 brainId, address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        PendingUnstake storage p = _pending[brainId][validator][msg.sender];
        // One outstanding cooldown at a time keeps the unlock timer un-gameable; claim first.
        if (p.shares != 0) revert PendingUnstakeExists();

        // Convert the requested asset amount to shares (round up so the user cannot exit more
        // value than they own through rounding), capped at what they actually hold so that
        // requesting one's full balance always succeeds despite floor/ceil rounding.
        uint256 owned = _stakerShares[brainId][validator][msg.sender];
        uint256 shares = _assetsToSharesUp(brainId, validator, amount);
        if (shares > owned) shares = owned;
        if (shares == 0) revert InsufficientStake();

        // Move shares from active to pending. They STAY in _vShares/_vAssets so they remain
        // slashable during the cooldown; only the staker's active balance drops.
        _stakerShares[brainId][validator][msg.sender] = owned - shares;
        p.shares = shares;
        p.unlockAt = uint64(block.timestamp) + UNSTAKE_COOLDOWN;

        emit UnstakeRequested(brainId, validator, msg.sender, _sharesToAssets(brainId, validator, shares), p.unlockAt);
    }

    function claimUnstake(uint256 brainId, address validator) external nonReentrant {
        PendingUnstake storage p = _pending[brainId][validator][msg.sender];
        uint256 shares = p.shares;
        if (shares == 0) revert NoPendingUnstake();
        if (block.timestamp < p.unlockAt) revert UnstakeNotReady();

        // Current asset value of the exiting shares (reflects any slashing during cooldown).
        uint256 amount = _sharesToAssets(brainId, validator, shares);

        delete _pending[brainId][validator][msg.sender];
        _vShares[brainId][validator] -= shares;
        _vAssets[brainId][validator] -= amount;
        _brainAssets[brainId] -= amount;
        _totalAssets -= amount;

        _checkpoint(brainId);
        BASED.safeTransfer(msg.sender, amount);
        emit UnstakeClaimed(brainId, validator, msg.sender, amount);
    }

    function slash(uint256 brainId, address validator, uint256 amount, bytes32 reason)
        external
        onlyRole(SLASHER_ROLE)
        nonReentrant
    {
        uint256 pool = _vAssets[brainId][validator];
        if (amount > pool) amount = pool;
        if (amount == 0) return;

        // Reduce ONLY the asset pool; shares are untouched, so every share (active and pending)
        // loses value pro-rata. No per-staker underflow is possible.
        _vAssets[brainId][validator] = pool - amount;
        _brainAssets[brainId] -= amount;
        _totalAssets -= amount;

        _checkpoint(brainId);
        BASED.safeTransfer(BURN_ADDRESS, amount);
        emit Slashed(brainId, validator, amount, reason);
    }

    /// @notice Accrue `amount` BASED as reward to a (brain, validator) pool. The assets are added
    ///         to the pool WITHOUT minting shares, so every existing staker's share value rises
    ///         pro-rata — this is the delegated-yield path (validators' fee income flows to their
    ///         stakers). Reverts if the pool has no shares, so reward is never stranded against a
    ///         pool that would mint zero shares to the next staker.
    /// @dev    Pulls `amount` from the caller (the RewardDistributor/market), which must approve first.
    function notifyReward(uint256 brainId, address validator, uint256 amount)
        external
        onlyRole(REWARDER_ROLE)
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (validator == address(0)) revert InvalidAmount();
        if (_vShares[brainId][validator] == 0) revert NoStakeToReward();

        BASED.safeTransferFrom(msg.sender, address(this), amount);

        _vAssets[brainId][validator] += amount;
        _brainAssets[brainId] += amount;
        _totalAssets += amount;

        _checkpoint(brainId);
        emit RewardAccrued(brainId, validator, amount);
    }

    // --- Views ---

    function totalStaked() external view returns (uint256) {
        return _totalAssets;
    }

    function brainStake(uint256 brainId) external view returns (uint256) {
        return _brainAssets[brainId];
    }

    function validatorStake(uint256 brainId, address validator) external view returns (uint256) {
        return _vAssets[brainId][validator];
    }

    function stakerBalance(uint256 brainId, address validator, address staker) external view returns (uint256) {
        return _sharesToAssets(brainId, validator, _stakerShares[brainId][validator][staker]);
    }

    function pendingBalance(uint256 brainId, address validator, address staker) external view returns (uint256) {
        return _sharesToAssets(brainId, validator, _pending[brainId][validator][staker].shares);
    }

    function effectiveBrainStake(uint256 brainId) external view returns (uint256) {
        uint256 raw = _brainAssets[brainId];
        uint256 cap = (_totalAssets * CENTRALIZATION_CAP_BPS) / 10_000;
        return raw > cap ? cap : raw;
    }

    function getPastBrainStake(uint256 brainId, uint48 timepoint) external view returns (uint256) {
        return _brainHistory[brainId].upperLookupRecent(timepoint);
    }

    function getPastTotalStaked(uint48 timepoint) external view returns (uint256) {
        return _totalHistory.upperLookupRecent(timepoint);
    }

    // --- Internal share math ---

    function _assetsToShares(uint256 brainId, address validator, uint256 amount) private view returns (uint256) {
        uint256 shares = _vShares[brainId][validator];
        uint256 assets = _vAssets[brainId][validator];
        if (shares == 0 || assets == 0) return amount; // 1:1 bootstrap
        return (amount * shares) / assets;
    }

    function _assetsToSharesUp(uint256 brainId, address validator, uint256 amount) private view returns (uint256) {
        uint256 shares = _vShares[brainId][validator];
        uint256 assets = _vAssets[brainId][validator];
        if (shares == 0 || assets == 0) return amount;
        return (amount * shares + assets - 1) / assets; // round up
    }

    function _sharesToAssets(uint256 brainId, address validator, uint256 shares) private view returns (uint256) {
        uint256 totalShares = _vShares[brainId][validator];
        if (totalShares == 0) return 0;
        return (shares * _vAssets[brainId][validator]) / totalShares;
    }

    function _checkpoint(uint256 brainId) private {
        uint48 now_ = clock();
        _totalHistory.push(now_, uint208(_totalAssets));
        _brainHistory[brainId].push(now_, uint208(_brainAssets[brainId]));
    }
}
