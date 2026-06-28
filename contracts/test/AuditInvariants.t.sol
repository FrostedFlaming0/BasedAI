// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {SubnetRegistry} from "../src/subnet/SubnetRegistry.sol";
import {ISubnetRegistry} from "../src/interfaces/ISubnetRegistry.sol";
import {RewardDistributor} from "../src/reward/RewardDistributor.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";
import {ComputeUnitMarket} from "../src/market/ComputeUnitMarket.sol";
import {ScoringRegistry} from "../src/scoring/ScoringRegistry.sol";
import {IScoringRegistry} from "../src/interfaces/IScoringRegistry.sol";
import {BrainNFTL2} from "../src/tokens/BrainNFTL2.sol";
import {BasedGovernor} from "../src/governance/BasedGovernor.sol";

contract AuditMockERC20 is ERC20 {
    constructor() ERC20("BASED", "BASED") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Exercises the StakingVault as an adversarial state machine while preserving only the real
/// preconditions a caller can satisfy. The invariant target is solvency, not a mirrored accounting
/// implementation: every reachable sequence must keep on-chain assets consistent with public totals.
contract StakingSolvencyHandler is Test {
    AuditMockERC20 public immutable based;
    StakingVault public immutable vault;
    address public immutable admin;
    address public immutable slasher;
    address public immutable rewarder;

    uint256[] internal _brains;
    address[] internal _validators;
    address[] internal _stakers;

    constructor(AuditMockERC20 based_, StakingVault vault_, address admin_) {
        based = based_;
        vault = vault_;
        admin = admin_;
        slasher = makeAddr("invariant-slasher");
        rewarder = makeAddr("invariant-rewarder");
        _brains.push(0);
        _brains.push(1);
        _validators.push(makeAddr("validator-a"));
        _validators.push(makeAddr("validator-b"));
        _validators.push(makeAddr("validator-c"));
        _stakers.push(makeAddr("staker-a"));
        _stakers.push(makeAddr("staker-b"));
        _stakers.push(makeAddr("staker-c"));
        _stakers.push(makeAddr("staker-d"));

        vm.startPrank(admin);
        vault.grantRole(vault.SLASHER_ROLE(), slasher);
        vault.grantRole(vault.REWARDER_ROLE(), rewarder);
        vm.stopPrank();

        for (uint256 i; i < _stakers.length; i++) {
            based.mint(_stakers[i], 1_000_000 ether);
            vm.prank(_stakers[i]);
            based.approve(address(vault), type(uint256).max);
        }
        based.mint(rewarder, 1_000_000 ether);
        vm.prank(rewarder);
        based.approve(address(vault), type(uint256).max);
    }

    function stake(uint256 brainSeed, uint256 validatorSeed, uint256 stakerSeed, uint256 amount) external {
        uint256 brainId = _brains[brainSeed % _brains.length];
        address validator = _validators[validatorSeed % _validators.length];
        address staker = _stakers[stakerSeed % _stakers.length];
        amount = bound(amount, 1, 10_000 ether);
        vm.prank(staker);
        try vault.stake(brainId, validator, amount) {} catch {}
    }

    function requestUnstake(uint256 brainSeed, uint256 validatorSeed, uint256 stakerSeed, uint256 amount) external {
        uint256 brainId = _brains[brainSeed % _brains.length];
        address validator = _validators[validatorSeed % _validators.length];
        address staker = _stakers[stakerSeed % _stakers.length];
        uint256 balance = vault.stakerBalance(brainId, validator, staker);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(staker);
        try vault.requestUnstake(brainId, validator, amount) {} catch {}
    }

    function claimUnstake(uint256 brainSeed, uint256 validatorSeed, uint256 stakerSeed, uint256 warpSeconds) external {
        uint256 brainId = _brains[brainSeed % _brains.length];
        address validator = _validators[validatorSeed % _validators.length];
        address staker = _stakers[stakerSeed % _stakers.length];
        vm.warp(block.timestamp + bound(warpSeconds, 0, 30 days));
        vm.prank(staker);
        try vault.claimUnstake(brainId, validator) {} catch {}
    }

    function slash(uint256 brainSeed, uint256 validatorSeed, uint256 amount) external {
        uint256 brainId = _brains[brainSeed % _brains.length];
        address validator = _validators[validatorSeed % _validators.length];
        uint256 pool = vault.validatorStake(brainId, validator);
        if (pool == 0) return;
        amount = bound(amount, 1, pool);
        vm.prank(slasher);
        vault.slash(brainId, validator, amount, "INVARIANT");
    }

    function reward(uint256 brainSeed, uint256 validatorSeed, uint256 amount) external {
        uint256 brainId = _brains[brainSeed % _brains.length];
        address validator = _validators[validatorSeed % _validators.length];
        if (vault.validatorStake(brainId, validator) == 0) return;
        amount = bound(amount, 1, 10_000 ether);
        vm.prank(rewarder);
        try vault.notifyReward(brainId, validator, amount) {} catch {}
    }

    function brains() external view returns (uint256[] memory) {
        return _brains;
    }

    function validators() external view returns (address[] memory) {
        return _validators;
    }
}

contract StakingSolvencyInvariantTest is StdInvariant, Test {
    AuditMockERC20 based;
    StakingVault vault;
    StakingSolvencyHandler handler;
    address admin = makeAddr("admin");

    function setUp() public {
        based = new AuditMockERC20();
        vault = new StakingVault(based, admin);
        handler = new StakingSolvencyHandler(based, vault, admin);
        targetContract(address(handler));
    }

    function invariant_vaultTokenBalanceEqualsTotalStaked() public view {
        assertEq(based.balanceOf(address(vault)), vault.totalStaked(), "vault token balance != totalStaked");
    }

    function invariant_brainTotalsSumToTotalStaked() public view {
        assertEq(vault.brainStake(0) + vault.brainStake(1), vault.totalStaked(), "brain totals drifted");
    }

    function invariant_validatorPoolsSumToBrainStake() public view {
        address[] memory validators = handler.validators();
        for (uint256 brainId; brainId < 2; brainId++) {
            uint256 sum;
            for (uint256 i; i < validators.length; i++) {
                sum += vault.validatorStake(brainId, validators[i]);
            }
            assertEq(sum, vault.brainStake(brainId), "validator pool sum drifted");
        }
    }

    function invariant_effectiveStakeNeverExceedsRawOrCap() public view {
        uint256 total = vault.totalStaked();
        uint256 cap = (total * vault.CENTRALIZATION_CAP_BPS()) / 10_000;
        for (uint256 brainId; brainId < 2; brainId++) {
            uint256 effective = vault.effectiveBrainStake(brainId);
            assertLe(effective, vault.brainStake(brainId), "effective > raw");
            assertLe(effective, cap, "effective > cap");
        }
    }
}

contract ReceiptPricingAndFeeFuzzTest is Test {
    AuditMockERC20 based;
    BrainNFTL2 nft;
    SubnetRegistry registry;
    StakingVault staking;
    RewardDistributor dist;
    ComputeUnitMarket market;

    address admin = makeAddr("admin");
    address owner = makeAddr("brain-owner");
    uint256 constant BRAIN = 3;

    function setUp() public {
        based = new AuditMockERC20();
        nft = new BrainNFTL2(address(this), 1, address(0xBEEF));
        nft.safeMint(owner, BRAIN);
        registry = new SubnetRegistry(IERC721(address(nft)), based);
        staking = new StakingVault(based, admin);
        dist = new RewardDistributor(based, ISubnetRegistry(address(registry)), IStakingVault(address(staking)), admin);
        market = new ComputeUnitMarket(
            based, ISubnetRegistry(address(registry)), IRewardDistributor(address(dist)), 1 ether, 7, 101, admin
        );
        vm.startPrank(admin);
        dist.grantRole(dist.MARKET_ROLE(), address(market));
        staking.grantRole(staking.REWARDER_ROLE(), address(dist));
        vm.stopPrank();
        vm.startPrank(owner);
        registry.activate(BRAIN, keccak256("model"), "ipfs://model");
        registry.setRegistrationFee(BRAIN, 0);
        vm.stopPrank();
    }

    function _signedReceipt(uint256 amount, uint256 nonce)
        internal
        returns (address user, uint256 userPk, address miner, ComputeUnitMarket.Receipt memory r, bytes memory sig)
    {
        (user, userPk) = makeAddrAndKey(string(abi.encodePacked("payer", nonce)));
        miner = makeAddr(string(abi.encodePacked("miner", nonce)));
        based.mint(user, amount + 1 ether);
        vm.startPrank(user);
        based.approve(address(market), type(uint256).max);
        market.deposit(amount + 1 ether);
        vm.stopPrank();
        r = ComputeUnitMarket.Receipt({
            user: user,
            miner: miner,
            brainId: BRAIN,
            promptHash: keccak256(abi.encode("prompt", nonce)),
            responseHash: keccak256(abi.encode("response", nonce)),
            amount: amount,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: nonce
        });
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(userPk, market.receiptDigest(r));
        sig = abi.encodePacked(rr, ss, v);
    }

    function testFuzz_quoteMatchesBytePricing(uint128 pricePerByte, uint128 pricePerRequest, uint64 p, uint64 r)
        public
    {
        vm.assume(pricePerByte > 0 || pricePerRequest > 0);
        vm.prank(admin);
        market.setPricing(pricePerByte, pricePerRequest);
        uint256 expected = uint256(pricePerRequest) + uint256(pricePerByte) * (uint256(p) + uint256(r));
        assertEq(market.quote(p, r), expected);
    }

    function testFuzz_redeemConservesFees(uint96 rawAmount, uint16 ownerSplit, uint16 minerShare) public {
        uint256 amount = bound(rawAmount, 1, 1_000_000 ether);
        ownerSplit = uint16(bound(ownerSplit, 0, registry.MAX_OWNER_SPLIT_BPS()));
        minerShare = uint16(bound(minerShare, 0, 10_000));
        vm.prank(owner);
        registry.setEmissionSplit(BRAIN, ownerSplit, minerShare);

        (,, address miner, ComputeUnitMarket.Receipt memory r, bytes memory sig) = _signedReceipt(amount, rawAmount);
        uint256 ownerBefore = based.balanceOf(owner);
        uint256 minerBefore = based.balanceOf(miner);
        uint256 distBefore = based.balanceOf(address(dist));
        vm.prank(miner);
        market.redeem(r, sig);

        uint256 ownerDelta = based.balanceOf(owner) - ownerBefore;
        uint256 minerDelta = based.balanceOf(miner) - minerBefore;
        uint256 distDelta = based.balanceOf(address(dist)) - distBefore;
        assertEq(ownerDelta + minerDelta + distDelta, amount, "fee split lost value");
        assertEq(dist.pendingValidatorFees(BRAIN), distDelta, "pending fee mismatch");
        assertEq(market.balances(r.user), 1 ether, "user debited exact redeemed amount");
    }

    function testFuzz_receiptDomainAndNonceAreEnforced(uint96 rawAmount, uint256 nonce) public {
        uint256 amount = bound(rawAmount, 1, 100 ether);
        nonce = bound(nonce, 1, type(uint64).max);
        (,, address miner, ComputeUnitMarket.Receipt memory r, bytes memory sig) = _signedReceipt(amount, nonce);

        ComputeUnitMarket.Receipt memory mutated = r;
        mutated.amount = amount + 1;
        vm.prank(miner);
        vm.expectRevert(ComputeUnitMarket.InvalidSignature.selector);
        market.redeem(mutated, sig);

        r.amount = amount;
        vm.prank(miner);
        market.redeem(r, sig);

        vm.prank(miner);
        vm.expectRevert(ComputeUnitMarket.NonceUsed.selector);
        market.redeem(r, sig);
    }
}

contract EpochLifecycleFuzzTest is Test {
    AuditMockERC20 based;
    StakingVault staking;
    ScoringRegistry scoring;
    address admin = makeAddr("admin");

    function setUp() public {
        based = new AuditMockERC20();
        staking = new StakingVault(based, admin);
        scoring = new ScoringRegistry(staking, uint64(block.timestamp));
        bytes32 slasherRole = staking.SLASHER_ROLE();
        vm.prank(admin);
        staking.grantRole(slasherRole, address(scoring));
    }

    function _stake(uint256 brainId, address validator, uint256 amount) internal {
        address staker = makeAddr(string(abi.encodePacked("staker", validator, brainId)));
        based.mint(staker, amount);
        vm.startPrank(staker);
        based.approve(address(staking), amount);
        staking.stake(brainId, validator, amount);
        vm.stopPrank();
    }

    function _sign(uint256 pk, uint64 epoch, uint256 brainId, bytes32 root) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, scoring.commitmentDigest(epoch, brainId, root));
        return abi.encodePacked(r, s, v);
    }

    function testFuzz_epochCannotBeBothFinalizedAndInvalidated(uint8 brainSeed, bytes32 rootA, bytes32 rootB) public {
        vm.assume(rootA != bytes32(0));
        vm.assume(rootB != bytes32(0));
        vm.assume(rootA != rootB);
        uint256 brainId = uint256(brainSeed) % 4;
        (address validator, uint256 pk) = makeAddrAndKey("epoch-validator");
        _stake(brainId, validator, 100 ether);
        vm.warp(block.timestamp + scoring.EPOCH_LENGTH());
        uint64 epoch = 0;

        address[] memory signers = new address[](1);
        signers[0] = validator;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(pk, epoch, brainId, rootA);
        scoring.proposeEpoch(epoch, brainId, rootA, signers, sigs);

        scoring.challengeEquivocation(
            epoch, brainId, rootA, _sign(pk, epoch, brainId, rootA), rootB, _sign(pk, epoch, brainId, rootB), validator
        );
        assertTrue(scoring.getEpoch(epoch, brainId).invalidated, "not invalidated");

        vm.warp(block.timestamp + scoring.CHALLENGE_WINDOW());
        vm.expectRevert(IScoringRegistry.EpochAlreadyInvalidated.selector);
        scoring.finalizeEpoch(epoch, brainId);
        assertEq(scoring.getEpoch(epoch, brainId).finalizedAt, 0, "invalidated root finalized");
        assertFalse(
            scoring.verifyScore(epoch, brainId, makeAddr("miner"), 1, new bytes32[](0)), "invalid root verified"
        );
    }

    function testFuzz_challengeWindowAnchoredToProposal(uint32 lateBy) public {
        (address validator, uint256 pk) = makeAddrAndKey("late-validator");
        _stake(0, validator, 100 ether);
        uint256 delay = bound(uint256(lateBy), scoring.EPOCH_LENGTH(), 30 days);
        vm.warp(block.timestamp + delay);
        bytes32 root = keccak256("late-root");
        address[] memory signers = new address[](1);
        signers[0] = validator;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(pk, 0, 0, root);
        scoring.proposeEpoch(0, 0, root, signers, sigs);

        vm.expectRevert(IScoringRegistry.ChallengeWindowOpen.selector);
        scoring.finalizeEpoch(0, 0);
        vm.warp(block.timestamp + scoring.CHALLENGE_WINDOW());
        scoring.finalizeEpoch(0, 0);
        assertGt(scoring.getEpoch(0, 0).finalizedAt, 0);
    }
}

