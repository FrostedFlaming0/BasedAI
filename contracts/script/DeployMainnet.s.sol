// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BrainNFT} from "../src/tokens/BrainNFT.sol";
import {BrainBridgeAdapter, IL1ERC721Bridge} from "../src/tokens/BrainBridgeAdapter.sol";

/// @notice Ethereum mainnet deployment of the Brain NFT and bridge adapter.
///
/// The deployer holds GOVERNANCE_ROLE transiently to wire the bridge, then transfers governance
/// to the configured GOVERNANCE address and renounces its own roles.
///
/// Constructor inputs:
///   PEPECOIN     - existing Pepecoin contract (0xA9E8aCf069C58aEc8825542845Fd754e41a9489A)
///   BASEDAI      - existing basedAI contract (0x44971ABF0251958492FeE97dA3e5C5adA88B9185)
///   PEPE_STAKE   - initial Pepecoin stake amount (e.g., 100,000 ether for 100k PEPE)
///   BASED_STAKE  - initial basedAI stake amount (e.g., 10,000 ether for 10k basedAI)
///   GOVERNANCE   - final governance (e.g., a multisig until v1.1)
contract DeployMainnet is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address pepecoin = vm.envAddress("PEPECOIN");
        address basedAI = vm.envAddress("BASEDAI");
        uint256 pepeStake = vm.envOr("PEPE_STAKE", uint256(100_000 ether));
        uint256 basedStake = vm.envOr("BASED_STAKE", uint256(10_000 ether));
        address governance = vm.envAddress("GOVERNANCE");
        // OPTIONAL at this phase: the L2 BrainNFT representation and Ink's canonical L1 bridge are
        // outputs of the L2 deploy (Phase 2) and Ink's own deployment. Leaving them unset deploys the
        // L1 BrainNFT ALONE (no circular dependency on a Phase-2 address); the adapter is then wired
        // in Phase 3 once both addresses exist. Set both to deploy and wire the adapter in one shot.
        address brainNFTL2 = vm.envOr("BRAIN_NFT_L2", address(0));
        address l1Bridge = vm.envOr("L1_NFT_BRIDGE", address(0));
        bool wireAdapter = brainNFTL2 != address(0) && l1Bridge != address(0);

        vm.startBroadcast(pk);

        // Deploy with the deployer as temporary governance so we can wire the bridge.
        BrainNFT brain = new BrainNFT(IERC20(pepecoin), IERC20(basedAI), pepeStake, basedStake, deployer);

        address adapter = address(0);
        if (wireAdapter) {
            BrainBridgeAdapter a = new BrainBridgeAdapter(brain, brainNFTL2, IL1ERC721Bridge(l1Bridge));
            adapter = address(a);
            // Ink's canonical L1ERC721Bridge is the escrow for BOTH legs: it pulls the Brain on deposit
            // and releases it on withdrawal, so it MUST be an authorized endpoint or escrow->user
            // withdrawal would revert (the one-way lock). The adapter is an additional endpoint for the
            // optional one-call deposit helper.
            brain.setBridge(l1Bridge);
            brain.setBridgeEndpoint(adapter, true);
        }

        // Hand governance to the configured address and renounce the deployer's bootstrap roles.
        if (governance != deployer) {
            brain.grantRole(brain.GOVERNANCE_ROLE(), governance);
            brain.grantRole(brain.DEFAULT_ADMIN_ROLE(), governance);
            brain.renounceRole(brain.GOVERNANCE_ROLE(), deployer);
            brain.renounceRole(brain.DEFAULT_ADMIN_ROLE(), deployer);
        }

        vm.stopBroadcast();

        console2.log("BrainNFT (mainnet):     ", address(brain));
        console2.log("BrainBridgeAdapter:     ", adapter);
        console2.log("Governance:             ", governance);
        if (!wireAdapter) {
            console2.log("NOTE: adapter NOT deployed; set BRAIN_NFT_L2 + L1_NFT_BRIDGE and run Phase 3 wiring.");
        }
    }
}
