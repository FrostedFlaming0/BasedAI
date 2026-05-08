// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISubnetRegistry
/// @notice Per-Brain configuration, miner/validator membership, and lifecycle.
interface ISubnetRegistry {
    /// @dev One Brain's runtime configuration.
    struct Subnet {
        address owner;              // resolved from L2 BrainNFT representation
        bytes32 modelHash;          // content hash identifying the model
        string modelURI;            // human-readable model spec (e.g., HF URL)
        uint256 registrationFee;    // BASED required to register as miner/validator
        uint16 ownerSplitBps;       // basis points to owner; remainder to nodes (default 800 = 8%)
        uint16 minerShareBps;       // miners' share of node split (default 7609 = 70% of 92%)
        uint64 createdAt;
        bool active;
    }

    struct ValidatorInfo {
        uint64 registeredAt;
        uint64 lastActiveEpoch;
        bool active;
    }

    struct MinerInfo {
        uint64 registeredAt;
        uint64 lastActiveEpoch;
        bool active;
    }

    event SubnetActivated(uint256 indexed brainId, address indexed owner, bytes32 modelHash);
    event SubnetDeactivated(uint256 indexed brainId);
    event SubnetConfigured(uint256 indexed brainId, bytes32 modelHash, string modelURI);
    event ValidatorRegistered(uint256 indexed brainId, address indexed validator);
    event ValidatorDeregistered(uint256 indexed brainId, address indexed validator);
    event MinerRegistered(uint256 indexed brainId, address indexed miner);
    event MinerDeregistered(uint256 indexed brainId, address indexed miner);
    event RegistrationFeeUpdated(uint256 indexed brainId, uint256 newFee);
    event EmissionSplitUpdated(uint256 indexed brainId, uint16 ownerSplitBps, uint16 minerShareBps);

    error NotBrainOwner();
    error SubnetInactive();
    error AlreadyRegistered();
    error NotRegistered();
    error CapacityReached();
    error InvalidSplit();

    function MAX_VALIDATORS_PER_BRAIN() external view returns (uint256);
    function MAX_MINERS_PER_BRAIN() external view returns (uint256);

    function activate(uint256 brainId, bytes32 modelHash, string calldata modelURI) external;
    function deactivate(uint256 brainId) external;
    function setModel(uint256 brainId, bytes32 modelHash, string calldata modelURI) external;
    function setRegistrationFee(uint256 brainId, uint256 fee) external;
    function setEmissionSplit(uint256 brainId, uint16 ownerSplitBps, uint16 minerShareBps) external;

    function registerValidator(uint256 brainId) external;
    function deregisterValidator(uint256 brainId) external;
    function registerMiner(uint256 brainId) external;
    function deregisterMiner(uint256 brainId) external;

    function getSubnet(uint256 brainId) external view returns (Subnet memory);
    function isValidator(uint256 brainId, address who) external view returns (bool);
    function isMiner(uint256 brainId, address who) external view returns (bool);
    function validatorCount(uint256 brainId) external view returns (uint256);
    function minerCount(uint256 brainId) external view returns (uint256);
}
