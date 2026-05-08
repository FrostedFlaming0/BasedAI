# Tokenomics

BasedAI v2 has no protocol-level emissions. The network operates on existing community tokens with fee-for-service economics. This document describes the economic mechanics in detail.

For the design rationale, see [`../whitepaper-v2.md`](../whitepaper-v2.md).

## Tokens

The network uses two existing tokens. **No new tokens are issued.**

### $basedAI

The operational currency of the network.

- **Address:** `0x44971ABF0251958492FeE97dA3e5C5adA88B9185` (Ethereum mainnet)
- **Supply:** 35,769,420 (fixed; ~100k burned via the contract's `burn()` function as of Q2 2026)
- **Mint capability:** None. Ownership renounced; no minter role exists.
- **Bridged to Ink** via the canonical OP Stack bridge for use within the network.

### Pepecoin

The alternative Brain-acquisition asset and community governance signaling token.

- **Address:** `0xA9E8aCf069C58aEc8825542845Fd754e41a9489A` (Ethereum mainnet)
- **Role:** Brain stake-mint (alternative to $basedAI), Snapshot governance weight

## Brain acquisition

Brains are acquired by **staking** either Pepecoin or $basedAI for 90 days. There is no burn-mint path; all Brain creation uses recoverable stake.

| Method | Initial stake | Lock | Recoverability |
|---|---|---|---|
| Pepecoin stake | 100,000 PEPE | 90 days | Refundable on Brain deactivation |
| $basedAI stake | 10,000 basedAI | 90 days | Refundable on Brain deactivation |

The two stake amounts are calibrated quarterly by governance to maintain rough parity in USD terms. Adjustments are bounded to ±50%/+200% of the previous value to prevent griefing.

Both stake methods share the **64-Brain cap**. IDs 0–6 are reserved for administrative use; public minting allocates IDs starting at 7.

Stake-minted Brains are non-transferable in v1. Deactivation returns the original stake and burns the NFT.

## Fee flows

Three sources of fees flow through the network:

### Registration fees

Miners and validators pay a one-time fee in $basedAI to register on a Brain. Default 100 $basedAI, configurable by the Brain owner.

**100% of registration fees are burned** by sending to a dead address (`0x000...dEaD`). This creates direct deflationary pressure on $basedAI supply proportional to network growth.

### Inference fees

Users pay miners directly for inference. The miner sets the price; the user pays via signed receipts that are batch-redeemed on-chain through the `ComputeUnitMarket` contract.

**The protocol takes 0% of inference fees in v1.** All payments flow to network operators per the split below.

### Slashed stake

When a validator is slashed for equivocation (signing two contradictory Merkle roots in the same epoch), their stake is reduced. **100% of slashed stake is burned.**

## Inference fee split

When a miner redeems inference receipts, the payment is split:

| Recipient | Default share | Notes |
|---|---|---|
| Miner who served the request | **70%** | Direct to the serving miner |
| Validators on the Brain | **22%** | Split by stake among active validators |
| Brain owner | **8%** | Configurable downward to 0%; capped at 15% upward |

The 8% default reflects that Brain owners do less ongoing work than miners (who run GPUs continuously) or validators (who score continuously). It is intentionally lower than the 25% in the original whitepaper, which assumed emission subsidies that no longer exist.

The Brain owner's share is configurable per-Brain. Owners can reduce their share to 0% to attract miners; they cannot raise it above 15% without governance approval.

## Centralization caps

Two caps prevent concentration of network economic share:

- **Per-Brain cap:** A Brain's effective stake for fee weighting is capped at 0.5% of network-wide stake. Stake beyond this cap continues to earn for individual stakers (through their validator) but does not increase the Brain's share of network-wide activity. Adjustable by governance within hard bounds (0.1% min, 5% max).
- **Per-validator cap:** A single validator's effective stake is capped at 5% of network-wide stake across all Brains. Adjustable within bounds (1% min, 25% max).

Both caps apply only to weighting calculations, not to the actual stake amount a participant can hold.

## Why no emissions

The original 2024 whitepaper proposed a halving emission schedule starting at 10 $basedAI per 10-second block, totaling roughly 31.5M $basedAI in year one. This was designed to bootstrap miner participation before organic demand emerged.

This implementation does not include emissions because:

1. **The existing $basedAI contract cannot mint.** Its ownership is renounced; no minter role exists; supply is mathematically fixed at ~35.67M.
2. **Issuing a separate rewards token without backing would collapse to zero.** A floating "rewards token" with no convertibility to $basedAI is a synthetic emission that miners would dump immediately.
3. **The project has no treasury allocation in $basedAI.** Without backing reserves, no honest emission mechanism is available.

Instead of papering over this with emission gimmicks, the design accepts the constraint. The network must work on fee-for-service economics from day one, or it does not work.

## Bootstrap considerations

A fee-only network has a bootstrap problem: miners need users to earn, users need miners to use the network, and neither shows up first. This implementation addresses bootstrapping outside of protocol economics:

- **Reference Brains** (operated by the bootstrap operator) provide free or subsidized inference at launch to attract initial users.
- **Volunteer miners** from the existing BasedAI and Pepecoin communities operate hardware during the bootstrap phase, motivated by community participation rather than fee income.
- **Strategic partners** may fund miner subsidies as direct off-protocol grants. These are not emissions; they are funded operational programs that exist outside the contract economy.

The expectation is a 12–18 month period of low-volume operation before the network reaches self-sustaining fee flows. This is a known dynamic in decentralized infrastructure networks and is not unique to BasedAI.

## Governance economics

GigaBrain status: any Brain whose total stake reaches 0.5% of network stake gets one binding on-chain governance vote. Vote count is binary per Brain (additional stake beyond the threshold doesn't grant additional votes), so a single entity needs to acquire many Brains and concentrate stake on each to dominate governance.

In addition, Pepecoin holders and $basedAI holders can participate in advisory Snapshot.org polls weighted by their token holdings. These polls are non-binding but inform GigaBrain voting.

Governance can:

- Adjust the centralization caps within hard bounds
- Modify default fee splits within hard bounds
- Adjust quarterly stake amounts for Brain minting (within ±50%/+200%)
- Promote new contract versions (subject to a 48-hour timelock)
- Allocate the operational treasury (bug bounty payouts, audit funding)

Governance cannot (without admin role transfer, which is itself governance-gated after bootstrap):

- Mint $basedAI (the existing contract has no minter role)
- Modify the supply schedule of $basedAI (it's fixed)
- Seize Brain NFTs
- Override scoring results

## Demand sinks for $basedAI

Network growth creates demand for $basedAI through:

1. **Brain minting** — one of two acquisition methods (alternative to Pepecoin)
2. **Registration fees** — every miner and validator joining a Brain pays in $basedAI (and the fee is burned)
3. **Inference payments** — users pay in $basedAI for compute
4. **Staking** — stakers lock $basedAI to validators to earn fee share

Each of these creates real economic demand without requiring new issuance. As the network grows, the demand for $basedAI grows; as registration fees and slashed stake are burned, supply slowly deflates.

## What participants should expect

This is not a yield product. A BasedAI participant should expect:

- **Brain owners:** ~8% of fees flowing to your Brain. Returns depend entirely on how much real inference traffic the Brain attracts. With low traffic, returns are negligible. With high traffic, returns can be meaningful but never reach the 30,000–80,000 BASED/year figures projected in the original whitepaper (which assumed emission subsidies).
- **Miners:** ~70% of fees. GPU operating costs must be covered by inference demand. During bootstrap, expect to operate at a loss or for community reasons.
- **Validators:** ~22% of fees. Lower-cost than mining (CPU-bound) but also lower fee share. Stake required to be in the active validator set.
- **Stakers:** Earn from validator fee income. No yield until the network has real fee flow.

Anyone evaluating participation should read the [Honest Limitations section](../whitepaper-v2.md#11-honest-limitations) of the whitepaper before staking real capital.
