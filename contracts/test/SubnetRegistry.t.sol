// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SubnetRegistry} from "../src/subnet/SubnetRegistry.sol";
import {ISubnetRegistry} from "../src/interfaces/ISubnetRegistry.sol";

contract MockBASED is ERC20 {
    constructor() ERC20("BASED", "BASED") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockBrainNFT is ERC721 {
    constructor() ERC721("Brain", "BRAIN") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract SubnetRegistryTest is Test {
    SubnetRegistry registry;
    MockBASED based;
    MockBrainNFT nft;

    address owner = makeAddr("owner");
    address miner = makeAddr("miner");
    address validator = makeAddr("validator");
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 constant BRAIN_ID = 42;

    function setUp() public {
        based = new MockBASED();
        nft = new MockBrainNFT();
        registry = new SubnetRegistry(nft, based);

        nft.mint(owner, BRAIN_ID);
        based.mint(miner, 1_000 ether);
        based.mint(validator, 1_000 ether);

        vm.prank(miner);
        based.approve(address(registry), type(uint256).max);
        vm.prank(validator);
        based.approve(address(registry), type(uint256).max);
    }

    function test_activate_setsOwnerAndDefaults() public {
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");

        ISubnetRegistry.Subnet memory s = registry.getSubnet(BRAIN_ID);
        assertEq(s.owner, owner);
        assertEq(s.modelHash, bytes32(uint256(0xabc)));
        assertEq(s.registrationFee, registry.DEFAULT_REGISTRATION_FEE());
        assertTrue(s.active);
    }

    function test_activate_revertsForNonOwner() public {
        vm.prank(miner);
        vm.expectRevert(ISubnetRegistry.NotBrainOwner.selector);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");
    }

    function test_register_chargesFee() public {
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");

        uint256 fee = registry.DEFAULT_REGISTRATION_FEE();
        uint256 minerBefore = based.balanceOf(miner);

        vm.prank(miner);
        registry.registerMiner(BRAIN_ID);

        assertEq(based.balanceOf(miner), minerBefore - fee);
        assertEq(based.balanceOf(BURN_ADDRESS), fee);
        assertTrue(registry.isMiner(BRAIN_ID, miner));
    }

    function test_register_revertsOnDuplicate() public {
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");

        vm.startPrank(miner);
        registry.registerMiner(BRAIN_ID);
        vm.expectRevert(ISubnetRegistry.AlreadyRegistered.selector);
        registry.registerMiner(BRAIN_ID);
        vm.stopPrank();
    }

    function test_setEmissionSplit_revertsOnInvalid() public {
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");

        vm.prank(owner);
        vm.expectRevert(ISubnetRegistry.InvalidSplit.selector);
        registry.setEmissionSplit(BRAIN_ID, 10_001, 5_000);
    }

    function test_setEmissionSplit_revertsWhenOwnerExceedsCap() public {
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");

        vm.prank(owner);
        vm.expectRevert(ISubnetRegistry.InvalidSplit.selector);
        // 1501 bps = 15.01%, just above the cap
        registry.setEmissionSplit(BRAIN_ID, 1501, 7609);
    }

    function test_defaultSplits_are_8_70_22() public {
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");

        ISubnetRegistry.Subnet memory s = registry.getSubnet(BRAIN_ID);
        assertEq(s.ownerSplitBps, 800);
        assertEq(s.minerShareBps, 7609);
    }

    function testFuzz_registerMiner_capacity(uint8 n) public {
        n = uint8(bound(n, 1, 10));
        vm.prank(owner);
        registry.activate(BRAIN_ID, bytes32(uint256(0xabc)), "ipfs://model");
        vm.prank(owner);
        registry.setRegistrationFee(BRAIN_ID, 0);

        for (uint256 i = 0; i < n; i++) {
            address m = address(uint160(i + 1000));
            vm.prank(m);
            registry.registerMiner(BRAIN_ID);
        }
        assertEq(registry.minerCount(BRAIN_ID), n);
    }
}
