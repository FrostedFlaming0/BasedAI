# BasedAI Contracts (v2)

Foundry project containing all on-chain components.

## Layout

```
src/
  tokens/          BrainNFT (mainnet), BrainNFTL2 (Ink), BrainBridgeAdapter
  subnet/          SubnetRegistry — per-Brain configuration & participants
  staking/         StakingVault — stake to (Brain, validator) with 14-day cooldown
  scoring/         ScoringRegistry — epoch Merkle roots + equivocation fraud proofs
  governance/      BasedGovernor — GigaBrain voting on top of OZ Governor
  market/          ComputeUnitMarket — payment channels for inference
  interfaces/      Shared interfaces
test/              Foundry tests
script/            Deployment scripts
```

## v2 design notes

This implementation does NOT include:

- A `BASED` ERC-20 contract — uses the existing $basedAI at `0x44971ABF0251958492FeE97dA3e5C5adA88B9185` directly via `IERC20`.
- An `EmissionController` — no protocol-level emissions in v2. Network operates on fee-for-service.
- A `Pepecoin` deployment — uses the existing Pepecoin at `0xA9E8aCf069C58aEc8825542845Fd754e41a9489A`.

## Build

```bash
forge install
forge build
forge test
```

## Two-chain deployment

Two contracts live on **Ethereum mainnet**:

- `BrainNFT` — accepts staking of either Pepecoin or $basedAI to mint a Brain. Stake-only (no burn path), 64 Brain cap, IDs 0–6 reserved.
- `BrainBridgeAdapter` — escrow helper for bridging Brain ownership to L2.

The remainder live on **Ink L2** and reference the bridged $basedAI as a standard `IERC20`.

See `script/Deploy.s.sol` (L2), `script/DeployMainnet.s.sol` (L1), and `../docs/deployment.md` for the full sequence.

## Network policy: burns

Two flows burn $basedAI directly to `0x000...dEaD`:

- **Registration fees** (paid by miners and validators when joining a Brain)
- **Slashed stake** (when validators are slashed for equivocation)

These are hardcoded in `SubnetRegistry` and `StakingVault` respectively — not configurable, not redirectable. The constants are named `BURN_ADDRESS`.

## Fee split defaults

`SubnetRegistry.DEFAULT_OWNER_SPLIT_BPS = 800` (8%) and `DEFAULT_MINER_SHARE_BPS = 7609` (which gives miners 70% of total when applied to the 92% node share). Validators receive the remainder, ~22% of total.

`MAX_OWNER_SPLIT_BPS = 1500` caps the Brain owner's share at 15%.
