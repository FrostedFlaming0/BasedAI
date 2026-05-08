# Architecture

BasedAI v2 is a decentralized LLM inference marketplace deployed on Ink (Kraken's L2). It is built on top of the existing $basedAI and Pepecoin contracts on Ethereum mainnet; this implementation does not introduce new tokens.

For the full design rationale, see [`../whitepaper-v2.md`](../whitepaper-v2.md). This document describes the technical structure of the implementation.

## Layers

The system has four layers:

1. **On-chain (Ink L2):** ownership, staking, payments, scoring settlement, governance.
2. **Off-chain coordination (libp2p):** miner/validator discovery, request/response routing.
3. **Compute (miner GPUs):** the actual LLM inference.
4. **Verification (validators):** statistical spot-checking, score posting.

## Component map

```
Ethereum mainnet:
  $basedAI (existing, 0x44971ABF...)  ──┐
  Pepecoin (existing, 0xA9E8aCf0...)  ──┤── stake to mint ──▶ BrainNFT ──bridge──▶ BrainNFTL2
                                        │
                                        └── bridge ────▶ $basedAI on Ink L2

Ink L2:
  BrainNFTL2 ◀──reads ownership──┐
                                 │
  SubnetRegistry  ───────────────┤
  StakingVault   ───────────────┤
  ScoringRegistry ──────────────┤
  ComputeUnitMarket ────────────┤
  BasedGovernor ────────────────┘

Off-chain:
  miner ◀─libp2p─▶ validator ◀─libp2p─▶ user-client
                                            │
                                            ▼
                                       HTTP gateway (browser fallback)
```

## Contract responsibilities

**No `BASED` contract is deployed.** The existing `$basedAI` token at `0x44971ABF0251958492FeE97dA3e5C5adA88B9185` is bridged to Ink via the canonical OP Stack bridge. All on-chain references use the bridged representation as a standard `IERC20`.

**`BrainNFT`** (Ethereum mainnet ERC-721) — issued by staking either 100,000 Pepecoin or 10,000 $basedAI for 90 days. Capped at 64 tokens. IDs 0–6 reserved for administrative use; public IDs start at 7. Stake-minted Brains are non-transferable and recover their stake on deactivation. Stake amounts adjustable by governance within ±50%/+200% bounds.

**`BrainNFTL2`** (Ink L2 ERC-721) — bridge representation. All L2 contracts read Brain ownership from this contract.

**`SubnetRegistry`** — per-Brain configuration (model, fees, splits) and miner/validator membership. Hard caps: 256 validators and 1,792 miners per Brain. Registration fees (default 100 $basedAI) are burned to a dead address.

**`StakingVault`** — $basedAI staking to (Brain, validator) tuples. 14-day cooldown on unstake, slashing hook callable only by `ScoringRegistry`. Slashed stake is burned. Effective stake for emission weighting is capped at 0.5% of total per-Brain.

**`ScoringRegistry`** — receives per-epoch Merkle commitments from validators. Validates signatures, enforces a >50% stake quorum, opens a 1-hour challenge window, and accepts equivocation fraud proofs that trigger validator slashing.

**`ComputeUnitMarket`** — payment channels for inference. Users deposit $basedAI into spending accounts; miners batch-redeem signed receipts. Receipts include nonces and expiries to prevent double-spend and stale claims. **No protocol take in v1** — 100% of inference fees flow to network operators per the 70/22/8 split managed by the validator scoring system.

**`BasedGovernor`** — GigaBrain voting. A Brain that crosses 0.5% of network stake gets one vote, exercised by its current owner. Standard OZ Governor + Timelock with 48-hour minimum delay.

## Off-chain flow: inference

1. User deposits $basedAI into `ComputeUnitMarket`.
2. User reads `SubnetRegistry` to find the model on a target Brain, queries the gateway for a miner list.
3. User signs an upper-bound receipt (max budget, expiry, fresh nonce) and sends it with the prompt to the miner over libp2p.
4. Miner runs inference, returns response + signed receipt.
5. Miner periodically batches receipts and redeems them on-chain via `ComputeUnitMarket.redeem`.

## Off-chain flow: scoring

1. Validators run challenge prompts against miners on their Brain (deterministic prompts, temperature=0).
2. At each 1-hour epoch boundary, validators score miners on (latency, quality, consistency) — see `validator/src/basedai_validator/scoring.py`.
3. Validators co-sign a Merkle root over `(brainId, miner, score)` leaves.
4. An aggregator submits the root + signatures to `ScoringRegistry.proposeEpoch`.
5. After a 1-hour challenge window, the epoch finalizes and miner scores become canonical for fee distribution.

## Trust assumptions

This system **does not** prove inference correctness cryptographically. The trust model is:

- Inference happens on miner GPUs in plaintext. Miners can see and log prompts.
- Validators detect bad miners statistically: deterministic challenge agreement with the network mode, eval-set quality, latency outliers.
- Misbehavior is punished economically through validator slashing on equivocation and through low scores reducing fee earnings.

This is the same trust model as Bittensor, Akash, Render, and every other production decentralized inference network. The original 2024 whitepaper claimed cryptographic privacy via FHE and proof-of-correct-inference via "ZK-LLMs"; those claims are not implemented here because they are not currently feasible at production performance levels.

## Threat model

| Threat | Mitigation |
|---|---|
| Bridge exploit | Use Ink's canonical OP Stack bridge (operated by the Ink Foundation and Optimism), not third-party bridges |
| Validator collusion | 0.5% per-Brain stake cap, 5% per-validator cap, equivocation fraud proofs, periodic external audits |
| Sybil miners | Per-Brain registration fee (burned), 1,792 miner cap per Brain |
| Stake-then-attack | 14-day unstaking cooldown |
| MEV on epoch boundaries | Commit-reveal for epoch root proposals (planned post-v1) |
| Smart contract bugs | OpenZeppelin where possible; custom code (`ScoringRegistry`, `SubnetRegistry`, `StakingVault`) gets a third-party audit before mainnet |

## Why Ink

Ink is Kraken's OP Stack L2, part of the Optimism Superchain. The L2 model trades sequencer-level sovereignty for time-to-ship and EVM composability — appropriate for a project that needs to validate product-market fit before optimizing for sovereignty. Specific technical fit:

- **Sub-cent transaction fees with ~1-second blocks.** The network's fundamental product is "cheap, frequent, low-margin transactions" (inference receipts, scoring posts, registration), and Ink's gas economics support this directly.
- **OP Stack maturity.** Standard tooling — Foundry, Hardhat, OpenZeppelin v5, Etherscan-equivalent explorers — works without modification. The deployment story is the same as any other Superchain L2.
- **Superchain interop.** Optimism's planned Interop Layer (early 2026) will allow contracts on Ink, Base, World Chain, and other Superchain L2s to call each other natively. Choosing Ink today does not preclude future cross-chain functionality with the broader OP Stack ecosystem.
- **ETH as gas token.** No proprietary gas token required; users only need ETH on Ink to pay fees.
- **Permissionless fault proofs.** Ink launched with multiple challengers (Kraken and Gelato), making it the first Superchain network with this property at launch.

If the network outgrows L2 constraints, migrating to a sovereign chain is a v2 decision informed by real usage data, not a v1 commitment.
