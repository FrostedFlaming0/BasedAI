// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {ComputeUnitMarket} from "../src/market/ComputeUnitMarket.sol";
import {SubnetRegistry} from "../src/subnet/SubnetRegistry.sol";
import {ISubnetRegistry} from "../src/interfaces/ISubnetRegistry.sol";
import {RewardDistributor} from "../src/reward/RewardDistributor.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";

contract MockBASED is ERC20 {
    constructor() ERC20("BASED", "BASED") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Regression tests for the audited Critical/High findings.
contract SecurityFixesTest is Test {
    MockBASED based;

    address admin = makeAddr("admin");
    address slasher = makeAddr("slasher");
    address a = makeAddr("a");
    address b = makeAddr("b");
    address validator = makeAddr("validator");
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        based = new MockBASED();
    }

    // --- StakingVault: slashing is pro-rata and never bricks (C-02 / finding #3) ---

    function _vault() internal returns (StakingVault v) {
        v = new StakingVault(based, admin);
        bytes32 role = v.SLASHER_ROLE();
        vm.prank(admin);
        v.grantRole(role, slasher);
        for (uint256 i; i < 2; i++) {
            address s = i == 0 ? a : b;
            based.mint(s, 1_000 ether);
            vm.prank(s);
            based.approve(address(v), type(uint256).max);
        }
    }

    function test_slash_isProRata_andBothCanExit() public {
        StakingVault v = _vault();
        vm.prank(a);
        v.stake(1, validator, 100 ether);
        vm.prank(b);
        v.stake(1, validator, 100 ether);

        // Slash half the pool.
        vm.prank(slasher);
        v.slash(1, validator, 100 ether, "TEST");

        // Each staker bears half the loss — neither escapes, neither is bricked.
        assertApproxEqAbs(v.stakerBalance(1, validator, a), 50 ether, 1);
        assertApproxEqAbs(v.stakerBalance(1, validator, b), 50 ether, 1);

        uint256 balA = v.stakerBalance(1, validator, a);
        uint256 balB = v.stakerBalance(1, validator, b);
        vm.prank(a);
        v.requestUnstake(1, validator, balA);
        vm.prank(b);
        v.requestUnstake(1, validator, balB);
        vm.warp(block.timestamp + 14 days);

        vm.prank(a);
        v.claimUnstake(1, validator); // would underflow/revert in v1
        vm.prank(b);
        v.claimUnstake(1, validator);

        assertApproxEqAbs(based.balanceOf(a), 1_000 ether - 50 ether, 1);
        assertApproxEqAbs(based.balanceOf(b), 1_000 ether - 50 ether, 1);
        assertEq(based.balanceOf(BURN), 100 ether);
    }

    function test_pendingUnstake_isStillSlashable() public {
        StakingVault v = _vault();
        vm.prank(a);
        v.stake(1, validator, 100 ether);
        vm.prank(b);
        v.stake(1, validator, 100 ether);

        // A tries to escape by requesting unstake BEFORE the slash.
        vm.prank(a);
        v.requestUnstake(1, validator, 100 ether);

        vm.prank(slasher);
        v.slash(1, validator, 100 ether, "TEST");

        vm.warp(block.timestamp + 14 days);
        vm.prank(a);
        v.claimUnstake(1, validator);

        // A's pending bore the slash pro-rata: ~50, not the full 100. No evasion.
        assertApproxEqAbs(based.balanceOf(a), 1_000 ether - 50 ether, 1);
    }

    // --- StakingVault: fully-slashed pool cannot confiscate new deposits (finding #2) ---

    function test_stake_intoFullySlashedPool_reverts_noConfiscation() public {
        StakingVault v = _vault();
        // a stakes, then the pool is fully slashed to zero assets while a's shares remain.
        vm.prank(a);
        v.stake(1, validator, 100 ether);
        vm.prank(slasher);
        v.slash(1, validator, 100 ether, "FULL");
        assertEq(v.validatorStake(1, validator), 0);

        // b's new deposit must NOT be diluted by a's stale, valueless shares: the insolvent pool
        // refuses the deposit rather than handing a a cut of b's money.
        vm.prank(b);
        vm.expectRevert(IStakingVault.PoolInsolvent.selector);
        v.stake(1, validator, 100 ether);

        // b kept every token; nothing was confiscated.
        assertEq(based.balanceOf(b), 1_000 ether);
    }

    function test_stake_zeroShareDeposit_reverts() public {
        StakingVault v = _vault();
        vm.prank(a);
        v.stake(1, validator, 100 ether);
        // Reward growth without new shares: 1 share now backs far more than 1 wei of assets.
        based.mint(admin, 1_000 ether);
        vm.prank(admin);
        based.approve(address(v), type(uint256).max);
        bytes32 rewarder = v.REWARDER_ROLE();
        vm.prank(admin);
        v.grantRole(rewarder, admin);
        vm.prank(admin);
        v.notifyReward(1, validator, 900 ether); // pool now 1000 assets / 100e18 shares

        // A dust deposit that would round to zero shares is rejected, not silently gifted away.
        vm.prank(b);
        vm.expectRevert(IStakingVault.ZeroShares.selector);
        v.stake(1, validator, 1); // 1 * shares / assets rounds to 0
    }

    function test_snapshot_pastStakeIsQueryable() public {
        StakingVault v = _vault();
        uint48 t0 = v.clock();
        vm.warp(block.timestamp + 10);
        vm.prank(a);
        v.stake(7, validator, 100 ether);
        uint48 t1 = v.clock();

        // Stake added at t1 is invisible at t0 (snapshot) but visible at t1.
        assertEq(v.getPastBrainStake(7, t0), 0);
        assertEq(v.getPastTotalStaked(t0), 0);
        assertEq(v.getPastBrainStake(7, t1), 100 ether);
    }

    // --- ComputeUnitMarket: bound output, counter-signed amount, protected collateral (C-01/H-01) ---

    /// @dev A market wired to a real (but unconfigured) registry + distributor. brainId used in
    ///      these tests is inactive, so redemption pays the miner in full (pre-split behavior).
    function _wiredMarket() internal returns (ComputeUnitMarket m) {
        SubnetRegistry registry = new SubnetRegistry(IERC721(address(based)), based);
        StakingVault staking = new StakingVault(based, admin);
        RewardDistributor dist =
            new RewardDistributor(based, ISubnetRegistry(address(registry)), IStakingVault(address(staking)), admin);
        m = new ComputeUnitMarket(
            based, ISubnetRegistry(address(registry)), IRewardDistributor(address(dist)), 1 ether, 1, 1, admin
        );
    }

    function _signReceipt(ComputeUnitMarket m, uint256 pk, ComputeUnitMarket.Receipt memory r)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = m.receiptDigest(r);
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(pk, digest);
        return abi.encodePacked(rr, ss, vv);
    }

    function test_redeem_requiresNonZeroResponseAndChargesExactAmount() public {
        ComputeUnitMarket m = _wiredMarket();
        (address user, uint256 userPk) = makeAddrAndKey("user");
        address miner = makeAddr("miner");
        based.mint(user, 1_000 ether);
        vm.startPrank(user);
        based.approve(address(m), type(uint256).max);
        m.deposit(500 ether);
        vm.stopPrank();

        ComputeUnitMarket.Receipt memory r = ComputeUnitMarket.Receipt({
            user: user,
            miner: miner,
            brainId: 1,
            promptHash: keccak256("prompt"),
            responseHash: bytes32(0), // not yet bound
            amount: 10 ether, // actual cost <= budget
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 1
        });

        // Zero response hash is rejected.
        bytes memory sig0 = _signReceipt(m, userPk, r);
        vm.prank(miner);
        vm.expectRevert(ComputeUnitMarket.EmptyResponse.selector);
        m.redeem(r, sig0);

        // Bind the delivered output and re-sign (the user counter-signs the final receipt).
        r.responseHash = keccak256("response");
        bytes memory sig = _signReceipt(m, userPk, r);
        vm.prank(miner);
        m.redeem(r, sig);

        // Exactly the actual cost is transferred — not the full budget.
        assertEq(based.balanceOf(miner), 10 ether);
        assertEq(m.balances(user), 490 ether);
    }

    function test_withdraw_isDelayed_soCollateralCannotBeYanked() public {
        ComputeUnitMarket m = _wiredMarket();
        (address user,) = makeAddrAndKey("user2");
        based.mint(user, 1_000 ether);
        vm.startPrank(user);
        based.approve(address(m), type(uint256).max);
        m.deposit(100 ether);
        // Cannot withdraw instantly; must request and wait out the delay.
        m.requestWithdraw(100 ether);
        vm.expectRevert(ComputeUnitMarket.WithdrawalNotReady.selector);
        m.withdraw();
        vm.warp(block.timestamp + 1 days);
        m.withdraw();
        vm.stopPrank();
        assertEq(based.balanceOf(user), 1_000 ether);
    }
}
