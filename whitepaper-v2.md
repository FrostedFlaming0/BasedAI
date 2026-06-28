    # BasedAI: A Decentralized LLM Inference Marketplace on Ink

**Version 2.0 — May 2026**

## Abstract

BasedAI is a decentralized marketplace for large language model inference, deployed as a set of Solidity contracts on Ink (Kraken's Layer 2). The network coordinates three roles — Brain owners, miners, and validators — through NFT-gated subnets ("Brains"), a stake-weighted scoring system, and direct fee-for-service payments in $basedAI. This document describes the system's design, economics, and operational mechanics.

This is a substantial revision of the original BasedAI whitepaper (February 2024). It reflects what was learned during the BasedAI Testnet (commenced May 2023, operated by Big Brain Pepe) and corrects design decisions that did not survive technical scrutiny. Specifically:

- The original whitepaper described "Zero-Knowledge LLMs" using Fully Homomorphic Encryption with a novel quantization technique called "Cerberus Squeezing." This implementation does not include those features. FHE-based inference is not currently viable at production performance levels for transformer models, and the cryptographic privacy claims could not be substantiated.
- The original described a sovereign Layer 1 chain. This implementation deploys to Ink instead, trading some sovereignty for faster shipping, lower cost, and EVM composability.
- The original described emission-based economics with a halving schedule. This implementation has no protocol-level emissions because the existing $basedAI contract (0x44971ABF0251958492FeE97dA3e5C5adA88B9185) has fixed supply and renounced ownership.

What remains is a focused, honest design: a working marketplace built on technology that exists today, anchored to the existing $basedAI token, and accessible through both the existing Pepecoin and BasedAI communities.

---

## 1. Introduction

The decentralized AI infrastructure space has matured significantly since 2023. Networks like Bittensor, Akash, and Render have demonstrated that distributed compute marketplaces can sustain real economic activity. The lessons from those networks — and from BasedAI's own testnet — inform this design.

The thesis is simple: many LLM inference workloads do not require the hyperscale datacenter economics of OpenAI or Anthropic. They require capable models, predictable latency, and verifiable behavior. A network of independent operators running open-source models can serve these workloads at a fraction of incumbent prices, with the additional property that no single party controls the inference path.

BasedAI is the implementation of that thesis on Ink, with one important distinction: it does not introduce new tokens or speculative economic mechanisms. The existing $basedAI token at `0x44971ABF0251958492FeE97dA3e5C5adA88B9185` is the network's currency. The existing Pepecoin community gates participation in subnet ownership. Network activity creates demand for both tokens through real fee flows; nothing in this design creates synthetic emission pressure or extractive value capture for a team.

This is a deliberately constrained design. The original whitepaper proposed mechanisms that, in retrospect, depended on assumptions that did not hold: cryptographic guarantees that were not feasible, emission curves that required a new token and treasury that did not exist, governance structures that assumed concentration patterns that may never emerge. By accepting these constraints rather than papering over them, what remains is a system that can actually be built, audited, and shipped.

---

## 2. System Overview

The network has four layers.

**On-chain (Ink L2).** Solidity contracts handle subnet ownership, staking, registration, scoring settlement, payment receipts, and governance. The $basedAI token at the existing mainnet contract is bridged to Ink via the canonical OP Stack bridge.

**Off-chain coordination (libp2p).** Miners and validators discover each other and route inference requests via libp2p gossip and direct streams. A lightweight HTTP gateway provides browser-compatible access to the network.

**Compute layer.** Miners run LLM inference on their own GPUs, serving requests routed to them by users or validators. Inference happens in plaintext; there are no cryptographic privacy claims.

**Verification layer.** Validators issue challenge prompts, score miner output, and co-sign Merkle commitments to per-epoch scores. A 14-day staking cooldown and equivocation-based slashing make misbehavior economically punished.

```
                      ┌─────────────────────────────┐
                      │      BasedAI on Ink L2      │
                      │                             │
                      │  Subnet Registry            │
                      │  Staking Vault              │
                      │  Scoring Registry           │
                      │  Compute Unit Market        │
                      │  Brain NFT (L2 rep)         │
                      └──────────────┬──────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
       ┌──────▼──────┐        ┌──────▼──────┐        ┌──────▼──────┐
       │   Brain #7  │        │   Brain #N  │   ...  │  Brain #63  │
       │             │        │             │        │             │
       │ Validators  │        │ Validators  │        │ Validators  │
       │ Miners      │        │ Miners      │        │ Miners      │
       └─────────────┘        └─────────────┘        └─────────────┘
                                     │
                      ┌──────────────▼──────────────┐
                      │     Ethereum mainnet        │
                      │                             │
                      │  $basedAI (existing)        │
                      │  Pepecoin (existing)        │
                      │  Brain NFT (issuance)       │
                      └─────────────────────────────┘
```

---

## 3. Brains

A Brain is a subnet — a configuration that specifies which model is being served, who can participate, and how rewards are distributed.

### 3.1 Brain ownership

A Brain is represented as an ERC-721 NFT. The supply is capped at 64 Brains, of which 7 are reserved for administrative purposes (Brains 0–6). Public minting allocates IDs starting at 7.

Brains are acquired by **staking** either Pepecoin or $basedAI for a 90-day initial lock period. There is no burn-mint path; all Brain creation uses recoverable stake.

| Method | Stake amount | Lock | Recoverability |
|---|---|---|---|
| Pepecoin stake | 100,000 PEPE | 90 days | Refundable on Brain deactivation |
| $basedAI stake | 10,000 basedAI | 90 days | Refundable on Brain deactivation |

The two stake amounts are calibrated quarterly by governance to maintain rough parity in USD terms. Initial values are illustrative; final amounts will be set at deployment based on then-current prices and adjusted on a quarterly schedule with a hard floor of 50% and ceiling of 200% of the previous quarter's value.

Both stake methods share the 64-Brain cap. The first to reach the cap fills it; the asset chosen is the staker's preference.

### 3.2 Brain transferability

Stake-minted Brains are non-transferable in v1. The Brain NFT is bound to its original staker until deactivation, at which point the stake is returned and the NFT is burned.

This is a deliberate v1 simplification. Transferability requires separating "Brain ownership" from "stake claim," which adds complexity to the contract and creates secondary-market dynamics that are difficult to reason about at the small scale (64 Brains) the network launches with. If a secondary market becomes desirable, transferability can be added in v2 via a stake-attachment mechanism that lets owners sell the operational Brain while the original staker retains stake-recovery rights.

### 3.3 Brain configuration

A Brain owner controls:

- The model served on the Brain (specified as a content hash plus a HuggingFace URL or equivalent)
- The registration fee paid by miners and validators to join (default 100 $basedAI)
- The emission split between owner and operators (default 8% / 92%, see Section 5)
- The Brain's display identity (name, ENS handle)

Configuration changes are notified to operators via gossip; miners and validators re-pull the model when it changes.

### 3.4 Reserved Brains

Seven Brain IDs (0–6) are reserved for administrative use:

| ID | Purpose |
|---|---|
| 0 | Network coordination (heartbeat, peer discovery bootstrap) |
| 1 | Reference inference Brain (operator-curated, free tier) |
| 2 | Eval set host (validator-shared challenge prompts) |
| 3 | Bug bounty submission portal |
| 4 | Reserved |
| 5 | Reserved |
| 6 | Reserved |

Reserved Brains are operated by the network's bootstrap operator (initially the team behind this implementation; transferable to a community multisig via governance). They follow the same economic rules as public Brains — they earn fees only if they perform real work, and they are subject to the same scoring system.

### 3.5 Brain capacity

Each Brain supports up to:

- **256 validators**
- **1,792 miners**

These caps match the original whitepaper. They are large enough that no Brain is expected to fill them at launch and small enough to keep on-chain enumeration tractable.

---

## 4. Participants

### 4.1 Brain owners

Brain owners hold the ERC-721 for a Brain. They configure the model, set fees, and earn 8% (default) of the fees flowing to their Brain. Their work is configuration and oversight; they are not required to operate any infrastructure themselves.

### 4.2 Miners

Miners run LLM inference on their own GPUs. To join a Brain:

1. Choose a Brain
2. Pay the registration fee in $basedAI
3. Register on-chain via `SubnetRegistry.registerMiner()`
4. Begin serving inference requests via libp2p

Miners earn 70% of fees flowing to their Brain, distributed proportionally to per-epoch scores assigned by validators.

### 4.3 Validators

Validators verify miner output and assign scores. To join:

1. Choose a Brain
2. Pay the registration fee in $basedAI
3. Register on-chain via `SubnetRegistry.registerValidator()`
4. Begin issuing challenge prompts and scoring miners

Validators earn 22% of fees flowing to their Brain, distributed proportionally to their stake on that Brain.

To prevent stake concentration, only validators in the top 70th percentile by stake on a given Brain are counted as "active" for emission purposes. This pushes validators to diversify across Brains, particularly newer ones where the active threshold is lower in absolute terms.

### 4.4 Stakers

Anyone can stake $basedAI to a (Brain, validator) tuple. Stakers don't operate infrastructure; they delegate to a validator and earn a share of that validator's fee income. Stake is subject to:

- 14-day unstaking cooldown
- Slashing if the validator they staked to is slashed for misbehavior

This mechanism lets the broader $basedAI holder community participate in network economics without running infrastructure.

---

## 5. Economic Design

The network has no protocol-level emissions. Miners and validators earn from real economic activity — users paying for inference — not from new token issuance.

### 5.1 Fee flows

Three sources of fees flow through the network:

**Registration fees.** Miners and validators pay a one-time fee in $basedAI to register on a Brain. Default 100 $basedAI, configurable by Brain owner. **100% of registration fees are burned** by sending to a dead address. This creates direct deflationary pressure on $basedAI supply proportional to network growth.

**Inference fees.** Users pay miners directly for inference. The miner sets the price; the user pays via signed receipts that are batch-redeemed on-chain through the `ComputeUnitMarket` contract. **In v1, the protocol takes 0% of inference fees.** All payments flow to miners, then to validators and Brain owner via the standard split.

**Slashed stake.** When a validator is slashed for equivocation (signing two contradictory Merkle roots in the same epoch), their stake is reduced. **100% of slashed stake is burned.**

### 5.2 Inference fee split

When a miner redeems inference receipts, the payment is split:

- **70% to the miner** who served the request
- **22% to validators** on the Brain (split by stake among active validators)
- **8% to the Brain owner**

These are protocol defaults. Brain owners can reduce their own share down to 0%. The maximum owner share is capped at 15%; only governance can raise this cap further.

The 8% default reflects that Brain owners do less ongoing work than miners (who run GPUs continuously) or validators (who score continuously). It is intentionally lower than the 25% in the original whitepaper, which assumed emission subsidies that no longer exist.

### 5.3 Why no emissions

The original whitepaper proposed a halving emission schedule starting at 10 $basedAI per 10-second block, totaling roughly 31.5M $basedAI in year one. This was designed to bootstrap miner participation before organic demand emerged.

This implementation does not include emissions because:

1. **The existing $basedAI contract cannot mint.** Its ownership is renounced; no minter role exists; supply is mathematically fixed at ~35.67M.
2. **Issuing a separate rewards token without backing would collapse to zero.** A floating "rewards token" with no convertibility to $basedAI is a synthetic emission that miners would dump immediately.
3. **The project has no treasury allocation in $basedAI.** Without backing reserves, no honest emission mechanism is available.

Instead of papering over this with emission gimmicks, the design accepts the constraint. The network must work on fee-for-service economics from day one, or it does not work. This is harder to bootstrap than emission-subsidized networks, but it is honest, and it preserves the existing token's economics for existing holders.

### 5.4 Bootstrap considerations

A fee-only network has a bootstrap problem: miners need users to earn, users need miners to use the network, and neither shows up first. This implementation addresses bootstrapping outside of protocol economics:

- **Reference Brains** (operated by the bootstrap operator) provide free or subsidized inference at launch to attract initial users.
- **Volunteer miners** from the existing BasedAI and Pepecoin communities operate hardware during the bootstrap phase, motivated by community participation rather than fee income.
- **Strategic partners** may fund miner subsidies as direct off-protocol grants. These are not emissions; they are funded operational programs that exist outside the contract economy.

The expectation is a 12–18 month period of low-volume operation before the network reaches self-sustaining fee flows. This is a known dynamic in decentralized infrastructure networks and is not unique to BasedAI.

### 5.5 Centralization caps

Two caps prevent concentration of network economic share:

- **Per-Brain cap:** A Brain's effective stake for fee weighting is capped at 0.5% of network-wide stake. Stake beyond this cap continues to earn for individual stakers (through their validator) but does not increase the Brain's share of network-wide activity. Adjustable by governance within hard bounds (0.1% min, 5% max).
- **Per-validator cap:** A single validator's effective stake is capped at 5% of network-wide stake across all Brains. Adjustable within bounds (1% min, 25% max).

Both caps apply only to weighting calculations, not to the actual stake amount a participant can hold.

### 5.6 Pepecoin's role

The original whitepaper made Pepecoin the sole gate for Brain ownership. This implementation widens that to dual-asset (Pepecoin or $basedAI) for Brain minting, while maintaining Pepecoin's role as a community participant.

Pepecoin holders:

- Can stake Pepecoin to mint Brains (same mechanics as $basedAI stakers)
- Participate in network governance via Snapshot.org voting (advisory, weighted by Pepecoin holdings)
- Are explicitly recognized as a co-equal community alongside $basedAI holders

This reflects the historical reality of the BasedAI testnet, which was launched by the Pepecoin community in May 2023, while acknowledging that the operational currency of the Ink L2 implementation is $basedAI.

---

## 6. Scoring and Validation

The network does not prove inference correctness cryptographically. Instead, validators score miners statistically and economically.

### 6.1 The scoring algorithm

Each epoch (1 hour), a validator scores each miner on its Brain along three dimensions:

**Latency (20% weight).** How quickly the miner responds, normalized against the network median.

**Quality (50% weight).** How closely the miner's responses match a held-out evaluation set of prompt/reference pairs. v1 uses token-set Jaccard similarity; v2 may use embedding similarity or perplexity comparisons.

**Consistency (30% weight).** For deterministic challenge prompts (temperature=0), the fraction of times the miner produces the modal response across the network. Miners who consistently disagree with the consensus are penalized.

Scores are computed off-chain by validators, then committed on-chain as a Merkle root over `(brainId, miner, score)` leaves.

### 6.2 Epoch commitment

At each epoch boundary:

1. Each validator independently builds a Merkle tree of its scores
2. Validators sign the root and submit signatures to an aggregator
3. The aggregator submits a co-signed root to `ScoringRegistry.proposeEpoch()`
4. The on-chain contract verifies signatures, checks that signer stake exceeds the >50% quorum threshold
5. A 1-hour challenge window opens during which fraud proofs can be submitted
6. After the challenge window, the epoch finalizes

### 6.3 Slashing via fraud proofs

If a validator signs two contradictory roots for the same epoch (equivocation), anyone can submit both signatures to `ScoringRegistry.challengeEquivocation()`. The contract verifies the signatures and slashes the validator's stake. Slashed stake is burned.

This is the only on-chain slashing mechanism in v1. Other forms of misbehavior (lazy validation, biased scoring) are addressed economically through the scoring system itself: a validator who consistently signs roots that diverge from the network mode will fall out of the active set and earn no fees.

### 6.4 What is not verified

To be explicit about the trust model: the network does not verify that:

- A miner ran the correct model (validators sample-check, but cannot prove)
- A miner's response was generated rather than pre-computed (response timing can be checked, but not proven)
- A user's prompt was kept private (it was not — miners see prompts in plaintext)
- A validator scored honestly (only equivocation is proven; bias is not)

These are the same trust assumptions as Bittensor, Akash, Render, and every other production decentralized inference network. The trust model is **economic and statistical**, not cryptographic. Misbehavior is detected through divergence from network consensus and punished through reduced earnings.

The original whitepaper claimed cryptographic guarantees via FHE and "ZK-LLMs" that would have addressed several of these limitations. Those claims are not implemented because they are not currently feasible at production performance levels.

---

## 7. Governance

Governance happens through two channels.

### 7.1 GigaBrain on-chain governance

A Brain whose total stake reaches 0.5% of network stake is automatically promoted to "GigaBrain" status, which grants one binding on-chain governance vote. The vote is binary per Brain — additional stake beyond 0.5% does not grant additional votes.

GigaBrain votes can:

- Adjust centralization caps within hard-coded bounds
- Modify default fee splits within hard-coded bounds
- Promote new contract versions (subject to a 48-hour timelock)
- Allocate the operational treasury (bug bounty payouts, audit funding)

GigaBrain votes cannot:

- Mint $basedAI (the existing contract has no minter role)
- Modify the supply schedule of $basedAI (it's fixed)
- Seize Brain NFTs
- Override scoring results

### 7.2 Snapshot signaling

Pepecoin holders and $basedAI holders can participate in Snapshot.org polls weighted by their token holdings. These polls are advisory, not binding, but Brain owners are expected to consider them when exercising their on-chain votes. Snapshot is gas-free, accessible, and scales to large holder counts in a way that on-chain voting cannot.

This two-tier system gives the broader community real input without requiring all governance traffic to flow through expensive on-chain transactions.

### 7.3 Bootstrap period

For the first 12 months after launch, the bootstrap operator retains an emergency pause capability for the `ComputeUnitMarket` contract only. This is a kill switch for catastrophic bugs, not a governance override; it cannot mint, transfer, or seize. After 12 months, the pause capability transfers to GigaBrain governance.

The bootstrap operator does not have any other admin powers — no ability to mint $basedAI (it's not possible), no ability to seize stake, no ability to override scoring.

---

## 8. Tokenomics

### 8.1 $basedAI

$basedAI is the operational currency of the network.

- **Address:** `0x44971ABF0251958492FeE97dA3e5C5adA88B9185` (Ethereum mainnet)
- **Supply:** 35,769,420 (fixed; ~100k burned via the contract's `burn()` function as of Q2 2026)
- **Mint:** Not possible (ownership renounced, no minter role)
- **Bridged to Ink** via the canonical OP Stack bridge for use within the network

Demand for $basedAI comes from:

- Miner and validator registration fees (burned on payment)
- Brain minting (one acquisition method)
- Inference payments by users
- Staking to validators for fee share

Network growth creates direct demand for the token without requiring new issuance. As registration fees are burned, the supply continues its existing slow deflation.

### 8.2 Pepecoin

Pepecoin is the alternative Brain-acquisition asset and the gate for community governance signaling.

- **Address:** `0xA9E8aCf069C58aEc8825542845Fd754e41a9489A` (Ethereum mainnet)
- **Role:** Brain stake-mint (alternative to $basedAI), Snapshot governance weight

Pepecoin's role is preserved for continuity with the original BasedAI testnet community. Brains can be minted with either Pepecoin or $basedAI at the staker's preference.

### 8.3 No new tokens

This implementation does not issue any new tokens. No rewards token, no governance token, no Brain token, no team token, no investor token. The existing $basedAI and Pepecoin contracts are the only tokens that participate in the network's economics.

This is a deliberate constraint. It simplifies the legal posture (no issuance event), preserves existing holders' economic position (no dilution), and removes a category of design temptation (creating new tokens to solve problems that don't actually require them).

---

## 9. Implementation

The on-chain implementation consists of the following Solidity contracts on Ink L2:

| Contract | Purpose |
|---|---|
| `BrainNFTL2` | L2 representation of mainnet Brain NFTs |
| `SubnetRegistry` | Per-Brain configuration and miner/validator membership |
| `StakingVault` | $basedAI staking with cooldown unstaking and slashing |
| `ScoringRegistry` | Epoch Merkle commitments and fraud proofs |
| `ComputeUnitMarket` | Signed receipt redemption for inference payments |
| `BasedGovernor` | GigaBrain on-chain voting with timelock |

Plus on Ethereum mainnet:

| Contract | Purpose |
|---|---|
| `BrainNFT` | Canonical Brain NFT, accepts Pepecoin or $basedAI stake |
| `BrainBridgeAdapter` | Helper for bridging Brain ownership to L2 |

Off-chain components:

| Component | Purpose |
|---|---|
| Reference miner | Python implementation using vLLM and libp2p |
| Reference validator | Python implementation with scoring algorithm and Merkle commitment |
| Aggregator service | Collects validator signatures and submits to `ScoringRegistry` |
| HTTP gateway | Browser-compatible relay to libp2p network |
| Indexer | Subgraph or Postgres indexer for off-chain queries |

The implementation is open source under the MIT license and available at the project's GitHub repository.

### 9.1 Audit and security

All custom contracts will be audited prior to mainnet deployment. The OZ-derived contracts (token interfaces, governance scaffolding) have less new attack surface than the protocol-specific contracts (`ScoringRegistry`, `StakingVault`, `ComputeUnitMarket`, `SubnetRegistry`).

A bug bounty program will be active before mainnet, with critical-severity payouts up to $250,000 from the operational treasury.

Known limitations are documented in `docs/security.md` and tracked publicly. The implementation is intentionally non-upgradable: contracts ship as immutable code, and changes require new deployments and migration. This trades flexibility for trust-minimization.

---

## 10. Roadmap

The roadmap is structured around capability milestones, not calendar dates.

**Phase 1 — Audit-ready code.** Contracts compiled, tested with >90% coverage, hardened against the v1 simplifications documented in `docs/security.md`. Off-chain components running end-to-end on testnet. Audit firm engaged.

**Phase 2 — Audit and remediation.** External audit completed; all critical and high findings resolved. Bug bounty program live on Immunefi.

**Phase 3 — Public testnet.** Contracts deployed to Ink Sepolia. 10–20 community-operated miners and 5–10 validators run the network for at least 30 consecutive days. Real users submit real prompts.

**Phase 4 — Mainnet launch.** Contracts deployed to Ink. Reserved Brains (0–6) pre-minted. Public Brain minting opens. Initial reference Brains operational with bootstrap volunteer miners.

**Phase 5 — Decentralization.** Bootstrap operator's emergency pause capability transfers to GigaBrain governance. Aggregator service becomes permissionless. Multiple independent indexers operate the discovery layer.

There are no token sales, no fundraising rounds, no presale events, and no investor allocations associated with this roadmap. The implementation is funded by the project team and any voluntary contributors.

---

## 11. Honest Limitations

This section catalogs what the system does not do, so that participants can evaluate it accurately.

**No cryptographic privacy.** Miners see prompts in plaintext. Sensitive prompts (medical, legal, financial) should be appropriately redacted before submission. Anyone running a miner can log all traffic flowing through their node.

**No proof of inference correctness.** Validators sample-check, but cannot prove a miner ran the correct model. A miner who substitutes a smaller cheaper model would be detected over time through quality scoring, but not in any single inference.

**No protection against censorship by miners.** Miners can refuse to serve specific users or specific prompt patterns. Users can switch miners, but cannot force any particular miner to serve them.

**No guaranteed availability.** Brains can be deactivated. Miners can leave. Validators can leave. The network as a whole has no SLA, and individual Brains have only the SLAs their owners choose to advertise.

**Bridge dependency.** Brain ownership originates on Ethereum mainnet but is read on Ink L2 via the canonical bridge. Bridge security is the largest single risk in the system. Ink's bridge is a standard OP Stack canonical bridge operated within the Optimism Superchain framework; the trust model is explicitly that of an OP Stack rollup, not a fully trustless system.

**Sequencer dependency.** Ink's sequencer is currently operated by Kraken / the Ink Foundation. Transactions can in principle be censored or reordered. OP Stack's roadmap to decentralized sequencing has not yet been delivered. Ink launched with permissionless fault proofs and multiple challengers (Kraken and Gelato), which provides stronger withdrawal guarantees than chains relying on a single challenger but does not change sequencer-level assumptions.

**Bootstrap fragility.** Without protocol emissions, the network depends on volunteer miners or off-protocol funding to bootstrap. If neither materializes, the network may fail to reach critical mass and may not survive its first year.

These limitations are real and not being hidden. They define what the network is and is not. A user or operator who understands these limitations and chooses to participate is participating in the system as it actually is, not as a marketing description portrays it.

---

## 12. Conclusion

BasedAI v2 is a more modest and more honest design than its predecessor. It does not claim cryptographic privacy. It does not promise emission-funded yields. It does not introduce new tokens. It does not require trust in a team's continued operation.

What it does is build infrastructure that creates demand for two existing community tokens, while paying real network operators for real work, on a Layer 2 that ships in months rather than years.

The original whitepaper described a system that, in retrospect, was not buildable as specified. This version describes a system that is. Whether the network finds product-market fit in the broader inference economy is an open question that the implementation cannot answer — only operation can. But the implementation, at least, is honest about what it is, and that honesty is the foundation on which any real network economy must rest.

---

## Appendices

### A. References

- Original BasedAI whitepaper (Wellington, S., February 2024). Retained for historical context; superseded by this document.
- Bittensor whitepaper (Rao, J. et al., 2021). The closest architectural analog.
- Optimism Stack documentation. The L2 framework Ink inherits from.
- OpenZeppelin Contracts v5. The standards library used throughout the implementation.

### B. Contract addresses

To be populated at deployment. Mainnet $basedAI and Pepecoin addresses are listed in Section 8 and are immutable.

### C. Glossary

- **Brain:** A subnet within the BasedAI network, representing a configured model instance with its own miners and validators.
- **GigaBrain:** A Brain whose total stake exceeds 0.5% of network stake, granting it one on-chain governance vote.
- **Epoch:** A 1-hour period over which scoring is aggregated and committed.
- **Equivocation:** A validator signing two contradictory commitments for the same epoch — the only on-chain slashing condition in v1.
- **Bootstrap operator:** The team or multisig responsible for the network at launch, with limited emergency-pause capability that transfers to governance after 12 months.

---

*This document supersedes BasedAI Whitepaper v1.0 (February 2024). It will itself be revised as the network's design evolves.*
