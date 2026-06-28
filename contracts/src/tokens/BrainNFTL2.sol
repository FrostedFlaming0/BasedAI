// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IOptimismMintableERC721} from "../interfaces/IOptimismMintableERC721.sol";

/// @title BrainNFTL2
/// @notice L2 representation of mainnet Brain NFTs. Implements the OP Stack `OptimismMintableERC721`
///         standard so Ink's CANONICAL `L2ERC721Bridge` (predeploy 0x4200..0014) mints it on deposit
///         from L1 and burns it on withdrawal — no custom/placeholder bridge. All BasedAI L2 contracts
///         read Brain ownership (and governance voting power) from this contract.
/// @dev    Soulbound like its L1 counterpart: a Brain can only be MINTED (by the bridge, from L1) or
///         BURNED (by the bridge, on withdrawal), never transferred peer-to-peer. This keeps L2
///         governance power bound to the bridged, stake-backed L1 Brain rather than freely tradable.
contract BrainNFTL2 is ERC721Enumerable, IOptimismMintableERC721 {
    /// @inheritdoc IOptimismMintableERC721
    uint256 public immutable REMOTE_CHAIN_ID;
    /// @inheritdoc IOptimismMintableERC721
    address public immutable REMOTE_TOKEN;
    /// @inheritdoc IOptimismMintableERC721
    address public immutable BRIDGE;

    error TransferRestricted();

    /// @notice Only the canonical L2 ERC721 bridge may mint/burn.
    modifier onlyBridge() {
        require(msg.sender == BRIDGE, "BrainNFTL2: only bridge");
        _;
    }

    /// @param bridge_        The canonical L2ERC721Bridge (Ink predeploy 0x4200..0014).
    /// @param remoteChainId_ Chain id of the L1 where the real Brain NFT lives (1 mainnet / 11155111 sepolia).
    /// @param remoteToken_   Address of the L1 BrainNFT this token represents.
    constructor(address bridge_, uint256 remoteChainId_, address remoteToken_)
        ERC721("BasedAI Brain (L2)", "BRAIN-L2")
    {
        require(bridge_ != address(0), "BrainNFTL2: bridge zero");
        require(remoteChainId_ != 0, "BrainNFTL2: remote chain id zero");
        require(remoteToken_ != address(0), "BrainNFTL2: remote token zero");
        BRIDGE = bridge_;
        REMOTE_CHAIN_ID = remoteChainId_;
        REMOTE_TOKEN = remoteToken_;
    }

    /// @inheritdoc IOptimismMintableERC721
    function remoteChainId() external view returns (uint256) {
        return REMOTE_CHAIN_ID;
    }

    /// @inheritdoc IOptimismMintableERC721
    function remoteToken() external view returns (address) {
        return REMOTE_TOKEN;
    }

    /// @inheritdoc IOptimismMintableERC721
    function bridge() external view returns (address) {
        return BRIDGE;
    }

    /// @inheritdoc IOptimismMintableERC721
    function safeMint(address _to, uint256 _tokenId) external onlyBridge {
        _safeMint(_to, _tokenId);
        emit Mint(_to, _tokenId);
    }

    /// @inheritdoc IOptimismMintableERC721
    function burn(address _from, uint256 _tokenId) external onlyBridge {
        _burn(_tokenId);
        emit Burn(_from, _tokenId);
    }

    /// @dev Soulbound: permit only mint (from == 0) and burn (to == 0); reject peer-to-peer transfers.
    ///      The bridge mints/burns directly, so no transfer-to-bridge is required.
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721Enumerable) returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert TransferRestricted();
        return super._update(to, tokenId, auth);
    }

    /// @dev Returns true for the OptimismMintableERC721 interface id (what L2ERC721Bridge checks) and
    ///      every interface ERC721Enumerable advertises.
    function supportsInterface(bytes4 _interfaceId) public view override(ERC721Enumerable, IERC165) returns (bool) {
        return _interfaceId == type(IOptimismMintableERC721).interfaceId || super.supportsInterface(_interfaceId);
    }
}
