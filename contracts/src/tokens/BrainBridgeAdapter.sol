// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice The OP Stack canonical L1 ERC-721 bridge interface (Ink uses the standard predeploy set).
///         This is the REAL `L1ERC721Bridge.bridgeERC721To` ABI from ethereum-optimism, not a
///         placeholder. Ink L1ERC721Bridge: mainnet 0x661235a238b11191211fa95d4dd9e423d521e0be,
///         Sepolia 0xd1c901bbd7796546a7ba2492e0e199911fae68c7.
interface IL1ERC721Bridge {
    function bridgeERC721To(
        address _localToken,
        address _remoteToken,
        address _to,
        uint256 _tokenId,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
}

/// @title BrainBridgeAdapter
/// @notice Optional one-call helper that escrows a Brain NFT on L1 and triggers Ink's canonical
///         L1ERC721Bridge to mint the L2 representation. Users MAY instead approve the L1ERC721Bridge
///         directly and call `bridgeERC721To` — the adapter only pins the correct remote token and gas.
///
/// Flow:
///   1. Brain owner approves this adapter for their BrainNFT.
///   2. Owner calls bridgeToL2(brainId, l2Recipient).
///   3. The adapter takes custody, approves the canonical bridge, and calls bridgeERC721To.
///   4. Ink's L2ERC721Bridge mints the `BrainNFTL2` (an OptimismMintableERC721) to l2Recipient.
///
/// Returning a Brain to L1 uses the canonical L2->L1 withdrawal on Ink (burns L2, releases the L1
/// escrow back to the owner). For both legs the L1ERC721Bridge must be authorized as a bridge
/// endpoint on BrainNFT (and, when this adapter is used, the adapter too).
contract BrainBridgeAdapter is IERC721Receiver {
    IERC721 public immutable BRAIN_NFT;
    address public immutable BRAIN_NFT_L2;
    IL1ERC721Bridge public immutable BRIDGE;
    uint32 public constant DEFAULT_MIN_GAS = 200_000;

    event BridgedToL2(uint256 indexed brainId, address indexed owner, address indexed l2Recipient);

    error ZeroRecipient();
    error UnsupportedNFT();

    constructor(IERC721 brainNFT, address brainNFTL2, IL1ERC721Bridge bridge) {
        BRAIN_NFT = brainNFT;
        BRAIN_NFT_L2 = brainNFTL2;
        BRIDGE = bridge;
    }

    function bridgeToL2(uint256 brainId, address l2Recipient) external {
        if (l2Recipient == address(0)) revert ZeroRecipient();
        // Pull the NFT into this adapter; owner must have approved. (BrainNFT must authorize this
        // adapter AND the canonical bridge as `bridge` endpoints so the soulbound token can move.)
        BRAIN_NFT.transferFrom(msg.sender, address(this), brainId);
        // Approve the canonical bridge to escrow it, then trigger the deposit.
        BRAIN_NFT.approve(address(BRIDGE), brainId);
        BRIDGE.bridgeERC721To(address(BRAIN_NFT), BRAIN_NFT_L2, l2Recipient, brainId, DEFAULT_MIN_GAS, "");
        emit BridgedToL2(brainId, msg.sender, l2Recipient);
    }

    /// @dev Only accept the Brain NFT, so unrelated NFTs cannot be safe-transferred in and trapped.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(BRAIN_NFT)) revert UnsupportedNFT();
        return IERC721Receiver.onERC721Received.selector;
    }
}
