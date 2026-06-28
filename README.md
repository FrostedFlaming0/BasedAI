# BasedAI

> ⚠️ **Prototype — not production-ready, not audited for deployment.** Several economic
> components described below (fee distribution, staking rewards, emissions, score-driven payouts)
> are **not yet implemented**, and parts of the off-chain network are stubs. See
> [IMPLEMENTATION_STATUS.md](./IMPLEMENTATION_STATUS.md) for the authoritative
> implemented-vs-planned matrix and [SECURITY_AUDIT.md](./SECURITY_AUDIT.md) for findings.
> Do not deposit funds, stake, bridge, or deploy to mainnet.

A decentralized LLM inference network built on Ink (Kraken's L2), with NFT-gated subnets, stake-weighted scoring, and EVM-native economics anchored to existing community tokens.

## What this is

BasedAI is a network where:

- **Brain owners** acquire ERC-721 NFTs by staking either Pepecoin or $basedAI, granting them the right to operate a subnet for a specific model.
- **Miners** run LLM inference on GPUs and serve prompts.
- **Validators** spot-check miner output and assign scores.
- **Users** pay in $basedAI for inference; rewards flow to participants based on stake-weighted scoring.

The full design is documented in [`whitepaper-v2.md`](./whitepaper-v2.md). This repository contains the implementation: Solidity contracts, miner/validator reference software, and client libraries.

## Background

This implementation follows the BasedAI Testnet, commenced May 2023 by Big Brain Pepe — one of the earliest decentralized AI testnets to go live. The testnet validated the core subnet architecture and informed the design choices in this repository, including the move to an L2-native deployment model and the omission of the cryptographic claims from the original whitepaper that did not hold up under scrutiny.

## What this is not

This implementation deliberately omits several mechanisms from the original 2024 whitepaper that did not hold up under scrutiny:

- **No FHE-based "Zero-Knowledge LLMs."** Inference happens on miner GPUs in plaintext; verification is statistical and economic, not cryptographic.
- **No "Cerberus Squeezing."** The optimization technique described in the original paper was repackaged standard quantization and did not solve the FHE performance bottleneck.
- **No protocol-level emissions.** The existing $basedAI contract has fixed supply and renounced ownership; new emissions are not possible without issuing a new token. The network operates on fee-for-service economics.
- **No new tokens.** This implementation uses the existing $basedAI (`0x44971ABF0251958492FeE97dA3e5C5adA88B9185`) and Pepecoin (`0xA9E8aCf069C58aEc8825542845Fd754e41a9489A`) contracts. No team token, no rewards token, no investor allocation.

If you need cryptographic privacy for AI inference, this is not the project for you. If you need a decentralized inference marketplace with honest threat modeling, it is.

## Repository layout

```
contracts/        Solidity contracts (Foundry)
miner/            Reference miner implementation (Python, vLLM-based)
validator/        Reference validator implementation (Python)
client/
  typescript/     TypeScript client library (browser/Node)
  python/         Python client library
docs/             Architecture, deployment, tokenomics, security
scripts/          Static checks, off-chain services
whitepaper-v2.md  Full design specification
```

## Quick start

```bash
# Install dependencies
make install

# Run contract tests
make test-contracts

# Run miner tests
make test-miner

# Deploy to Ink Sepolia testnet (requires BASEDAI_L2 env var)
make deploy-testnet
```

See [`docs/getting-started.md`](./docs/getting-started.md) for full setup, [`docs/architecture.md`](./docs/architecture.md) for the design, and [`docs/tokenomics.md`](./docs/tokenomics.md) for economic mechanics.

## Status

Pre-alpha. Contracts are unaudited. Do not deploy to mainnet without a professional audit. Not for production use.

## CI status

CI is currently red. This is expected pre-alpha state — the scaffold needs a Foundry build pass to surface and fix the OZ v5 API drift the static checks couldn't catch. Tracked in issue #1.

## License

MIT. See `LICENSE`.
