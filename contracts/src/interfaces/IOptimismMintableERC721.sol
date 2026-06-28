// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

/// @title IOptimismMintableERC721
/// @notice Interface for contracts that are compatible with the OptimismMintableERC721 standard.
///         Tokens that follow this standard can be transferred across the OP Stack ERC721 bridge.
/// @dev    Vendored VERBATIM from ethereum-optimism (op-contracts/v1.6.0) so that
///         `type(IOptimismMintableERC721).interfaceId` computed here is byte-identical to the value
///         Ink's deployed L2ERC721Bridge checks via ERC165. The function set MUST NOT be edited.
interface IOptimismMintableERC721 is IERC721Enumerable {
    /// @notice Emitted when a token is minted.
    event Mint(address indexed account, uint256 tokenId);

    /// @notice Emitted when a token is burned.
    event Burn(address indexed account, uint256 tokenId);

    /// @notice Mints some token ID for a user, checking first that contract recipients
    ///         are aware of the ERC721 protocol to prevent tokens from being forever locked.
    function safeMint(address _to, uint256 _tokenId) external;

    /// @notice Burns a token ID from a user.
    function burn(address _from, uint256 _tokenId) external;

    /// @notice Chain ID of the chain where the remote token is deployed.
    function REMOTE_CHAIN_ID() external view returns (uint256);

    /// @notice Address of the token on the remote domain.
    function REMOTE_TOKEN() external view returns (address);

    /// @notice Address of the ERC721 bridge on this network.
    function BRIDGE() external view returns (address);

    /// @notice Chain ID of the chain where the remote token is deployed.
    function remoteChainId() external view returns (uint256);

    /// @notice Address of the token on the remote domain.
    function remoteToken() external view returns (address);

    /// @notice Address of the ERC721 bridge on this network.
    function bridge() external view returns (address);
}
