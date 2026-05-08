// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISubnetRegistry} from "../interfaces/ISubnetRegistry.sol";

/// @title SubnetRegistry
/// @notice Per-Brain configuration and miner/validator membership.
contract SubnetRegistry is ISubnetRegistry {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_VALIDATORS_PER_BRAIN = 256;
    uint256 public constant MAX_MINERS_PER_BRAIN = 1792;

    uint256 public constant DEFAULT_REGISTRATION_FEE = 100 ether;
    uint16 public constant DEFAULT_OWNER_SPLIT_BPS = 800;        // 8% to owner
    uint16 public constant DEFAULT_MINER_SHARE_BPS = 7609;       // 70% of 92% node share = 7609 of 10000

    uint16 public constant MAX_OWNER_SPLIT_BPS = 1500;           // 15% cap on owner share

    /// @notice Registration fees are burned (sent to dead address) by network policy.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IERC721 public immutable BRAIN_NFT;
    IERC20 public immutable BASED;

    mapping(uint256 brainId => Subnet) private _subnets;
    mapping(uint256 brainId => mapping(address => ValidatorInfo)) private _validators;
    mapping(uint256 brainId => mapping(address => MinerInfo)) private _miners;
    mapping(uint256 brainId => uint256) private _validatorCount;
    mapping(uint256 brainId => uint256) private _minerCount;

    constructor(IERC721 brainNFT, IERC20 based) {
        BRAIN_NFT = brainNFT;
        BASED = based;
    }

    modifier onlyOwner(uint256 brainId) {
        if (BRAIN_NFT.ownerOf(brainId) != msg.sender) revert NotBrainOwner();
        _;
    }

    modifier onlyActive(uint256 brainId) {
        if (!_subnets[brainId].active) revert SubnetInactive();
        _;
    }

    function activate(uint256 brainId, bytes32 modelHash, string calldata modelURI)
        external
        onlyOwner(brainId)
    {
        Subnet storage s = _subnets[brainId];
        s.owner = msg.sender;
        s.modelHash = modelHash;
        s.modelURI = modelURI;
        s.registrationFee = DEFAULT_REGISTRATION_FEE;
        s.ownerSplitBps = DEFAULT_OWNER_SPLIT_BPS;
        s.minerShareBps = DEFAULT_MINER_SHARE_BPS;
        s.createdAt = uint64(block.timestamp);
        s.active = true;
        emit SubnetActivated(brainId, msg.sender, modelHash);
    }

    function deactivate(uint256 brainId) external onlyOwner(brainId) {
        _subnets[brainId].active = false;
        emit SubnetDeactivated(brainId);
    }

    function setModel(uint256 brainId, bytes32 modelHash, string calldata modelURI)
        external
        onlyOwner(brainId)
        onlyActive(brainId)
    {
        Subnet storage s = _subnets[brainId];
        s.modelHash = modelHash;
        s.modelURI = modelURI;
        emit SubnetConfigured(brainId, modelHash, modelURI);
    }

    function setRegistrationFee(uint256 brainId, uint256 fee)
        external
        onlyOwner(brainId)
        onlyActive(brainId)
    {
        _subnets[brainId].registrationFee = fee;
        emit RegistrationFeeUpdated(brainId, fee);
    }

    function setEmissionSplit(uint256 brainId, uint16 ownerSplitBps, uint16 minerShareBps)
        external
        onlyOwner(brainId)
        onlyActive(brainId)
    {
        if (ownerSplitBps > MAX_OWNER_SPLIT_BPS || minerShareBps > 10_000) revert InvalidSplit();
        Subnet storage s = _subnets[brainId];
        s.ownerSplitBps = ownerSplitBps;
        s.minerShareBps = minerShareBps;
        emit EmissionSplitUpdated(brainId, ownerSplitBps, minerShareBps);
    }

    function registerValidator(uint256 brainId) external onlyActive(brainId) {
        if (_validators[brainId][msg.sender].active) revert AlreadyRegistered();
        if (_validatorCount[brainId] >= MAX_VALIDATORS_PER_BRAIN) revert CapacityReached();
        _payFee(brainId);
        _validators[brainId][msg.sender] = ValidatorInfo({
            registeredAt: uint64(block.timestamp),
            lastActiveEpoch: 0,
            active: true
        });
        _validatorCount[brainId] += 1;
        emit ValidatorRegistered(brainId, msg.sender);
    }

    function deregisterValidator(uint256 brainId) external {
        if (!_validators[brainId][msg.sender].active) revert NotRegistered();
        _validators[brainId][msg.sender].active = false;
        _validatorCount[brainId] -= 1;
        emit ValidatorDeregistered(brainId, msg.sender);
    }

    function registerMiner(uint256 brainId) external onlyActive(brainId) {
        if (_miners[brainId][msg.sender].active) revert AlreadyRegistered();
        if (_minerCount[brainId] >= MAX_MINERS_PER_BRAIN) revert CapacityReached();
        _payFee(brainId);
        _miners[brainId][msg.sender] = MinerInfo({
            registeredAt: uint64(block.timestamp),
            lastActiveEpoch: 0,
            active: true
        });
        _minerCount[brainId] += 1;
        emit MinerRegistered(brainId, msg.sender);
    }

    function deregisterMiner(uint256 brainId) external {
        if (!_miners[brainId][msg.sender].active) revert NotRegistered();
        _miners[brainId][msg.sender].active = false;
        _minerCount[brainId] -= 1;
        emit MinerDeregistered(brainId, msg.sender);
    }

    function _payFee(uint256 brainId) internal {
        uint256 fee = _subnets[brainId].registrationFee;
        if (fee > 0) {
            // 100% of registration fees are burned (network policy).
            BASED.safeTransferFrom(msg.sender, BURN_ADDRESS, fee);
        }
    }

    // --- Views ---

    function getSubnet(uint256 brainId) external view returns (Subnet memory) {
        return _subnets[brainId];
    }

    function isValidator(uint256 brainId, address who) external view returns (bool) {
        return _validators[brainId][who].active;
    }

    function isMiner(uint256 brainId, address who) external view returns (bool) {
        return _miners[brainId][who].active;
    }

    function validatorCount(uint256 brainId) external view returns (uint256) {
        return _validatorCount[brainId];
    }

    function minerCount(uint256 brainId) external view returns (uint256) {
        return _minerCount[brainId];
    }
}
