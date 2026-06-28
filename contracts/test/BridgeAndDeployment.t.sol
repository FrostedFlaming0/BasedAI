// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BrainNFT} from "../src/tokens/BrainNFT.sol";
import {IBrainNFT} from "../src/interfaces/IBrainNFT.sol";
import {BrainNFTL2} from "../src/tokens/BrainNFTL2.sol";
import {IOptimismMintableERC721} from "../src/interfaces/IOptimismMintableERC721.sol";
import {BrainBridgeAdapter, IL1ERC721Bridge} from "../src/tokens/BrainBridgeAdapter.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {ComputeUnitMarket} from "../src/market/ComputeUnitMarket.sol";
import {RewardDistributor} from "../src/reward/RewardDistributor.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployMainnet} from "../script/DeployMainnet.s.sol";

contract DeployMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockL1ERC721Bridge is IL1ERC721Bridge {
    event BridgeCalled(
        address indexed localToken,
        address indexed remoteToken,
        address indexed to,
        uint256 tokenId,
        uint32 minGasLimit,
        bytes extraData
    );

    function bridgeERC721To(
        address localToken,
        address remoteToken,
        address to,
        uint256 tokenId,
        uint32 minGasLimit,
        bytes calldata extraData
    ) external {
        IERC721(localToken).transferFrom(msg.sender, address(this), tokenId);
        emit BridgeCalled(localToken, remoteToken, to, tokenId, minGasLimit, extraData);
    }

    function release(address localToken, address to, uint256 tokenId) external {
        IERC721(localToken).transferFrom(address(this), to, tokenId);
    }
}

contract BridgeIntegrationTest is Test {
    DeployMockERC20 token;
    BrainNFT brain;
    BrainNFTL2 l2Brain;
    MockL1ERC721Bridge bridge;
    BrainBridgeAdapter adapter;

    address governance = makeAddr("governance");
    address user = makeAddr("user");
    address recipient = makeAddr("l2-recipient");

    function setUp() public {
        token = new DeployMockERC20("Mock", "MOCK");
        brain = new BrainNFT(token, token, 1 ether, 1 ether, governance);
        bridge = new MockL1ERC721Bridge();
        l2Brain = new BrainNFTL2(address(0x4200000000000000000000000000000000000014), 1, address(brain));
        adapter = new BrainBridgeAdapter(brain, address(l2Brain), bridge);

        vm.startPrank(governance);
        brain.mintReserved(user, 1);
        brain.mintReserved(user, 2);
        brain.mintReserved(user, 3);
        brain.setBridge(address(bridge));
        brain.setBridgeEndpoint(address(adapter), true);
        vm.stopPrank();
    }

    function test_directCanonicalBridgeEscrowsAndReleasesBrain() public {
        vm.startPrank(user);
        brain.approve(address(bridge), 1);
        bridge.bridgeERC721To(address(brain), address(l2Brain), recipient, 1, 200_000, "direct");
        vm.stopPrank();
        assertEq(brain.ownerOf(1), address(bridge), "bridge did not escrow");

        bridge.release(address(brain), user, 1);
        assertEq(brain.ownerOf(1), user, "bridge release failed");
    }

    function test_adapterPinsRemoteTokenAndGasThenEscrowsThroughCanonicalBridge() public {
        vm.prank(user);
        brain.approve(address(adapter), 2);

        vm.expectEmit(true, true, true, true, address(bridge));
        emit MockL1ERC721Bridge.BridgeCalled(address(brain), address(l2Brain), recipient, 2, 200_000, "");
        vm.prank(user);
        adapter.bridgeToL2(2, recipient);

        assertEq(brain.ownerOf(2), address(bridge), "adapter path did not end in bridge escrow");
    }

    function test_adapterRejectsZeroRecipientAndUnrelatedNFTReceiver() public {
        vm.prank(user);
        brain.approve(address(adapter), 3);
        vm.prank(user);
        vm.expectRevert(BrainBridgeAdapter.ZeroRecipient.selector);
        adapter.bridgeToL2(3, address(0));

        vm.expectRevert(BrainBridgeAdapter.UnsupportedNFT.selector);
        adapter.onERC721Received(address(this), user, 999, "");
    }

    function test_bridgeEndpointRevocationBlocksBothAdapterAndBridgeRelease() public {
        vm.startPrank(governance);
        brain.setBridge(address(0));
        brain.setBridgeEndpoint(address(adapter), false);
        vm.stopPrank();

        vm.prank(user);
        brain.approve(address(adapter), 2);
        vm.prank(user);
        vm.expectRevert(IBrainNFT.TransferRestricted.selector);
        adapter.bridgeToL2(2, recipient);
    }

    function test_l2BrainOnlyCanonicalBridgeCanMintOrBurnAndNeverTransfer() public {
        BrainNFTL2 nft = new BrainNFTL2(address(bridge), 1, address(brain));
        assertTrue(nft.supportsInterface(type(IOptimismMintableERC721).interfaceId));

        vm.expectRevert(bytes("BrainNFTL2: only bridge"));
        nft.safeMint(user, 77);

        vm.prank(address(bridge));
        nft.safeMint(user, 77);
        assertEq(nft.ownerOf(77), user);

        vm.prank(user);
        vm.expectRevert(BrainNFTL2.TransferRestricted.selector);
        nft.transferFrom(user, recipient, 77);

        vm.expectRevert(bytes("BrainNFTL2: only bridge"));
        nft.burn(user, 77);
        vm.prank(address(bridge));
        nft.burn(user, 77);
        assertEq(nft.balanceOf(user), 0);
    }
}

