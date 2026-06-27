// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";

/// @title BasedGovernor
/// @notice GigaBrain voting: 1 vote per Brain whose stake-share crosses the GigaBrain threshold.
///         A Brain's vote is exercised by its current owner (resolved from BrainNFTL2).
contract BasedGovernor is Governor, GovernorSettings, GovernorCountingSimple, GovernorTimelockControl {
    uint16 public constant GIGABRAIN_THRESHOLD_BPS = 50; // 0.5%

    IERC721 public immutable BRAIN_NFT_L2;
    IStakingVault public immutable STAKING;
    uint256 public immutable BRAIN_SUPPLY_CAP;

    constructor(IERC721 brainNFTL2, IStakingVault staking, TimelockController timelock, uint256 brainSupplyCap)
        Governor("BasedGovernor")
        GovernorSettings(
            1 days, // voting delay
            7 days, // voting period
            0 // proposal threshold (any GigaBrain holder can propose)
        )
        GovernorTimelockControl(timelock)
    {
        BRAIN_NFT_L2 = brainNFTL2;
        STAKING = staking;
        BRAIN_SUPPLY_CAP = brainSupplyCap;
    }

    function _getVotes(address account, uint256, bytes memory) internal view override returns (uint256) {
        // Count Brains owned by `account` whose stake exceeds the GigaBrain threshold.
        uint256 totalNetStake = STAKING.totalStaked();
        if (totalNetStake == 0) return 0;
        uint256 threshold = (totalNetStake * GIGABRAIN_THRESHOLD_BPS) / 10_000;

        uint256 votes;
        // Iterate the holder's Brains via ERC721Enumerable (assumes BrainNFTL2 supports it).
        uint256 balance = BRAIN_NFT_L2.balanceOf(account);
        for (uint256 i = 0; i < balance; i++) {
            // Casting to enumerable interface inline to avoid extra import surface.
            (bool ok, bytes memory ret) = address(BRAIN_NFT_L2)
                .staticcall(abi.encodeWithSignature("tokenOfOwnerByIndex(address,uint256)", account, i));
            if (!ok) continue;
            uint256 brainId = abi.decode(ret, (uint256));
            if (STAKING.brainStake(brainId) >= threshold) votes += 1;
        }
        return votes;
    }

    function quorum(uint256) public pure override returns (uint256) {
        return 1; // any non-zero GigaBrain support quorum
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    // --- Required overrides ---

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
