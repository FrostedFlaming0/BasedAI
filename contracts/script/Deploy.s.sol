// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BrainNFTL2} from "../src/tokens/BrainNFTL2.sol";
import {SubnetRegistry} from "../src/subnet/SubnetRegistry.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {ScoringRegistry} from "../src/scoring/ScoringRegistry.sol";
import {ComputeUnitMarket} from "../src/market/ComputeUnitMarket.sol";
import {BasedGovernor} from "../src/governance/BasedGovernor.sol";

/// @notice L2 deployment for BasedAI v2.
///
/// Reads the bridged $basedAI token address from BASEDAI_L2 (the canonical bridge
/// representation of mainnet 0x44971ABF...). No new token is deployed.
/// No EmissionController is deployed (v2 has no protocol-level emissions).
///
/// The mainnet BrainNFT + bridge adapter is deployed separately (DeployMainnet.s.sol).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN", deployer);

        // Existing $basedAI bridged to Ink. This is provided externally; no token
        // is deployed by this script.
        IERC20 basedAI = IERC20(vm.envAddress("BASEDAI_L2"));

        vm.startBroadcast(pk);

        // Phase 1: L2 Brain representation.
        BrainNFTL2 brainNFT = new BrainNFTL2(admin);

        // Phase 2: core registries.
        SubnetRegistry registry = new SubnetRegistry(brainNFT, basedAI);
        StakingVault staking = new StakingVault(basedAI, admin);

        uint64 genesisTs = uint64(block.timestamp);
        ScoringRegistry scoring = new ScoringRegistry(staking, genesisTs);

        ComputeUnitMarket market = new ComputeUnitMarket(basedAI);

        // Phase 3: governance.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(2 days, proposers, executors, admin);

        BasedGovernor governor = new BasedGovernor(brainNFT, staking, timelock, 64);

        // Phase 4: wire up roles.
        // ScoringRegistry can slash via StakingVault.
        staking.grantRole(staking.SLASHER_ROLE(), address(scoring));

        vm.stopBroadcast();

        console2.log("$basedAI (L2):    ", address(basedAI));
        console2.log("BrainNFTL2:       ", address(brainNFT));
        console2.log("SubnetRegistry:   ", address(registry));
        console2.log("StakingVault:     ", address(staking));
        console2.log("ScoringRegistry:  ", address(scoring));
        console2.log("Market:           ", address(market));
        console2.log("Timelock:         ", address(timelock));
        console2.log("Governor:         ", address(governor));
    }
}
