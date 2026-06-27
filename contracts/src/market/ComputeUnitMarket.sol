// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ComputeUnitMarket
/// @notice User spending accounts for inference. Miners batch-submit signed receipts to claim payment.
contract ComputeUnitMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    struct Receipt {
        address user;
        address miner;
        uint256 brainId;
        bytes32 promptHash;
        bytes32 responseHash;
        uint256 amount;
        uint64 expiry;
        uint256 nonce;
    }

    IERC20 public immutable BASED;

    mapping(address user => uint256) public balances;
    mapping(address user => mapping(uint256 nonce => bool)) public usedNonces;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event ReceiptRedeemed(
        address indexed user, address indexed miner, uint256 indexed brainId, uint256 amount, uint256 nonce
    );

    error InsufficientBalance();
    error ExpiredReceipt();
    error NonceUsed();
    error InvalidSignature();

    constructor(IERC20 based) {
        BASED = based;
    }

    function deposit(uint256 amount) external nonReentrant {
        BASED.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (balances[msg.sender] < amount) revert InsufficientBalance();
        balances[msg.sender] -= amount;
        BASED.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Miner redeems a user-signed receipt to draw payment from the user's balance.
    function redeem(Receipt calldata r, bytes calldata userSig) external nonReentrant {
        if (block.timestamp > r.expiry) revert ExpiredReceipt();
        if (usedNonces[r.user][r.nonce]) revert NonceUsed();
        if (balances[r.user] < r.amount) revert InsufficientBalance();
        if (msg.sender != r.miner) revert InvalidSignature();

        bytes32 digest = keccak256(
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

        if (ECDSA.recover(digest, userSig) != r.user) revert InvalidSignature();

        usedNonces[r.user][r.nonce] = true;
        balances[r.user] -= r.amount;
        BASED.safeTransfer(r.miner, r.amount);

        emit ReceiptRedeemed(r.user, r.miner, r.brainId, r.amount, r.nonce);
    }
}
