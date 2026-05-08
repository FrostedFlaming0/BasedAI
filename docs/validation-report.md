# Validation Report (v2)

This document records what static checks have been run against the v2 repository
in lieu of a full compile + test cycle. **It is not a substitute for running
`forge build` and `forge test` in a real Foundry environment** — it catches a
useful subset of issues but cannot verify type correctness, override matching,
storage layout, or runtime semantics.

## Environment

The contracts target Solidity 0.8.24 with OpenZeppelin Contracts v5. They have
not been compiled in this checkout because Foundry was unavailable in the
authoring environment; the static checks below were run against the source as-is.

## v2 changes from v1 scaffold

This implementation incorporates the following design changes from the original
scaffold:

- **No new tokens.** The `BASED.sol` contract was deleted; the existing
  `$basedAI` at `0x44971ABF...` is used directly via `IERC20`.
- **No emissions.** The `EmissionController` and its interface were deleted.
  The network operates on fee-for-service economics only.
- **Stake-only Brain minting.** `BrainNFT.sol` was rewritten with no burn-mint
  path. Two stake methods (Pepecoin or $basedAI) share a unified 64-Brain cap
  with reserved IDs 0–6.
- **Updated fee splits.** `SubnetRegistry` defaults changed from 25%/75% to
  8%/92% for owner/nodes, with miners getting 76% of nodes (= 70% of total).
  Maximum owner share capped at 15%.
- **Burn destinations.** Registration fees and slashed stake go directly to
  `0x000...dEaD` (network policy), not to a configurable sink.
- **14-day unstake cooldown** (was 7 days).
- **64-Brain cap** (was 1024).

## Checks performed

### 1. Solidity structural validation

Every `.sol` file (13 in `src/`, 3 in `test/`, 2 in `script/`) parses with:

- balanced braces, parens, and brackets (string- and comment-aware)
- imports that resolve to either local files in this repo or to packages in the
  `@openzeppelin/contracts/` and `forge-std/` namespaces
- a single uniform `pragma solidity ^0.8.24` across all files

Tool: `scripts/check_solidity.py` (offline, stdlib-only).

### 2. Interface-implementation consistency

Every contract that declares `is I<name>` was checked to verify that all
function names declared in the interface appear as functions in the contract.
This check has known false positives for `public` constants and `public`
mappings (which Solidity auto-generates getters for); those were inspected
manually and confirmed correct.

Tool: `scripts/check_overrides.py`.

### 3. BrainNFT v2 logic

The new `_allocateBrainId` uses a dedicated `nextPublicId` counter starting at
`FIRST_PUBLIC_ID = 7`. There is no skip logic for ID 47 (which was a v1
placeholder for an admin Brain that no longer exists in v2). The counter
advances cleanly through IDs 7..63 (capped at 64 total with IDs 0–6 reserved).

Reserved IDs 0–6 must be pre-minted to the operator multisig at deployment.
The contract does not enforce this; it's an operational requirement.

### 4. Constructor signature changes verified

The following constructor signatures changed in v2; tests and deploy scripts
were updated to match:

- `SubnetRegistry(IERC721 brainNFT, IERC20 based)` — removed `feeSink` param
- `StakingVault(IERC20 based, address admin)` — removed `slashSink` param
- `BrainNFT(IERC20 pepecoin, IERC20 basedAI, uint256 pepeStake, uint256 basedStake, address governance)` — full rewrite

### 5. Python source validation

All Python source files (miner, validator, both clients, scripts) parse with
`python3 -m py_compile`. No syntax errors.

### 6. Validator scoring algorithm — executed

The scoring algorithm in `validator/src/basedai_validator/scoring.py` was
executed against four test cases (empty, consistency, quality, fixed-point
range). All passed. Algorithm unchanged from v1.

### 7. Merkle algorithm — executed

The sorted-pair Merkle construction was verified against an independent
stdlib-only reimplementation. Algorithm unchanged from v1.

### 8. TypeScript files

All five `.ts` files in `client/typescript/src/` have balanced braces, parens,
and brackets. They have not been typechecked offline.

## What was NOT validated

The following will only surface when the contracts actually compile:

- **Type errors** (e.g., passing a `uint256` where a `uint64` is expected)
- **Override modifier mismatches** (which parents need to be listed in
  `override(...)`)
- **Storage layout issues** (collisions, gaps, packing inefficiencies)
- **Constructor argument count and order** at deploy time
- **OZ v5 minor-version API changes** beyond the spot-checks
- **`viaIR: true`** behavior — the contracts are configured to compile via the
  Yul IR, which sometimes catches issues that the legacy pipeline allows

The Python miner and validator runtimes have not been run against a live chain
or libp2p network.

## Recommended first step on a workstation with Foundry

```bash
cd contracts
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
forge install foundry-rs/forge-std --no-commit
forge build
forge test -vvv
```

Expect to fix 5–15 small issues that the static checker missed. Most will be
override modifier lists or import paths.
