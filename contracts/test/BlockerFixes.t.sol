// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BrainNFT} from "../src/tokens/BrainNFT.sol";
import {IBrainNFT} from "../src/interfaces/IBrainNFT.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {ScoringRegistry} from "../src/scoring/ScoringRegistry.sol";
import {IScoringRegistry} from "../src/interfaces/IScoringRegistry.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {BrainNFTL2} from "../src/tokens/BrainNFTL2.sol";
import {IOptimismMintableERC721} from "../src/interfaces/IOptimismMintableERC721.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Regression tests for Codex-confirmed testnet blockers #4 (one-way bridge), #5 (scoring
///         epoch/quorum), and #6 (deploy admin deadlock).
contract BlockerFixesTest is Test {
    using MessageHashUtils for bytes32;

    MockToken based;
    address gov = makeAddr("gov");

    function setUp() public {
        based = new MockToken();
    }

    // ---------------------------------------------------------------------------------------------
    // #4 BrainNFT: the soulbound exception must allow escrow -> user withdrawal (not just deposit).
    // ---------------------------------------------------------------------------------------------

    function _brainNFT() internal returns (BrainNFT nft) {
        // Reserved Brains carry no stake and are soulbound, so we can mint and move them without the
        // staking tokens. governance = gov so we can set bridge endpoints.
        nft = new BrainNFT(based, based, 1 ether, 1 ether, gov);
    }

    function test_bridge_isOneWayWithoutAllowlist_andTwoWayWithIt() public {
        BrainNFT nft = _brainNFT();
        address user = makeAddr("user");
        address adapter = makeAddr("adapter"); // L1 escrow-in helper
        address escrow = makeAddr("escrow"); // canonical bridge escrow (release side)
        address other = makeAddr("other");

        vm.prank(gov);
        nft.mintReserved(user, 1);

        // Soulbound: a plain user->user transfer is forbidden.
        vm.prank(user);
        vm.expectRevert(IBrainNFT.TransferRestricted.selector);
        nft.transferFrom(user, other, 1);

        // Authorize BOTH endpoints: the adapter (deposit) and the canonical escrow (withdrawal).
        vm.startPrank(gov);
        nft.setBridge(adapter);
        nft.setBridgeEndpoint(escrow, true);
        vm.stopPrank();

        // Deposit leg: user -> adapter, then adapter -> escrow.
        vm.prank(user);
        nft.transferFrom(user, adapter, 1);
        assertEq(nft.ownerOf(1), adapter);
        vm.prank(adapter);
        nft.transferFrom(adapter, escrow, 1);
        assertEq(nft.ownerOf(1), escrow);

        // Withdrawal leg: escrow -> user. This is the transfer that reverted under the single-`bridge`
        // guard (the one-way lock); with the allowlist it succeeds.
        vm.prank(escrow);
        nft.transferFrom(escrow, user, 1);
        assertEq(nft.ownerOf(1), user);
    }

    function test_bridge_revokeEndpoint_restoresSoulbound() public {
        BrainNFT nft = _brainNFT();
        address user = makeAddr("user");
        address escrow = makeAddr("escrow");
        vm.prank(gov);
        nft.mintReserved(user, 2);
        vm.prank(gov);
        nft.setBridgeEndpoint(escrow, true);
        vm.prank(user);
        nft.transferFrom(user, escrow, 2);

        // Revoke, then escrow can no longer move it to an arbitrary user.
        vm.prank(gov);
        nft.setBridgeEndpoint(escrow, false);
        vm.prank(escrow);
        vm.expectRevert(IBrainNFT.TransferRestricted.selector);
        nft.transferFrom(escrow, user, 2);
    }

    // ---------------------------------------------------------------------------------------------
    // #4 (real bridge) BrainNFTL2 is a soulbound OptimismMintableERC721 driven by the canonical bridge.
    // ---------------------------------------------------------------------------------------------

    function test_brainNFTL2_isOptimismMintableAndSoulbound() public {
        address bridge = makeAddr("l2bridge"); // stands in for Ink's L2ERC721Bridge predeploy
        address l1Token = makeAddr("l1brain");
        BrainNFTL2 nft = new BrainNFTL2(bridge, 1, l1Token);

        // Advertises the exact interface Ink's L2ERC721Bridge checks via ERC165.
        assertTrue(nft.supportsInterface(type(IOptimismMintableERC721).interfaceId), "not OptimismMintable");
        assertEq(nft.bridge(), bridge);
        assertEq(nft.remoteToken(), l1Token);
        assertEq(nft.remoteChainId(), 1);

        // Only the bridge may mint/burn.
        vm.expectRevert(bytes("BrainNFTL2: only bridge"));
        nft.safeMint(address(this), 1);

        address user = makeAddr("holder");
        vm.prank(bridge);
        nft.safeMint(user, 1);
        assertEq(nft.ownerOf(1), user);

        // Soulbound: peer-to-peer transfer is forbidden; only the bridge can burn it back out.
        address other = makeAddr("other");
        vm.prank(user);
        vm.expectRevert(BrainNFTL2.TransferRestricted.selector);
        nft.transferFrom(user, other, 1);

        vm.prank(bridge);
        nft.burn(user, 1);
        assertEq(nft.balanceOf(user), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // #5 ScoringRegistry: completed-epoch only, no empty/zero-stake quorum, ceil-rounded quorum.
    // ---------------------------------------------------------------------------------------------

    struct ScoringEnv {
        StakingVault staking;
        ScoringRegistry scoring;
        uint64 genesis;
    }

    function _scoring() internal returns (ScoringEnv memory e) {
        e.staking = new StakingVault(based, gov);
        e.genesis = uint64(block.timestamp);
        e.scoring = new ScoringRegistry(e.staking, e.genesis);
    }

    function _stakeTo(StakingVault staking, address validator, uint256 amount) internal {
        address staker = makeAddr(string(abi.encodePacked("staker", validator)));
        based.mint(staker, amount);
        vm.startPrank(staker);
        based.approve(address(staking), amount);
        staking.stake(0, validator, amount);
        vm.stopPrank();
    }

    function _sign(ScoringRegistry scoring, uint256 pk, uint64 epoch, bytes32 root)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = scoring.commitmentDigest(epoch, 0, root);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_proposeEpoch_rejectsCurrentInProgressEpoch() public {
        ScoringEnv memory e = _scoring();
        (address val, uint256 pk) = makeAddrAndKey("val");
        _stakeTo(e.staking, val, 100 ether);

        // Move into epoch 1 so epoch 1 is the CURRENT (in-progress) epoch.
        vm.warp(e.genesis + e.scoring.EPOCH_LENGTH());
        assertEq(e.scoring.currentEpoch(), 1);

        bytes32 root = keccak256("root");
        address[] memory signers = new address[](1);
        signers[0] = val;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(e.scoring, pk, 1, root);

        // Committing the still-in-progress epoch is rejected.
        vm.expectRevert(IScoringRegistry.EpochNotComplete.selector);
        e.scoring.proposeEpoch(1, 0, root, signers, sigs);

        // The completed epoch 0 is accepted.
        sigs[0] = _sign(e.scoring, pk, 0, root);
        e.scoring.proposeEpoch(0, 0, root, signers, sigs);
        assertEq(e.scoring.getEpoch(0, 0).merkleRoot, root);
    }

    function test_proposeEpoch_rejectsEmptySignerSet() public {
        ScoringEnv memory e = _scoring();
        vm.warp(e.genesis + e.scoring.EPOCH_LENGTH()); // complete epoch 0
        address[] memory none = new address[](0);
        bytes[] memory noSigs = new bytes[](0);
        // An empty signer set must not be able to install an arbitrary root (the empty-quorum defect).
        vm.expectRevert(IScoringRegistry.NoSigners.selector);
        e.scoring.proposeEpoch(0, 0, keccak256("evil"), none, noSigs);
    }

    function test_proposeEpoch_rejectsZeroTotalStake() public {
        ScoringEnv memory e = _scoring();
        (address val, uint256 pk) = makeAddrAndKey("val");
        // val signs but NO stake exists anywhere -> zero total stake -> no real quorum.
        vm.warp(e.genesis + e.scoring.EPOCH_LENGTH());
        address[] memory signers = new address[](1);
        signers[0] = val;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(e.scoring, pk, 0, keccak256("root"));
        vm.expectRevert(IScoringRegistry.EmptyQuorum.selector);
        e.scoring.proposeEpoch(0, 0, keccak256("root"), signers, sigs);
    }

    function test_proposeEpoch_insufficientStake_reverts() public {
        ScoringEnv memory e = _scoring();
        (address big, uint256 bigPk) = makeAddrAndKey("big");
        (address small, uint256 smallPk) = makeAddrAndKey("small");
        // Total stake 100; `small` holds only 40 (< ceil(50.01%)). Signing alone can't reach quorum.
        _stakeTo(e.staking, big, 60 ether);
        _stakeTo(e.staking, small, 40 ether);
        vm.warp(e.genesis + e.scoring.EPOCH_LENGTH());

        bytes32 root = keccak256("root");
        address[] memory signers = new address[](1);
        signers[0] = small;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(e.scoring, smallPk, 0, root);
        vm.expectRevert(IScoringRegistry.InsufficientSignerStake.selector);
        e.scoring.proposeEpoch(0, 0, root, signers, sigs);

        // A >50% signer (big, 60) clears the ceil-rounded quorum.
        signers[0] = big;
        sigs[0] = _sign(e.scoring, bigPk, 0, root);
        e.scoring.proposeEpoch(0, 0, root, signers, sigs);
        assertEq(e.scoring.getEpoch(0, 0).merkleRoot, root);
    }

    function test_quorum_isBrainLocal() public {
        ScoringEnv memory e = _scoring();
        (address signer, uint256 pk) = makeAddrAndKey("brain-zero-validator");
        _stakeTo(e.staking, signer, 60 ether);
        // A large unrelated Brain must not dilute Brain 0 quorum.
        address whale = makeAddr("other-brain-validator");
        address staker = makeAddr("other-brain-staker");
        based.mint(staker, 10_000 ether);
        vm.startPrank(staker);
        based.approve(address(e.staking), 10_000 ether);
        e.staking.stake(1, whale, 10_000 ether);
        vm.stopPrank();

        vm.warp(e.genesis + e.scoring.EPOCH_LENGTH());
        bytes32 root = keccak256("brain-zero-root");
        address[] memory signers = new address[](1);
        signers[0] = signer;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(e.scoring, pk, 0, root);
        e.scoring.proposeEpoch(0, 0, root, signers, sigs);
        assertEq(e.scoring.getEpoch(0, 0).merkleRoot, root);
        assertEq(e.scoring.getEpoch(0, 1).merkleRoot, bytes32(0));
    }

    // ---------------------------------------------------------------------------------------------
    // #6 Deploy: the script must refuse to renounce admin if no Brain minter is configured.
    // ---------------------------------------------------------------------------------------------

    /// @dev One test (not two) so the process-global `vm.setEnv("L1_BRAIN_NFT", ...)` cannot race
    ///      across test functions: a missing L1 Brain (the only L2 mint source via the bridge) MUST
    ///      revert before any renounce; present, it passes the reachability assertions and completes.
    function test_deploy_deadlockGuard() public {
        Deploy d = new Deploy();
        // Deterministic throwaway key; never used for real funds.
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "0x0000000000000000000000000000000000000000000000000000000000000001");
        vm.setEnv("BASEDAI_L2", vm.toString(address(based)));

        // Missing L1 Brain remote token -> no L2 Brain mint path -> the script refuses to deploy (and
        // thus to renounce), avoiding the permanent admin deadlock.
        vm.setEnv("L1_BRAIN_NFT", vm.toString(address(0)));
        vm.expectRevert(
            bytes(
                "L1_BRAIN_NFT required: L2 Brains are minted only by bridging from L1; without it governance can never reach quorum after renounce"
            )
        );
        d.run();

        // With the L1 Brain wired (and L2_ERC721_BRIDGE defaulting to the canonical predeploy), the
        // deploy reaches the reachability assertions and completes cleanly.
        vm.setEnv("L1_BRAIN_NFT", vm.toString(makeAddr("l1brain")));
        d.run();
    }
}
