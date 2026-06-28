// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {SubnetRegistry} from "../src/subnet/SubnetRegistry.sol";
import {ISubnetRegistry} from "../src/interfaces/ISubnetRegistry.sol";
import {RewardDistributor} from "../src/reward/RewardDistributor.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";
import {ComputeUnitMarket} from "../src/market/ComputeUnitMarket.sol";
import {BrainNFTL2} from "../src/tokens/BrainNFTL2.sol";

contract MockBASED is ERC20 {
    constructor() ERC20("BASED", "BASED") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Tests for the v2 fee economy: fee split, delegated yield, bounded validator
///         distribution, and the market circuit breaker.
contract EconomicLayerTest is Test {
    MockBASED based;
    BrainNFTL2 nft;
    SubnetRegistry registry;
    StakingVault staking;
    RewardDistributor dist;
    ComputeUnitMarket market;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address brainOwner = makeAddr("brainOwner");
    uint256 constant BRAIN = 1;
    uint256 constant MAX_RESERVATION = 1 ether;

    function setUp() public {
        based = new MockBASED();
        // BrainNFTL2 is an OptimismMintableERC721 minted only by its bridge; this test acts as the
        // bridge (1 = L1 chain id, a dummy L1 remote token).
        nft = new BrainNFTL2(address(this), 1, address(0xB1));
        nft.safeMint(brainOwner, BRAIN);

        registry = new SubnetRegistry(IERC721(address(nft)), based);
        staking = new StakingVault(based, admin);
        dist = new RewardDistributor(based, ISubnetRegistry(address(registry)), IStakingVault(address(staking)), admin);
        market = new ComputeUnitMarket(
            based, ISubnetRegistry(address(registry)), IRewardDistributor(address(dist)), MAX_RESERVATION, 1, 1, admin
        );

        vm.startPrank(admin);
        dist.grantRole(dist.MARKET_ROLE(), address(market));
        staking.grantRole(staking.REWARDER_ROLE(), address(dist));
        market.grantRole(market.PAUSER_ROLE(), guardian);
        vm.stopPrank();
    }

    // --- helpers ---

    function _activateBrainNoFee() internal {
        vm.startPrank(brainOwner);
        registry.activate(BRAIN, keccak256("model"), "ipfs://model");
        registry.setRegistrationFee(BRAIN, 0);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amt) internal {
        based.mint(who, amt);
        vm.prank(who);
        based.approve(address(staking), type(uint256).max);
    }

    /// @dev Register `v` as a validator on BRAIN and stake `amt` to it from `staker`.
    function _validatorWithStake(address v, address staker, uint256 amt) internal {
        vm.prank(v);
        registry.registerValidator(BRAIN, 0);
        _fund(staker, amt);
        vm.prank(staker);
        staking.stake(BRAIN, v, amt);
    }

    function _sorted(address x, address y) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        (arr[0], arr[1]) = x < y ? (x, y) : (y, x);
    }

    // --- StakingVault.notifyReward (delegated yield) ---

    function test_notifyReward_accruesToSharesProRata() public {
        address v = makeAddr("val");
        address s1 = makeAddr("s1");
        address s2 = makeAddr("s2");
        _fund(s1, 100 ether);
        _fund(s2, 300 ether);
        vm.prank(s1);
        staking.stake(BRAIN, v, 100 ether);
        vm.prank(s2);
        staking.stake(BRAIN, v, 300 ether);

        // Reward 80 BASED into the pool from a REWARDER.
        based.mint(address(this), 80 ether);
        based.approve(address(staking), 80 ether);
        bytes32 rwd = staking.REWARDER_ROLE();
        vm.prank(admin);
        staking.grantRole(rwd, address(this));
        staking.notifyReward(BRAIN, v, 80 ether);

        // s1 had 25% of the pool, s2 75% — yield splits the same way.
        assertApproxEqAbs(staking.stakerBalance(BRAIN, v, s1), 120 ether, 2);
        assertApproxEqAbs(staking.stakerBalance(BRAIN, v, s2), 360 ether, 2);
    }

    function test_notifyReward_revertsWithoutStake() public {
        address v = makeAddr("val");
        based.mint(address(this), 10 ether);
        based.approve(address(staking), 10 ether);
        bytes32 rwd = staking.REWARDER_ROLE();
        vm.prank(admin);
        staking.grantRole(rwd, address(this));
        vm.expectRevert(IStakingVault.NoStakeToReward.selector);
        staking.notifyReward(BRAIN, v, 10 ether);
    }

    function test_notifyReward_onlyRewarderRole() public {
        address v = makeAddr("val");
        vm.expectRevert();
        staking.notifyReward(BRAIN, v, 1 ether);
    }

    // --- ComputeUnitMarket fee split ---

    function _depositAndRedeem(uint256 amount) internal returns (address user, address miner) {
        uint256 userPk;
        (user, userPk) = makeAddrAndKey("user");
        miner = makeAddr("miner");
        based.mint(user, 1_000 ether);
        vm.startPrank(user);
        based.approve(address(market), type(uint256).max);
        market.deposit(1_000 ether);
        vm.stopPrank();

        ComputeUnitMarket.Receipt memory r = ComputeUnitMarket.Receipt({
            user: user,
            miner: miner,
            brainId: BRAIN,
            promptHash: keccak256("p"),
            responseHash: keccak256("resp"),
            amount: amount,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 1
        });
        bytes32 digest = market.receiptDigest(r);
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(userPk, digest);
        vm.prank(miner);
        market.redeem(r, abi.encodePacked(rr, ss, vv));
    }

    function test_redeem_splitsSeventyTwentyTwoEight() public {
        _activateBrainNoFee();
        uint256 amount = 1_000 ether;
        (, address miner) = _depositAndRedeem(amount);

        // owner 8% of gross; node share 92%; miner = 76.09% of node share = 70% of gross.
        uint256 ownerAmt = amount * 800 / 10_000; // 80
        uint256 nodeShare = amount - ownerAmt; // 920
        uint256 minerAmt = nodeShare * 7609 / 10_000; // ~700.028
        uint256 validatorAmt = nodeShare - minerAmt; // ~219.972

        assertEq(based.balanceOf(brainOwner), ownerAmt, "owner 8%");
        assertEq(based.balanceOf(miner), minerAmt, "miner ~70%");
        assertEq(dist.pendingValidatorFees(BRAIN), validatorAmt, "validator ~22% accrued");
        assertEq(based.balanceOf(address(dist)), validatorAmt, "distributor holds validator share");
        // Conservation: every wei is accounted for.
        assertEq(ownerAmt + minerAmt + validatorAmt, amount, "no wei lost");
        // Split is ~70/22/8.
        assertApproxEqRel(minerAmt, 700 ether, 0.001e18);
        assertApproxEqRel(validatorAmt, 220 ether, 0.001e18);
    }

    function test_redeem_ownerFeeFollowsNftTransfer() public {
        // Owner is cached at activation; the Brain NFT is then transferred to a new holder.
        _activateBrainNoFee();
        address newOwner = makeAddr("newOwner");
        // The L2 Brain is soulbound; ownership changes only via the bridge (re-bridge = burn old,
        // mint new). Simulate that: the test contract is the bridge.
        nft.burn(brainOwner, BRAIN);
        nft.safeMint(newOwner, BRAIN);

        uint256 amount = 1_000 ether;
        (, address miner) = _depositAndRedeem(amount);
        uint256 ownerAmt = amount * 800 / 10_000;

        // The owner fee follows the live NFT owner, not the stale activation-time address.
        assertEq(based.balanceOf(newOwner), ownerAmt, "fee follows transfer");
        assertEq(based.balanceOf(brainOwner), 0, "stale owner gets nothing");
        assertTrue(miner != address(0));
    }

    function test_quote_meteredPricing() public {
        vm.prank(admin);
        market.setPricing(2, 100); // 2 wei/token, 100 wei/request
        // charge = pricePerRequest + pricePerByte * (promptBytes + responseBytes)
        assertEq(market.quote(10, 20), 100 + 2 * 30);
        assertEq(market.pricePerByte(), 2);
        assertEq(market.pricePerRequest(), 100);
    }

    function test_setPricing_onlyAdmin() public {
        vm.expectRevert();
        market.setPricing(1, 1);
        vm.prank(admin);
        market.setPricing(1, 1);
        assertEq(market.quote(0, 0), 1);
    }

    function test_redeem_inactiveBrainPaysMinerFull() public {
        // BRAIN not activated -> getSubnet inactive -> miner gets 100%, nothing accrues.
        uint256 amount = 100 ether;
        (, address miner) = _depositAndRedeem(amount);
        assertEq(based.balanceOf(miner), amount);
        assertEq(dist.pendingValidatorFees(BRAIN), 0);
        assertEq(based.balanceOf(brainOwner), 0);
    }

    // --- Circuit breaker ---

    function test_pause_blocksRedeemAndDeposit_butNotWithdraw() public {
        _activateBrainNoFee();
        address user = makeAddr("u");
        based.mint(user, 100 ether);
        vm.startPrank(user);
        based.approve(address(market), type(uint256).max);
        market.deposit(100 ether);
        market.requestWithdraw(100 ether);
        vm.stopPrank();

        vm.prank(guardian);
        market.pause();

        vm.startPrank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.deposit(1 ether);
        vm.stopPrank();

        // Withdrawals stay open so a pause never traps funds.
        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        market.withdraw();
        assertEq(based.balanceOf(user), 100 ether);
    }

    function test_pause_onlyPauserRole() public {
        vm.expectRevert();
        market.pause();
    }

    // --- RewardDistributor: bounded, griefing-resistant distribution ---

    function _seedValidatorFees(uint256 amount) internal {
        // Simulate the market recording fees (transfer custody + record).
        based.mint(address(market), amount);
        vm.prank(address(market));
        based.transfer(address(dist), amount);
        vm.prank(address(market));
        dist.recordFees(BRAIN, amount);
    }

    function test_distribute_proRataByStakeIntoYield() public {
        _activateBrainNoFee();
        address v1 = makeAddr("v1");
        address v2 = makeAddr("v2");
        _validatorWithStake(v1, makeAddr("sv1"), 300 ether);
        _validatorWithStake(v2, makeAddr("sv2"), 100 ether);

        _seedValidatorFees(220 ether);
        dist.distribute(BRAIN, _sorted(v1, v2));

        // v1 has 75% of validator stake, v2 25% -> pools grow by 165 / 55.
        assertApproxEqAbs(staking.validatorStake(BRAIN, v1), 300 ether + 165 ether, 2);
        assertApproxEqAbs(staking.validatorStake(BRAIN, v2), 100 ether + 55 ether, 2);
        assertEq(dist.pendingValidatorFees(BRAIN), 0);
    }

    function test_distribute_revertsOnIncompleteSet() public {
        _activateBrainNoFee();
        address v1 = makeAddr("v1");
        address v2 = makeAddr("v2");
        _validatorWithStake(v1, makeAddr("sv1"), 300 ether);
        _validatorWithStake(v2, makeAddr("sv2"), 100 ether);
        _seedValidatorFees(100 ether);

        // Omitting v2 to concentrate rewards on v1 is rejected.
        address[] memory subset = new address[](1);
        subset[0] = v1;
        vm.expectRevert(IRewardDistributor.IncompleteValidatorSet.selector);
        dist.distribute(BRAIN, subset);
    }

    function test_distribute_revertsOnUnsortedOrNonValidator() public {
        _activateBrainNoFee();
        address v1 = makeAddr("v1");
        address v2 = makeAddr("v2");
        _validatorWithStake(v1, makeAddr("sv1"), 300 ether);
        _validatorWithStake(v2, makeAddr("sv2"), 100 ether);
        _seedValidatorFees(100 ether);

        // Descending order (=> would allow a duplicate) is rejected.
        address[] memory bad = new address[](2);
        (bad[0], bad[1]) = v1 < v2 ? (v2, v1) : (v1, v2);
        vm.expectRevert(IRewardDistributor.ValidatorsNotSorted.selector);
        dist.distribute(BRAIN, bad);
    }

    function test_recordFees_onlyMarketRole() public {
        vm.expectRevert(IRewardDistributor.NotMarket.selector);
        dist.recordFees(BRAIN, 1 ether);
    }

    function test_distribute_revertsWhenNothingPending() public {
        _activateBrainNoFee();
        address v1 = makeAddr("v1");
        _validatorWithStake(v1, makeAddr("sv1"), 100 ether);
        address[] memory one = new address[](1);
        one[0] = v1;
        vm.expectRevert(IRewardDistributor.NothingToDistribute.selector);
        dist.distribute(BRAIN, one);
    }

    // --- End-to-end: inference payment -> validator yield ---

    function test_endToEnd_redeemThenDistributeYieldsStakers() public {
        _activateBrainNoFee();
        address v1 = makeAddr("v1");
        address staker = makeAddr("staker");
        _validatorWithStake(v1, staker, 100 ether);

        uint256 before = staking.stakerBalance(BRAIN, v1, staker);
        _depositAndRedeem(1_000 ether); // accrues ~219.97 to the distributor

        address[] memory one = new address[](1);
        one[0] = v1;
        dist.distribute(BRAIN, one);

        // The sole validator's sole staker captured the entire validator fee share as yield.
        uint256 gained = staking.stakerBalance(BRAIN, v1, staker) - before;
        assertApproxEqRel(gained, 220 ether, 0.001e18);
    }

    // --- Pre-authorization reservation cap (Option B: bounds the no-delivery fallback) ---

    /// @dev The same sentinel the client signs: keccak(promptHash, nonce). Must match the contract.
    function _sentinel(bytes32 promptHash, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(promptHash, bytes32(nonce)));
    }

    function _buildSigned(
        address user,
        uint256 userPk,
        address miner,
        bytes32 promptHash,
        bytes32 responseHash,
        uint256 amount,
        uint256 nonce
    ) internal view returns (ComputeUnitMarket.Receipt memory r, bytes memory sig) {
        r = ComputeUnitMarket.Receipt({
            user: user,
            miner: miner,
            brainId: BRAIN,
            promptHash: promptHash,
            responseHash: responseHash,
            amount: amount,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: nonce
        });
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(userPk, market.receiptDigest(r));
        sig = abi.encodePacked(rr, ss, vv);
    }

    function _fundedUser() internal returns (address user, uint256 pk) {
        (user, pk) = makeAddrAndKey("capuser");
        based.mint(user, 10_000 ether);
        vm.startPrank(user);
        based.approve(address(market), type(uint256).max);
        market.deposit(10_000 ether);
        vm.stopPrank();
    }

    function test_preAuth_overCap_reverts() public {
        (address user, uint256 pk) = _fundedUser();
        address miner = makeAddr("miner");
        bytes32 promptHash = keccak256("prompt");
        // A pre-auth (sentinel responseHash) for more than the reservation cap is rejected.
        (ComputeUnitMarket.Receipt memory r, bytes memory sig) =
            _buildSigned(user, pk, miner, promptHash, _sentinel(promptHash, 1), MAX_RESERVATION + 1, 1);
        vm.prank(miner);
        vm.expectRevert(ComputeUnitMarket.ReservationExceedsCap.selector);
        market.redeem(r, sig);
    }

    function test_preAuth_atCap_redeems() public {
        (address user, uint256 pk) = _fundedUser();
        address miner = makeAddr("miner");
        bytes32 promptHash = keccak256("prompt");
        // At or below the cap, the pre-auth fallback redeems normally.
        (ComputeUnitMarket.Receipt memory r, bytes memory sig) =
            _buildSigned(user, pk, miner, promptHash, _sentinel(promptHash, 7), MAX_RESERVATION, 7);
        vm.prank(miner);
        market.redeem(r, sig);
        assertEq(based.balanceOf(miner), MAX_RESERVATION); // brain inactive -> miner gets it all
    }

    function test_finalReceipt_notCapped() public {
        (address user, uint256 pk) = _fundedUser();
        address miner = makeAddr("miner");
        bytes32 promptHash = keccak256("prompt");
        // A real (non-sentinel) responseHash is a client-counter-signed FINAL receipt: not capped,
        // even far above the reservation, because the client verified the delivered output first.
        bytes32 realHash = keccak256("the actual delivered response text");
        assertTrue(realHash != _sentinel(promptHash, 3));
        (ComputeUnitMarket.Receipt memory r, bytes memory sig) =
            _buildSigned(user, pk, miner, promptHash, realHash, 500 ether, 3);
        vm.prank(miner);
        market.redeem(r, sig);
        assertEq(based.balanceOf(miner), 500 ether);
    }

    function test_setMaxReservation_onlyAdmin() public {
        vm.expectRevert();
        market.setMaxReservation(5 ether);
        vm.prank(admin);
        market.setMaxReservation(5 ether);
        assertEq(market.maxReservation(), 5 ether);
    }
}
