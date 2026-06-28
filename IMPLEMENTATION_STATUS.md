# Implementation Status

> **This repository is pre-audit and testnet-targeted.** The documentation (whitepaper,
> tokenomics, guides) describes the intended end-state. The v2 fee economy (fee split, delegated
> yield, validator distribution, market pause) and the off-chain transport (gateway/indexer,
> miner discovery, signature aggregator, domain-separated epoch commitments) are now implemented
> and unit-tested. This matrix is the source of truth; where a document and the code disagree,
> **the code (and this matrix) win.** Do not deposit funds, stake, bridge, or run against
> mainnet until the remaining release gates below are met and an independent external audit and
> public testnet have completed.

## On-chain (contracts/src)

| Component | Status | Notes |
|-----------|--------|-------|
| Staking (stake/unstake/cooldown) | Implemented | Share-based; pro-rata slashing; stake checkpoints |
| Slashing | Implemented | Pro-rata across stakers incl. pending; no evasion/brick |
| Spending account + receipt redemption | Implemented | Output-bound, counter-signed receipts; withdrawal delay |
| Subnet registry / membership | Implemented | Fee slippage guard; reentrancy-safe; one-shot activate |
| Scoring commitments + equivocation fraud proof | Implemented | Per-Brain quorum; stake-weighted canonical score aggregation; domain-separated root invalidation |
| Governance (snapshot voting, timelock) | Implemented | Snapshot stake; per-Brain dedup; real quorum/threshold |
| Brain NFT (L1 soulbound + bridge escrow) | Implemented | ID space fixed at 0–63; reserved-id mint path |
| Fee distribution (70/22/8 miner/validator/owner) | Implemented | `ComputeUnitMarket.redeem` splits per Brain bps; owner→owner, validator→`RewardDistributor` |
| Staking rewards / delegated yield | Implemented | `StakingVault.notifyReward` accrues fee income to shares pro-rata (no separate claim needed) |
| Validator fee distribution | Implemented | `RewardDistributor` splits the 22% across a Brain's full active validator set by stake (bounded ≤256) |
| Market pause / circuit breaker | Implemented | `ComputeUnitMarket` is Pausable; `PAUSER_ROLE` (guardian then governance); withdrawals stay open |
| Protocol emissions / EmissionController | **Absent by design** | Whitepaper §5.3: $basedAI is fixed-supply, non-mintable, no treasury — v2 is fee-for-service |
| Score-driven emission payouts | **Absent by design** | No emissions to pay out; scores drive demand routing (client picks high-score miner) + equivocation slashing |

## Off-chain (miner / validator / client)

| Component | Status | Notes |
|-----------|--------|-------|
| Miner inference + receipt batching | Implemented | Eligibility checked before serving; bounded input |
| Miner challenge handling | Implemented | Requires a registered-validator signature |
| Miner HTTP transport + announce | Implemented | Serves `/infer` `/challenge` `/settle`; signed endpoint announce to the gateway |
| Validator scoring algorithm | Implemented | Heuristic; collusion/Sybil hardening still TODO |
| Validator epoch commitment | Implemented | Domain-separated signature (`commitment.py`) now verifies on-chain; submits to aggregator |
| Clients (py/ts) request + settle | Implemented | Two-phase counter-signed receipts; response verified |
| Validator miner discovery | Implemented | Pulls the reachable miner set from the gateway/indexer |
| Signature aggregator | Implemented | `aggregator.py`: verifies sigs, groups by root, submits `proposeEpoch` past quorum |
| HTTP gateway / indexer | Implemented | `gateway/` package: event-sourced membership + signed announces + inference proxy |
| **libp2p transport (gossip + streams)** | **Stub (HTTP is the testnet path)** | Protocol IDs defined; production gossip not wired — HTTP transport supersedes it for testnet |

## Bridge

| Component | Status | Notes |
|-----------|--------|-------|
| L1 escrow into adapter | Implemented | Requires `BrainNFT.setBridge(adapter)` (done in deploy) |
| `IL1NFTBridge` integration | **Placeholder** | Canonical Ink bridge ABI must be finalized + tested |
| L2 mint/burn authority | Implemented | `BRIDGE_ROLE`; grant the canonical messenger via governance |

## Release gates

Done: the economic layer (fee split, delegated yield, validator distribution, pause) and the
off-chain transport (gateway/discovery/aggregator, domain-separated commitments) are built and
unit-tested.

Addressed since the audit notes: the **pre-authorization overcharge** is closed. A pre-auth
carries the deterministic sentinel `responseHash = keccak(promptHash, nonce)`, which the market
recomputes and **caps at `maxReservation`** (governance-tunable). Full payment now requires the
client-counter-signed FINAL receipt, bound to the real, post-delivery `responseHash`. Both clients
sign only a small reservation as the no-delivery fallback. (`ComputeUnitMarket.redeem`,
`EconomicLayer.t.sol` cap tests, client `DEFAULT_RESERVATION`.)

Still required before mainnet — freeze deposits/stake/bridge/mainnet until:
- an **independent external audit** of the full v2 surface (incl. the new `RewardDistributor`,
  the market split, and the reservation-capped receipt path) is complete;
- a **public testnet** has run the end-to-end loop (deposit → infer → redeem-split →
  distribute → yield; challenge → epoch commit → aggregate → propose → finalize);
- **validator scoring** gets collusion/Sybil hardening and a non-public eval set;
- the **canonical Ink `IL1NFTBridge` ABI** is finalized and integration-tested.
