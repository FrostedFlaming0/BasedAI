// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";

contract MockBASED is ERC20 {
    constructor() ERC20("BASED", "BASED") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract StakingVaultTest is Test {
    StakingVault vault;
    MockBASED based;

    address admin = makeAddr("admin");
    address slasher = makeAddr("slasher");
    address staker = makeAddr("staker");
    address validator = makeAddr("validator");
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        based = new MockBASED();
        vault = new StakingVault(based, admin);

        vm.prank(admin);
        vault.grantRole(vault.SLASHER_ROLE(), slasher);

        based.mint(staker, 10_000 ether);
        vm.prank(staker);
        based.approve(address(vault), type(uint256).max);
    }

    function test_stake_increasesBalances() public {
        vm.prank(staker);
        vault.stake(1, validator, 100 ether);

        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.brainStake(1), 100 ether);
        assertEq(vault.validatorStake(1, validator), 100 ether);
        assertEq(vault.stakerBalance(1, validator, staker), 100 ether);
    }

    function test_unstake_requiresCooldown() public {
        vm.prank(staker);
        vault.stake(1, validator, 100 ether);

        vm.prank(staker);
        vault.requestUnstake(1, validator, 60 ether);

        vm.prank(staker);
        vm.expectRevert(IStakingVault.UnstakeNotReady.selector);
        vault.claimUnstake(1, validator);

        vm.warp(block.timestamp + 14 days);
        vm.prank(staker);
        vault.claimUnstake(1, validator);

        assertEq(based.balanceOf(staker), 10_000 ether - 40 ether);
    }

    function test_slash_burnsStake() public {
        vm.prank(staker);
        vault.stake(1, validator, 100 ether);

        vm.prank(slasher);
        vault.slash(1, validator, 30 ether, "TEST");

        assertEq(vault.validatorStake(1, validator), 70 ether);
        assertEq(vault.totalStaked(), 70 ether);
        assertEq(based.balanceOf(BURN_ADDRESS), 30 ether);
    }

    function test_effectiveStake_capsAtCentralizationLimit() public {
        // staker stakes 1000; only one Brain in the system; cap is 0.5% of total => 5 ether.
        vm.prank(staker);
        vault.stake(1, validator, 1_000 ether);

        // Total = 1000, cap = 5, effective = 5.
        assertEq(vault.effectiveBrainStake(1), 5 ether);
    }
}