contract DeploymentScriptTest is Test {
    DeployMockERC20 based;
    DeployMockERC20 pepe;
    uint256 deployerPk = 0xA11CE;
    address deployer;
    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address l1Brain = makeAddr("l1-brain");
    address l2Bridge = 0x4200000000000000000000000000000000000014;
    address l1Bridge = makeAddr("l1-bridge");

    function setUp() public {
        deployer = vm.addr(deployerPk);
        vm.deal(deployer, 100 ether);
        based = new DeployMockERC20("BASED", "BASED");
        pepe = new DeployMockERC20("PEPE", "PEPE");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(deployerPk)));
    }

    function test_l2DeployScriptReturnsReachableGovernanceAndNoDeployerAdmin() public {
        Deploy.Deployment memory out = new Deploy()
            .runWithConfig(
                Deploy.Config({
                pk: deployerPk,
                basedAI: address(based),
                quorumVotes: 1,
                minDelay: 1 days,
                l2Erc721Bridge: l2Bridge,
                l1BrainNFT: l1Brain,
                l1RemoteChainId: 1,
                guardian: guardian,
                maxReservation: 1 ether,
                pricePerByte: 7,
                pricePerRequest: 101
            })
            );

        assertEq(out.basedAI, address(based));
        assertEq(out.l1BrainNFT, l1Brain);
        assertEq(out.l2Erc721Bridge, l2Bridge);

        BrainNFTL2 brainL2 = BrainNFTL2(out.brainNFT);
        assertEq(brainL2.bridge(), l2Bridge);
        assertEq(brainL2.remoteToken(), l1Brain);
        assertEq(brainL2.remoteChainId(), 1);

        StakingVault staking = StakingVault(out.stakingVault);
        ComputeUnitMarket market = ComputeUnitMarket(out.market);
        RewardDistributor dist = RewardDistributor(out.rewardDistributor);
        TimelockController timelock = TimelockController(payable(out.timelock));

        assertTrue(staking.hasRole(staking.SLASHER_ROLE(), out.scoringRegistry));
        assertTrue(staking.hasRole(staking.REWARDER_ROLE(), out.rewardDistributor));
        assertTrue(dist.hasRole(dist.MARKET_ROLE(), out.market));
        assertTrue(market.hasRole(market.PAUSER_ROLE(), out.timelock));
        assertTrue(market.hasRole(market.PAUSER_ROLE(), guardian));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), out.governor));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), out.governor));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));

        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), out.timelock));
        assertTrue(market.hasRole(market.DEFAULT_ADMIN_ROLE(), out.timelock));
        assertTrue(dist.hasRole(dist.DEFAULT_ADMIN_ROLE(), out.timelock));
        assertFalse(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(market.hasRole(market.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(dist.hasRole(dist.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_l2DeployScriptRejectsMissingBridgeRemoteBeforeRenounce() public {
        Deploy d = new Deploy();
        vm.expectRevert(
            bytes(
                "L1_BRAIN_NFT required: L2 Brains are minted only by bridging from L1; without it governance can never reach quorum after renounce"
            )
        );
        d.runWithConfig(
            Deploy.Config({
                pk: deployerPk,
                basedAI: address(based),
                quorumVotes: 1,
                minDelay: 1 days,
                l2Erc721Bridge: l2Bridge,
                l1BrainNFT: address(0),
                l1RemoteChainId: 1,
                guardian: guardian,
                maxReservation: 1 ether,
                pricePerByte: 7,
                pricePerRequest: 101
            })
        );
    }

    function test_mainnetDeployScriptWithAdapterTransfersGovernanceAndWiresBridge() public {
        DeployMainnet.MainnetDeployment memory out = new DeployMainnet()
            .runWithConfig(deployerPk, address(pepe), address(based), 1 ether, 2 ether, governance, l1Brain, l1Bridge);
        BrainNFT brain = BrainNFT(out.brainNFT);

        assertEq(out.governance, governance);
        assertEq(out.pepecoin, address(pepe));
        assertEq(out.basedAI, address(based));
        assertEq(brain.bridge(), l1Bridge);
        assertTrue(brain.isBridgeEndpoint(out.bridgeAdapter));
        assertTrue(brain.hasRole(brain.GOVERNANCE_ROLE(), governance));
        assertTrue(brain.hasRole(brain.DEFAULT_ADMIN_ROLE(), governance));
        assertFalse(brain.hasRole(brain.GOVERNANCE_ROLE(), deployer));
        assertFalse(brain.hasRole(brain.DEFAULT_ADMIN_ROLE(), deployer));
        assertEq(BrainBridgeAdapter(out.bridgeAdapter).BRAIN_NFT_L2(), l1Brain);
        assertEq(address(BrainBridgeAdapter(out.bridgeAdapter).BRIDGE()), l1Bridge);
    }

    function test_mainnetDeployScriptCanDeployPhaseOneWithoutAdapter() public {
        DeployMainnet.MainnetDeployment memory out = new DeployMainnet()
            .runWithConfig(
                deployerPk,
                address(pepe),
                address(based),
                100_000 ether,
                10_000 ether,
                governance,
                address(0),
                address(0)
            );
        assertEq(out.bridgeAdapter, address(0));
        assertEq(BrainNFT(out.brainNFT).bridge(), address(0));
        assertTrue(BrainNFT(out.brainNFT).hasRole(BrainNFT(out.brainNFT).GOVERNANCE_ROLE(), governance));
    }
}
