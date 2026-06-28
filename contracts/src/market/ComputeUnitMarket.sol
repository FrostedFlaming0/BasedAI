// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ISubnetRegistry} from "../interfaces/ISubnetRegistry.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";

/// @title ComputeUnitMarket
/// @notice User spending accounts for inference. Miners submit user-signed receipts to claim payment.
/// @dev    Hardened over v1:
///         - The signed receipt binds the DELIVERED output (`responseHash`) and the FINAL
///           `amount` (the actual cost, which the client counter-signs only after receiving the
///           response). The miner can neither inflate the charge nor mutate the receipt without
///           invalidating the signature. (Fixes the broken response binding / full-budget overcharge.)
///         - Funds cannot be yanked out from under an in-flight receipt: withdrawals are subject to
///           a delay (`WITHDRAW_DELAY`) that exceeds the receipt lifetime, and any redemption during
///           the delay debits the balance first. (Fixes the withdraw-front-runs-redeem free-inference race.)
///         - Redemption now SPLITS the payment per the Brain's configured fee split (default
///           70% miner / 22% validators / 8% owner); the validator share is pushed to the
///           RewardDistributor where it accrues to validators' stakers. (Implements the v2 fee economy.)
///         - An emergency PAUSER (bootstrap guardian, later governance) can halt deposits and
///           redemptions as a circuit breaker; withdrawals stay open so a pause never traps funds.
contract ComputeUnitMarket is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    /// @notice May pause/unpause the market (emergency circuit breaker only — cannot move funds).
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Receipts must expire within this horizon, and withdrawals wait at least this long,
    ///      guaranteeing a miner can always redeem a signed receipt before its collateral can leave.
    uint64 public constant WITHDRAW_DELAY = 1 days;
    uint64 public constant MAX_RECEIPT_LIFETIME = 1 days;

    struct Receipt {
        address user;
        address miner;
        uint256 brainId;
        bytes32 promptHash;
        bytes32 responseHash; // hash of the DELIVERED response (non-zero, counter-signed)
        uint256 amount; // FINAL actual cost (<= the budget the user agreed to)
        uint64 expiry;
        uint256 nonce;
    }

    struct PendingWithdrawal {
        uint256 amount;
        uint64 readyAt;
    }

    uint16 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable BASED;
    ISubnetRegistry public immutable REGISTRY;
    IRewardDistributor public immutable REWARD_DISTRIBUTOR;

    /// @notice Maximum a pre-authorization receipt (sentinel responseHash, signed before any output
    ///         exists) may draw. A pre-auth is a bounded fallback so a miner is never wholly unpaid
    ///         for delivered work; full payment requires the client-counter-signed FINAL receipt
    ///         (bound to the real, post-delivery responseHash). Governance-tunable via the admin.
    uint256 public maxReservation;

    /// @notice Immutable-by-default protocol pricing (governance-tunable via the admin/timelock).
    ///         The charge is `pricePerRequest + pricePerByte * (promptBytes + responseBytes)`.
    ///         This is the canonical, on-chain source of truth a client reads to INDEPENDENTLY derive
    ///         the charge from authenticated token usage — so a miner can no longer bill the full
    ///         budget regardless of work done (the original overcharge). 0/0 disables metered pricing
    ///         (clients then fall back to their budget ceiling).
    uint256 public pricePerByte;
    uint256 public pricePerRequest;

    mapping(address user => uint256) public balances;
    mapping(address user => mapping(uint256 nonce => bool)) public usedNonces;
    mapping(address user => PendingWithdrawal) public pendingWithdrawals;

    event Deposited(address indexed user, uint256 amount);
    event WithdrawalRequested(address indexed user, uint256 amount, uint64 readyAt);
    event WithdrawalCancelled(address indexed user);
    event Withdrawn(address indexed user, uint256 amount);
    event ReceiptRedeemed(
        address indexed user, address indexed miner, uint256 indexed brainId, uint256 amount, uint256 nonce
    );
    event MaxReservationUpdated(uint256 maxReservation);
    event PricingUpdated(uint256 pricePerByte, uint256 pricePerRequest);
    /// @notice Emitted on every redemption with the realized fee split.
    event FeeSplit(
        uint256 indexed brainId,
        address indexed miner,
        address owner,
        uint256 minerAmount,
        uint256 ownerAmount,
        uint256 validatorAmount
    );

    error InsufficientBalance();
    error ExpiredReceipt();
    error ReceiptLifetimeTooLong();
    error EmptyResponse();
    error NonceUsed();
    error InvalidSignature();
    error InvalidAmount();
    error NoPendingWithdrawal();
    error WithdrawalNotReady();
    error ReservationExceedsCap();

    constructor(
        IERC20 based,
        ISubnetRegistry registry,
        IRewardDistributor rewardDistributor,
        uint256 maxReservation_,
        uint256 pricePerByte_,
        uint256 pricePerRequest_,
        address admin
    ) {
        BASED = based;
        REGISTRY = registry;
        REWARD_DISTRIBUTOR = rewardDistributor;
        maxReservation = maxReservation_;
        require(pricePerByte_ > 0 || pricePerRequest_ > 0, "pricing disabled");
        pricePerByte = pricePerByte_;
        pricePerRequest = pricePerRequest_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit MaxReservationUpdated(maxReservation_);
        emit PricingUpdated(pricePerByte_, pricePerRequest_);
    }

    /// @notice The canonical charge for an inference given its token usage. Clients read this to
    ///         derive — independently of the miner — the maximum they will counter-sign for.
    function quote(uint256 promptBytes, uint256 responseBytes) public view returns (uint256) {
        return pricePerRequest + pricePerByte * (promptBytes + responseBytes);
    }

    // --- Circuit breaker (emergency only; cannot move or seize funds) ---

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Governance tunes the pre-authorization draw cap (cannot move or seize funds).
    function setMaxReservation(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxReservation = newMax;
        emit MaxReservationUpdated(newMax);
    }

    /// @notice Governance tunes the metered price (cannot move or seize funds). Setting both to 0
    ///         disables on-chain metered pricing.
    function setPricing(uint256 newPricePerByte, uint256 newPricePerRequest) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPricePerByte > 0 || newPricePerRequest > 0, "pricing disabled");
        pricePerByte = newPricePerByte;
        pricePerRequest = newPricePerRequest;
        emit PricingUpdated(newPricePerByte, newPricePerRequest);
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        BASED.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Begin a withdrawal. Funds remain redeemable by miners during the delay; the
    ///         actual payout is `min(requested, balance at completion)`, so receipts redeemed in
    ///         the meantime take priority over the exiting user.
    function requestWithdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (balances[msg.sender] < amount) revert InsufficientBalance();
        uint64 readyAt = uint64(block.timestamp) + WITHDRAW_DELAY;
        pendingWithdrawals[msg.sender] = PendingWithdrawal({amount: amount, readyAt: readyAt});
        emit WithdrawalRequested(msg.sender, amount, readyAt);
    }

    function cancelWithdraw() external nonReentrant {
        if (pendingWithdrawals[msg.sender].readyAt == 0) revert NoPendingWithdrawal();
        delete pendingWithdrawals[msg.sender];
        emit WithdrawalCancelled(msg.sender);
    }

    function withdraw() external nonReentrant {
        PendingWithdrawal memory w = pendingWithdrawals[msg.sender];
        if (w.readyAt == 0) revert NoPendingWithdrawal();
        if (block.timestamp < w.readyAt) revert WithdrawalNotReady();

        uint256 bal = balances[msg.sender];
        uint256 amount = w.amount < bal ? w.amount : bal; // receipts redeemed during the delay win
        delete pendingWithdrawals[msg.sender];
        if (amount == 0) revert InsufficientBalance();

        balances[msg.sender] = bal - amount;
        BASED.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Miner redeems a user-signed final receipt to draw payment from the user's balance.
    /// @dev    The signature must cover the real `responseHash` and final `amount`; the user
    ///         counter-signs this only after receiving the response, so payment is bound to delivery.
    function redeem(Receipt calldata r, bytes calldata userSig) external nonReentrant whenNotPaused {
        if (block.timestamp > r.expiry) revert ExpiredReceipt();
        if (r.expiry > block.timestamp + MAX_RECEIPT_LIFETIME) revert ReceiptLifetimeTooLong();
        if (r.responseHash == bytes32(0)) revert EmptyResponse();
        if (r.amount == 0) revert InvalidAmount();
        // A pre-authorization receipt carries the deterministic sentinel responseHash the client
        // signs BEFORE any output exists (keccak(promptHash, nonce)). It is a bounded fallback, so
        // it can never draw more than `maxReservation`. A FINAL receipt — bound to the real,
        // client-counter-signed responseHash — is the only path that may bill the full amount. This
        // closes the full-budget pre-auth overcharge / charge-without-delivery at the contract level.
        if (r.responseHash == keccak256(abi.encodePacked(r.promptHash, bytes32(r.nonce))) && r.amount > maxReservation)
        {
            revert ReservationExceedsCap();
        }
        if (usedNonces[r.user][r.nonce]) revert NonceUsed();
        if (balances[r.user] < r.amount) revert InsufficientBalance();
        if (msg.sender != r.miner) revert InvalidSignature();

        bytes32 digest = _digest(r);
        if (ECDSA.recover(digest, userSig) != r.user) revert InvalidSignature();

        usedNonces[r.user][r.nonce] = true;
        balances[r.user] -= r.amount;

        _settle(r.brainId, r.miner, r.amount);

        emit ReceiptRedeemed(r.user, r.miner, r.brainId, r.amount, r.nonce);
    }

    /// @dev Splits `amount` per the Brain's configured fee split: owner share to the Brain owner,
    ///      validator share to the RewardDistributor (accrues to validators' stakers), remainder to
    ///      the miner. An inactive/unconfigured Brain pays the miner in full; a missing owner folds
    ///      its share into the miner so nothing is ever stranded. All BPS are of the gross `amount`.
    function _settle(uint256 brainId, address miner, uint256 amount) private {
        ISubnetRegistry.Subnet memory sn = REGISTRY.getSubnet(brainId);

        if (!sn.active) {
            BASED.safeTransfer(miner, amount);
            emit FeeSplit(brainId, miner, address(0), amount, 0, 0);
            return;
        }

        // ownerSplitBps is the owner's cut of the GROSS amount; the remaining "node share" is then
        // split between miner (minerShareBps of the node share) and validators (the rest).
        uint256 ownerAmount = (amount * sn.ownerSplitBps) / BPS_DENOMINATOR;
        uint256 nodeShare = amount - ownerAmount;
        uint256 minerAmount = (nodeShare * sn.minerShareBps) / BPS_DENOMINATOR;
        uint256 validatorAmount = nodeShare - minerAmount;

        // Owner share (fold into miner if no owner is recorded, rather than stranding it).
        if (ownerAmount > 0) {
            if (sn.owner != address(0)) {
                BASED.safeTransfer(sn.owner, ownerAmount);
            } else {
                minerAmount += ownerAmount;
                ownerAmount = 0;
            }
        }

        // Validator share -> RewardDistributor (custody first, then record the per-Brain accrual).
        if (validatorAmount > 0) {
            BASED.safeTransfer(address(REWARD_DISTRIBUTOR), validatorAmount);
            REWARD_DISTRIBUTOR.recordFees(brainId, validatorAmount);
        }

        BASED.safeTransfer(miner, minerAmount);
        emit FeeSplit(brainId, miner, sn.owner, minerAmount, ownerAmount, validatorAmount);
    }

    /// @notice The EIP-191 digest a user signs to authorize a receipt. Domain-separated by
    ///         contract address and chain id to prevent cross-contract / cross-chain replay.
    function receiptDigest(Receipt calldata r) external view returns (bytes32) {
        return _digest(r);
    }

    function _digest(Receipt calldata r) private view returns (bytes32) {
        return keccak256(
                abi.encode(
                    address(this),
                    block.chainid,
                    r.user,
                    r.miner,
                    r.brainId,
                    r.promptHash,
                    r.responseHash,
                    r.amount,
                    r.expiry,
                    r.nonce
                )
            ).toEthSignedMessageHash();
    }
}
