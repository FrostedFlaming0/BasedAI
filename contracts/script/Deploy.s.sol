// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {BrainNFTL2} from "../src/tokens/BrainNFTL2.sol";
import {SubnetRegistry} from "../src/subnet/SubnetRegistry.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {ScoringRegistry} from "../src/scoring/ScoringRegistry.sol";
import {ComputeUnitMarket} from "../src/market/ComputeUnitMarket.sol";
import {RewardDistributor} from "../src/reward/RewardDistributor.sol";
import {BasedGovernor} from "../src/governance/BasedGovernor.sol";
import {ISubnetRegistry} from "../src/interfaces/ISubnetRegistry.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";

/// @notice L2 deployment for BasedAI v2.
///
/// Hardened wiring (fixes the v1 "permanent admin backdoor / inert governor"):
///   - The Governor is granted PROPOSER + CANCELLER on the timelock; EXECUTOR is open.
///   - Protocol DEFAULT_ADMIN of StakingVault and BrainNFTL2 is transferred to the timelock.
///   - The deployer RENOUNCES every bootstrap admin role, so post-deploy the only way to act
///     through the timelock is a passed governance proposal (no standing superuser key).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IERC20 basedAI = IERC20(vm.envAddress("BASEDAI_L2"));
        uint256 quorumVotes = vm.envOr("GOV_QUORUM_VOTES", uint256(4));
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));
        // BrainNFTL2 is an OptimismMintableERC721 minted/burned ONLY by Ink's canonical L2ERC721Bridge
        // (predeploy 0x4200..0014). L2 Brains exist solely by bridging a real Brain from L1, so the
        // remote (L1) Brain NFT address is MANDATORY — without it there is no Brain mint path, and the
        // deployer renounces admin while governance needs a Brain quorum, permanently deadlocking it.
        address l2Erc721Bridge = vm.envOr("L2_ERC721_BRIDGE", 0x4200000000000000000000000000000000000014);
        address l1BrainNFT = vm.envOr("L1_BRAIN_NFT", address(0));
        uint256 l1RemoteChainId = vm.envOr("L1_REMOTE_CHAIN_ID", uint256(1)); // 1 mainnet / 11155111 sepolia
        require(
            l1BrainNFT != address(0),
            "L1_BRAIN_NFT required: L2 Brains are minted only by bridging from L1; without it governance can never reach quorum after renounce"
        );
        require(l2Erc721Bridge != address(0), "L2_ERC721_BRIDGE required");
        require(quorumVotes > 0 && quorumVotes <= 64, "GOV_QUORUM_VOTES must be in (0, 64]");
        // Optional guardian multisig that can CANCEL queued proposals (emergency brake only).
        address guardian = vm.envOr("GUARDIAN", address(0));

        vm.startBroadcast(pk);

        // Phase 1: L2 Brain representation — an OptimismMintableERC721 whose only minter/burner is the
        // canonical L2ERC721Bridge (no admin role, no custom minter). Soulbound like its L1 counterpart.
        BrainNFTL2 brainNFT = new BrainNFTL2(l2Erc721Bridge, l1RemoteChainId, l1BrainNFT);

        // Phase 2: core registries.
        SubnetRegistry registry = new SubnetRegistry(IERC721Enumerable(address(brainNFT)), basedAI);
        StakingVault staking = new StakingVault(basedAI, deployer);

        uint64 genesisTs = uint64(block.timestamp);
        ScoringRegistry scoring = new ScoringRegistry(staking, genesisTs);

        // RewardDistributor sinks the validator fee share and pushes it into staking as yield.
        RewardDistributor rewardDistributor = new RewardDistributor(
            basedAI, ISubnetRegistry(address(registry)), IStakingVault(address(staking)), deployer
        );

        // Market splits redemptions (owner/miner/validator) and routes the validator share to the
        // distributor. `maxReservation` bounds what a pre-authorization receipt can draw (governance-tunable).
        uint256 maxReservation = vm.envOr("MARKET_MAX_RESERVATION", uint256(1 ether));
        // Byte pricing is independently measurable by client and miner without trusting tokenizer output.
        uint256 pricePerByte = vm.envOr("MARKET_PRICE_PER_BYTE", uint256(1 gwei));
        uint256 pricePerRequest = vm.envOr("MARKET_PRICE_PER_REQUEST", uint256(1e14));
        ComputeUnitMarket market = new ComputeUnitMarket(
            basedAI,
            ISubnetRegistry(address(registry)),
            IRewardDistributor(address(rewardDistributor)),
            maxReservation,
            pricePerByte,
            pricePerRequest,
            deployer
        );

        // Phase 3: governance. Timelock starts with the deployer as temporary admin so we can
        // wire roles atomically, then we hand off and renounce.
        address[] memory none = new address[](0);
        TimelockController timelock = new TimelockController(minDelay, none, none, deployer);

        BasedGovernor governor =
            new BasedGovernor(IERC721Enumerable(address(brainNFT)), staking, timelock, 64, quorumVotes);

        // Phase 4: wire roles.
        // ScoringRegistry can slash via StakingVault.
        staking.grantRole(staking.SLASHER_ROLE(), address(scoring));

        // Economic wiring: the market records validator fees into the distributor, and the
        // distributor accrues them into staking as delegated yield.
        rewardDistributor.grantRole(rewardDistributor.MARKET_ROLE(), address(market));
        staking.grantRole(staking.REWARDER_ROLE(), address(rewardDistributor));

        // Emergency pause of the market: bootstrap guardian (if set) plus governance via timelock.
        market.grantRole(market.PAUSER_ROLE(), address(timelock));
        if (guardian != address(0)) {
            market.grantRole(market.PAUSER_ROLE(), guardian);
        }

        // Governor drives the timelock; execution is open (anyone can execute a queued, delayed op).
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        if (guardian != address(0)) {
            timelock.grantRole(timelock.CANCELLER_ROLE(), guardian);
        }

        // The L2 Brain minter is the canonical L2ERC721Bridge, fixed immutably in BrainNFTL2's
        // constructor — there is no minter role to grant here.

        // Pre-renunciation reachability assertions: PROVE administration stays operable before the
        // deployer drops its keys. If any of these fail the script reverts and nothing is renounced,
        // so a misconfigured deploy can never strand the protocol with no admin.
        require(brainNFT.bridge() == l2Erc721Bridge, "L2 Brain minter (bridge) not wired");
        require(brainNFT.remoteToken() == l1BrainNFT, "L1 Brain remote token not wired: no Brains bridgeable");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)), "governor cannot propose");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "execution not open");

        // Phase 5: hand protocol administration to the timelock and renounce the deployer's keys.
        staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), address(timelock));
        staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), deployer);

        // BrainNFTL2 has no admin role to transfer/renounce: mint/burn authority is the immutable
        // canonical bridge, set at construction.

        market.grantRole(market.DEFAULT_ADMIN_ROLE(), address(timelock));
        market.renounceRole(market.DEFAULT_ADMIN_ROLE(), deployer);

        rewardDistributor.grantRole(rewardDistributor.DEFAULT_ADMIN_ROLE(), address(timelock));
        rewardDistributor.renounceRole(rewardDistributor.DEFAULT_ADMIN_ROLE(), deployer);

        // Renounce the deployer's bootstrap admin of the timelock — no standing superuser remains.
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("$basedAI (L2):    ", address(basedAI));
        console2.log("BrainNFTL2:       ", address(brainNFT));
        console2.log("SubnetRegistry:   ", address(registry));
        console2.log("StakingVault:     ", address(staking));
        console2.log("ScoringRegistry:  ", address(scoring));
        console2.log("RewardDistributor:", address(rewardDistributor));
        console2.log("Market:           ", address(market));
        console2.log("Timelock:         ", address(timelock));
        console2.log("Governor:         ", address(governor));
        console2.log("L2 ERC721 bridge: ", l2Erc721Bridge);
        console2.log("L1 Brain NFT:     ", l1BrainNFT);
    }
}
