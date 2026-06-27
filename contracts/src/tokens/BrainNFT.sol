// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IBrainNFT} from "../interfaces/IBrainNFT.sol";

/// @title BrainNFT
/// @notice ERC-721 issued by staking either Pepecoin or $basedAI. Lives on Ethereum mainnet.
///         Total supply capped at 64; IDs 0–6 reserved for administrative Brains.
///         Stake-minted Brains are non-transferable; deactivation returns the original stake.
contract BrainNFT is ERC721Enumerable, ReentrancyGuard, AccessControl, IBrainNFT {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public constant MAX_SUPPLY = 64;
    uint256 public constant FIRST_PUBLIC_ID = 7;
    uint64 public constant STAKE_LOCK_DURATION = 90 days;

    /// @dev Stake amounts can be adjusted quarterly by governance, bounded to [50%, 200%]
    ///      of the previous value.
    uint256 public pepecoinStakeAmount;
    uint256 public basedStakeAmount;

    IERC20 public immutable PEPECOIN;
    IERC20 public immutable BASEDAI;

    uint256 private _totalSupply;
    uint256 public nextPublicId = FIRST_PUBLIC_ID;

    struct StakeRecord {
        address staker;
        uint64 unlockAt;
        StakeAsset asset;
        uint256 amount;
    }

    mapping(uint256 brainId => StakeRecord) public stakes;

    constructor(
        IERC20 pepecoin,
        IERC20 basedAI,
        uint256 initialPepecoinStake,
        uint256 initialBasedStake,
        address governance
    ) ERC721("BasedAI Brain", "BRAIN") {
        PEPECOIN = pepecoin;
        BASEDAI = basedAI;
        pepecoinStakeAmount = initialPepecoinStake;
        basedStakeAmount = initialBasedStake;
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(GOVERNANCE_ROLE, governance);
    }

    function stakeAssetOf(uint256 brainId) external view returns (StakeAsset) {
        return stakes[brainId].asset;
    }

    /// @notice Number of Brains currently in existence (manually accounted on mint/burn).
    function totalSupply() public view override(ERC721Enumerable, IBrainNFT) returns (uint256) {
        return _totalSupply;
    }

    // --- Mint paths ---

    function mintByPepecoinStake() external nonReentrant returns (uint256 brainId) {
        uint256 amount = pepecoinStakeAmount;
        PEPECOIN.safeTransferFrom(msg.sender, address(this), amount);
        brainId = _allocateBrainId();
        stakes[brainId] = StakeRecord({
            staker: msg.sender,
            unlockAt: uint64(block.timestamp) + STAKE_LOCK_DURATION,
            asset: StakeAsset.Pepecoin,
            amount: amount
        });
        _safeMint(msg.sender, brainId);
        emit BrainMintedByPepecoinStake(brainId, msg.sender, amount);
    }

    function mintByBasedStake() external nonReentrant returns (uint256 brainId) {
        uint256 amount = basedStakeAmount;
        BASEDAI.safeTransferFrom(msg.sender, address(this), amount);
        brainId = _allocateBrainId();
        stakes[brainId] = StakeRecord({
            staker: msg.sender,
            unlockAt: uint64(block.timestamp) + STAKE_LOCK_DURATION,
            asset: StakeAsset.BasedAI,
            amount: amount
        });
        _safeMint(msg.sender, brainId);
        emit BrainMintedByBasedStake(brainId, msg.sender, amount);
    }

    // --- Recovery ---

    function deactivateAndUnstake(uint256 brainId) external nonReentrant {
        StakeRecord memory record = stakes[brainId];
        if (record.asset == StakeAsset.None) revert WrongMintMethod();
        if (block.timestamp < record.unlockAt) revert StakeLockNotElapsed();

        address owner = ownerOf(brainId);
        if (owner != msg.sender) revert ERC721IncorrectOwner(msg.sender, brainId, owner);

        // Refund original staker (which equals owner since stake-minted is non-transferable).
        delete stakes[brainId];
        _burn(brainId);
        _totalSupply -= 1;

        IERC20 token = record.asset == StakeAsset.Pepecoin ? PEPECOIN : BASEDAI;
        token.safeTransfer(record.staker, record.amount);

        emit BrainBurned(brainId, owner, record.asset, record.amount);
    }

    // --- Governance ---

    function setStakeAmount(StakeAsset asset, uint256 newAmount) external onlyRole(GOVERNANCE_ROLE) {
        if (newAmount == 0) revert InvalidStakeAmount();

        if (asset == StakeAsset.Pepecoin) {
            uint256 old = pepecoinStakeAmount;
            // Floor 50%, ceiling 200% of previous value
            require(newAmount >= old / 2 && newAmount <= old * 2, "out of bounds");
            pepecoinStakeAmount = newAmount;
            emit StakeAmountUpdated(asset, old, newAmount);
        } else if (asset == StakeAsset.BasedAI) {
            uint256 old = basedStakeAmount;
            require(newAmount >= old / 2 && newAmount <= old * 2, "out of bounds");
            basedStakeAmount = newAmount;
            emit StakeAmountUpdated(asset, old, newAmount);
        } else {
            revert InvalidStakeAmount();
        }
    }

    // --- Internals ---

    function _allocateBrainId() internal returns (uint256) {
        if (_totalSupply >= MAX_SUPPLY - FIRST_PUBLIC_ID) revert MaxSupplyReached();
        uint256 candidate = nextPublicId;
        nextPublicId = candidate + 1;
        _totalSupply += 1;
        return candidate;
    }

    /// @dev Stake-minted Brains are non-transferable until burned.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            // Transfer between non-zero addresses is forbidden.
            revert TransferRestricted();
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
