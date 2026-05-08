// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BrainNFTL2
/// @notice L2 representation of mainnet Brain NFTs, minted/burned by the canonical bridge.
///         All BasedAI L2 contracts read Brain ownership from this contract.
contract BrainNFTL2 is ERC721Enumerable, AccessControl {
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    constructor(address admin) ERC721("BasedAI Brain (L2)", "BRAIN-L2") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function bridgeMint(address to, uint256 brainId) external onlyRole(BRIDGE_ROLE) {
        _safeMint(to, brainId);
    }

    function bridgeBurn(uint256 brainId) external onlyRole(BRIDGE_ROLE) {
        _burn(brainId);
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
