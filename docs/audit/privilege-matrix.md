# Privilege Matrix

| Actor / contract | Privileges | Cannot do | Handoff / control |
|---|---|---|---|
| Deployer | Temporarily deploy and wire contracts | Retain protocol admin after successful scripts | Renounces bootstrap admin roles in deploy scripts |
| L1 governance multisig | `BrainNFT` `DEFAULT_ADMIN_ROLE` and `GOVERNANCE_ROLE` | Move non-bridge Brains, mint public IDs outside contract rules | Recommended multisig; can later be transferred |
| `BrainNFT` bridge endpoints | Transfer otherwise-soulbound Brains into/out of escrow | Mint arbitrary public Brains or change stake records | L1 canonical bridge set via `setBridge`; optional adapter via `setBridgeEndpoint` |
| L2 canonical bridge | Mint/burn `BrainNFTL2` | Change remote token, transfer L2 Brains peer-to-peer | Immutable constructor authority |
| `BasedGovernor` | Propose governance actions through timelock | Execute without timelock delay/quorum | Timelock proposer/canceller |
| `TimelockController` | Admin for market, staking, reward distributor | Bypass configured delay | Open executor; governor proposer/canceller |
| Guardian | Pause/unpause market; optionally cancel timelock proposals | Move funds, change pricing, slash, mint, finalize scores | Optional bootstrap multisig; remove by governance when no longer needed |
| `ScoringRegistry` | Slash equivocating validators via `StakingVault.SLASHER_ROLE` | Transfer stake to itself; slash without valid equivocation path | Role granted by L2 deploy script |
| `RewardDistributor` | Accrue validator fee share as staking yield via `REWARDER_ROLE` | Record fees unless called by market; distribute to omitted validators | Admin is timelock |
| `ComputeUnitMarket` | Debit user balances on valid receipt; route fee split | Withdraw user funds without signature; redeem after expiry; redeem duplicate nonce | Admin is timelock; pauser is timelock/guardian |
| Brain owner | Activate/configure subnet, fees, model metadata | Exceed owner split cap; register others without fees | L2 Brain ownership from bridge |
| Miner | Redeem user-signed receipts; announce endpoint | Change receipt identity/amount without user signature | Must be registered in subnet |
| Validator | Submit score candidates and commitments; challenge miners | Commit current epoch; satisfy quorum without Brain-local stake | Must be registered/staked |
| Gateway | Proxy to announced miners and publish verified scores | Authorize miners not registered on-chain; trust unverified scores | Operational service, no contract privilege |
| Aggregator | Submit `proposeEpoch` when quorum signatures exist | Forge validator signatures; bypass on-chain quorum | Operational service, no privileged role required |
