// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BrainNFT} from "../src/tokens/BrainNFT.sol";
import {BrainBridgeAdapter, IL1NFTBridge} from "../src/tokens/BrainBridgeAdapter.sol";

/// @notice Ethereum mainnet deployment of the Brain NFT and bridge adapter.
///
/// Constructor inputs:
///   PEPECOIN     - existing Pepecoin contract (0xA9E8aCf069C58aEc8825542845Fd754e41a9489A)
///   BASEDAI      - existing basedAI contract (0x44971ABF0251958492FeE97dA3e5C5adA88B9185)
///   PEPE_STAKE   - initial Pepecoin stake amount (e.g., 100,000 ether for 100k PEPE)
///   BASED_STAKE  - initial basedAI stake amount (e.g., 10,000 ether for 10k basedAI)
///   GOVERNANCE   - address that can adjust stake amounts (e.g., a multisig until v1.1)
contract DeployMainnet is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address pepecoin = vm.envAddress("PEPECOIN");
        address basedAI = vm.envAddress("BASEDAI");
        uint256 pepeStake = vm.envOr("PEPE_STAKE", uint256(100_000 ether));
        uint256 basedStake = vm.envOr("BASED_STAKE", uint256(10_000 ether));
        address governance = vm.envAddress("GOVERNANCE");
        address brainNFTL2 = vm.envAddress("BRAIN_NFT_L2");
        address l1Bridge = vm.envAddress("L1_NFT_BRIDGE");

        vm.startBroadcast(pk);

        BrainNFT brain = new BrainNFT(
            IERC20(pepecoin),
            IERC20(basedAI),
            pepeStake,
            basedStake,
            governance
        );

        BrainBridgeAdapter adapter = new BrainBridgeAdapter(
            brain, brainNFTL2, IL1NFTBridge(l1Bridge)
        );

        vm.stopBroadcast();

        console2.log("BrainNFT (mainnet):     ", address(brain));
        console2.log("BrainBridgeAdapter:     ", address(adapter));
        console2.log("Pepecoin:               ", pepecoin);
        console2.log("basedAI:                ", basedAI);
        console2.log("Pepecoin stake amount:  ", pepeStake);
        console2.log("basedAI stake amount:   ", basedStake);
    }
}