contract RoleReachabilityTest is Test {
    AuditMockERC20 based;
    BrainNFTL2 nft;
    SubnetRegistry registry;
    StakingVault staking;
    RewardDistributor dist;
    ComputeUnitMarket market;
    ScoringRegistry scoring;
    TimelockController timelock;
    BasedGovernor governor;

    address deployer = makeAddr("deployer");
    address guardian = makeAddr("guardian");
    address bridge = makeAddr("bridge");
    address l1Brain = makeAddr("l1-brain");

    function setUp() public {
        based = new AuditMockERC20();
        nft = new BrainNFTL2(bridge, 1, l1Brain);
        registry = new SubnetRegistry(IERC721(address(nft)), based);
        staking = new StakingVault(based, deployer);
        scoring = new ScoringRegistry(staking, uint64(block.timestamp));
        dist =
            new RewardDistributor(based, ISubnetRegistry(address(registry)), IStakingVault(address(staking)), deployer);
        market = new ComputeUnitMarket(
            based, ISubnetRegistry(address(registry)), IRewardDistributor(address(dist)), 1 ether, 1, 1, deployer
        );
        address[] memory none = new address[](0);
        timelock = new TimelockController(1 days, none, none, deployer);
        governor = new BasedGovernor(IERC721Enumerable(address(nft)), staking, timelock, 64, 1);

        vm.startPrank(deployer);
        staking.grantRole(staking.SLASHER_ROLE(), address(scoring));
        staking.grantRole(staking.REWARDER_ROLE(), address(dist));
        dist.grantRole(dist.MARKET_ROLE(), address(market));
        market.grantRole(market.PAUSER_ROLE(), address(timelock));
        market.grantRole(market.PAUSER_ROLE(), guardian);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), address(timelock));
        staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), deployer);
        market.grantRole(market.DEFAULT_ADMIN_ROLE(), address(timelock));
        market.renounceRole(market.DEFAULT_ADMIN_ROLE(), deployer);
        dist.grantRole(dist.DEFAULT_ADMIN_ROLE(), address(timelock));
        dist.renounceRole(dist.DEFAULT_ADMIN_ROLE(), deployer);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();
    }

    function test_deployerPrivilegeRemoved_butTimelockAndGuardianReachable() public {
        assertFalse(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(market.hasRole(market.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(dist.hasRole(dist.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));

        vm.prank(deployer);
        vm.expectRevert();
        market.setPricing(2, 2);

        vm.prank(guardian);
        market.pause();
        assertTrue(market.paused());
        vm.prank(guardian);
        market.unpause();

        bytes memory data = abi.encodeCall(ComputeUnitMarket.setPricing, (11, 13));
        bytes32 salt = keccak256("set-pricing");
        vm.prank(address(governor));
        timelock.schedule(address(market), 0, data, bytes32(0), salt, 1 days);
        vm.warp(block.timestamp + 1 days);
        timelock.execute(address(market), 0, data, bytes32(0), salt);
        assertEq(market.pricePerByte(), 11);
        assertEq(market.pricePerRequest(), 13);
    }

    function test_roleOnlyFunctionsRemainNarrow() public {
        vm.expectRevert();
        staking.slash(0, makeAddr("v"), 1, "NOPE");
        vm.expectRevert();
        staking.notifyReward(0, makeAddr("v"), 1);
        vm.expectRevert();
        dist.recordFees(0, 1);
        vm.expectRevert();
        market.pause();
    }
}
