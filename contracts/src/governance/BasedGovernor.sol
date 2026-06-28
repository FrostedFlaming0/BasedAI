// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IStakingVault} from "../interfaces/IStakingVault.sol";

/// @title BasedGovernor
/// @notice GigaBrain voting: 1 vote per Brain whose stake-share crosses the GigaBrain threshold.
///         A Brain's vote is exercised by its current owner (resolved from BrainNFTL2).
/// @dev    Hardened over v1:
///         - Voting power is SNAPSHOTTED: stake is read at the proposal's timepoint via the
///           StakingVault history checkpoints, so stake acquired/borrowed during the voting window
///           does not grant power, and unstaking afterward does not remove it.
///         - The clock is timestamp-based (ERC-6372 mode=timestamp), so the `1 days` / `7 days`
///           settings mean wall-clock time, not block counts.
///         - Each Brain id can be counted AT MOST ONCE per proposal, so a transferable Brain
///           cannot be moved between addresses to vote repeatedly.
///         - `quorum` and `proposalThreshold` are real (configurable, non-trivial), not 1 and 0.
contract BasedGovernor is Governor, GovernorSettings, GovernorCountingSimple, GovernorTimelockControl {
    uint16 public constant GIGABRAIN_THRESHOLD_BPS = 50; // 0.5%

    /// @dev Bounds the per-voter Brain enumeration to keep `_getVotes` from unbounded gas.
    uint256 public constant MAX_BRAINS_PER_VOTER = 64;

    IERC721Enumerable public immutable BRAIN_NFT_L2;
    IStakingVault public immutable STAKING;
    uint256 public immutable BRAIN_SUPPLY_CAP;

    /// @notice Minimum number of GigaBrain votes required for a proposal to reach quorum.
    uint256 public quorumVotes;

    /// @dev proposalId => brainId => already counted (per-proposal de-duplication).
    mapping(uint256 => mapping(uint256 => bool)) private _brainVoted;

    event QuorumVotesUpdated(uint256 oldValue, uint256 newValue);

    constructor(
        IERC721Enumerable brainNFTL2,
        IStakingVault staking,
        TimelockController timelock,
        uint256 brainSupplyCap,
        uint256 initialQuorumVotes
    )
        Governor("BasedGovernor")
        GovernorSettings(
            1 days, // voting delay
            7 days, // voting period
            1 // proposal threshold: must hold >= 1 GigaBrain to propose
        )
        GovernorTimelockControl(timelock)
    {
        BRAIN_NFT_L2 = brainNFTL2;
        STAKING = staking;
        BRAIN_SUPPLY_CAP = brainSupplyCap;
        quorumVotes = initialQuorumVotes;
    }

    // --- Clock (ERC-6372 timestamp mode, consistent with StakingVault history) ---

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // --- Voting power (snapshotted) ---

    /// @dev Counts Brains owned by `account` whose SNAPSHOT stake crosses the GigaBrain threshold.
    function _getVotes(address account, uint256 timepoint, bytes memory) internal view override returns (uint256) {
        uint48 tp = uint48(timepoint);
        uint256 threshold = _gigaBrainThreshold(tp);
        if (threshold == 0) return 0;

        uint256 balance = BRAIN_NFT_L2.balanceOf(account);
        if (balance > MAX_BRAINS_PER_VOTER) balance = MAX_BRAINS_PER_VOTER;
        uint256 votes;
        for (uint256 i = 0; i < balance; i++) {
            uint256 brainId = BRAIN_NFT_L2.tokenOfOwnerByIndex(account, i);
            if (STAKING.getPastBrainStake(brainId, tp) >= threshold) votes += 1;
        }
        return votes;
    }

    /// @dev GigaBrain threshold at a timepoint; rounded UP so a near-zero total stake cannot make
    ///      every Brain a GigaBrain. Returns 0 (no eligibility) when there is no stake history.
    function _gigaBrainThreshold(uint48 timepoint) private view returns (uint256) {
        uint256 totalNetStake = STAKING.getPastTotalStaked(timepoint);
        if (totalNetStake == 0) return 0;
        return (totalNetStake * GIGABRAIN_THRESHOLD_BPS + 9_999) / 10_000;
    }

    /// @dev Overrides the ballot path so each Brain is counted at most once per proposal even if
    ///      the NFT is transferred between addresses mid-vote.
    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
        internal
        override
        returns (uint256)
    {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Active) {
            revert GovernorUnexpectedProposalState(proposalId, currentState, _encodeStateBitmap(ProposalState.Active));
        }

        uint48 tp = uint48(proposalSnapshot(proposalId));
        uint256 threshold = _gigaBrainThreshold(tp);
        uint256 weight;
        if (threshold != 0) {
            uint256 balance = BRAIN_NFT_L2.balanceOf(account);
            if (balance > MAX_BRAINS_PER_VOTER) balance = MAX_BRAINS_PER_VOTER;
            for (uint256 i = 0; i < balance; i++) {
                uint256 brainId = BRAIN_NFT_L2.tokenOfOwnerByIndex(account, i);
                if (STAKING.getPastBrainStake(brainId, tp) < threshold) continue;
                if (_brainVoted[proposalId][brainId]) continue; // each Brain votes once per proposal
                _brainVoted[proposalId][brainId] = true;
                weight += 1;
            }
        }
        _countVote(proposalId, account, support, weight, params);

        if (params.length == 0) {
            emit VoteCast(account, proposalId, support, weight, reason);
        } else {
            emit VoteCastWithParams(account, proposalId, support, weight, reason, params);
        }
        return weight;
    }

    function quorum(uint256) public view override returns (uint256) {
        return quorumVotes;
    }

    /// @notice Governance-only adjustment of the quorum (executed through the timelock).
    function setQuorumVotes(uint256 newQuorum) external onlyGovernance {
        emit QuorumVotesUpdated(quorumVotes, newQuorum);
        quorumVotes = newQuorum;
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
