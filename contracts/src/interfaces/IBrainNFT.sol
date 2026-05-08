// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBrainNFT
/// @notice Brain ownership token. Lives on Ethereum mainnet, acquired by staking
///         either Pepecoin or $basedAI. Bridged to Ink L2 for operational use.
interface IBrainNFT {
    enum StakeAsset { None, Pepecoin, BasedAI }

    event BrainMintedByPepecoinStake(uint256 indexed brainId, address indexed owner, uint256 amount);
    event BrainMintedByBasedStake(uint256 indexed brainId, address indexed owner, uint256 amount);
    event BrainBurned(uint256 indexed brainId, address indexed owner, StakeAsset asset, uint256 amountReturned);
    event StakeAmountUpdated(StakeAsset indexed asset, uint256 oldAmount, uint256 newAmount);

    error MaxSupplyReached();
    error TransferRestricted();
    error StakeLockNotElapsed();
    error WrongMintMethod();
    error NotGovernance();
    error InvalidStakeAmount();

    function MAX_SUPPLY() external view returns (uint256);
    function FIRST_PUBLIC_ID() external view returns (uint256);
    function STAKE_LOCK_DURATION() external view returns (uint64);

    function pepecoinStakeAmount() external view returns (uint256);
    function basedStakeAmount() external view returns (uint256);

    function totalSupply() external view returns (uint256);
    function stakeAssetOf(uint256 brainId) external view returns (StakeAsset);

    /// @notice Stake Pepecoin to mint a Brain. Brain is non-transferable until deactivation.
    function mintByPepecoinStake() external returns (uint256 brainId);

    /// @notice Stake basedAI to mint a Brain. Brain is non-transferable until deactivation.
    function mintByBasedStake() external returns (uint256 brainId);

    /// @notice Burn the Brain and recover the original stake. Requires lock period elapsed.
    function deactivateAndUnstake(uint256 brainId) external;

    /// @notice Governance-only. Adjust stake amount for an asset within bounds.
    function setStakeAmount(StakeAsset asset, uint256 newAmount) external;
}
