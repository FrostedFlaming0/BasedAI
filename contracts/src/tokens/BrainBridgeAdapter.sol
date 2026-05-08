// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Minimal interface to Ink's L1 standard bridge for NFTs.
///         The exact ABI may vary; this is a placeholder for the canonical bridge interface.
interface IL1NFTBridge {
    function depositERC721To(
        address l1Token,
        address l2Token,
        address to,
        uint256 tokenId,
        uint32 minGasLimit,
        bytes calldata extraData
    ) external;
}

/// @title BrainBridgeAdapter
/// @notice Owner-side helper that escrows a Brain NFT on L1 and triggers the bridge
///         to mint a representation on L2.
///
/// Flow:
///   1. Brain owner approves this contract for their BrainNFT.
///   2. Owner calls bridgeToL2(brainId, l2Recipient).
///   3. This contract takes custody and calls Ink's L1 NFT bridge.
///   4. Ink's bridge mints the L2 representation NFT to l2Recipient.
///
/// Bringing a Brain back to L1 follows the standard withdraw flow on Ink directly.
contract BrainBridgeAdapter is IERC721Receiver {
    IERC721 public immutable BRAIN_NFT;
    address public immutable BRAIN_NFT_L2;
    IL1NFTBridge public immutable BRIDGE;
    uint32 public constant DEFAULT_MIN_GAS = 200_000;

    event BridgedToL2(uint256 indexed brainId, address indexed owner, address indexed l2Recipient);

    constructor(IERC721 brainNFT, address brainNFTL2, IL1NFTBridge bridge) {
        BRAIN_NFT = brainNFT;
        BRAIN_NFT_L2 = brainNFTL2;
        BRIDGE = bridge;
    }

    function bridgeToL2(uint256 brainId, address l2Recipient) external {
        // Pull the NFT into this adapter; owner must have approved.
        BRAIN_NFT.transferFrom(msg.sender, address(this), brainId);
        // Approve the bridge to take it.
        BRAIN_NFT.approve(address(BRIDGE), brainId);
        // Trigger the canonical bridge.
        BRIDGE.depositERC721To(
            address(BRAIN_NFT),
            BRAIN_NFT_L2,
            l2Recipient,
            brainId,
            DEFAULT_MIN_GAS,
            ""
        );
        emit BridgedToL2(brainId, msg.sender, l2Recipient);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
