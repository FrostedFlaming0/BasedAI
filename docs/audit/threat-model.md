# Threat Model

## Assets

- User spending balances in `ComputeUnitMarket`.
- Staked BASED in `StakingVault`.
- Brain NFTs on L1 and their L2 representations.
- Validator fee accruals in `RewardDistributor`.
- Score roots in `ScoringRegistry`.
- Governance control through `BasedGovernor` and `TimelockController`.

## Trust boundaries

- L1 Ethereum: Brain minting, L1 escrow, and canonical bridge entry.
- Ink L2: market, staking, scoring, gateway-verified score routing, governance.
- Off-chain services: gateway, miner, validator, and aggregator.
- External canonical infrastructure: Ink/OP Stack bridges and RPC providers.

## Adversaries

- Users attempting to underpay miners or replay receipts.
- Miners attempting to overcharge, mutate final receipts, submit stale receipts, or serve malformed output.
- Validators attempting equivocation, low-quality scoring, omission, or collusion.
- Brain owners changing fee settings to grief participants.
- Gateway attackers attempting SSRF, replayed announces, stale membership, or DoS.
- Governance/guardian key compromise.
- Bridge/RPC operator failure or compromise.

## Main mitigations

- Receipts bind contract address, chain id, user, miner, Brain id, prompt hash,
  response hash, amount, expiry, and nonce.
- Pre-authorization receipts are capped by `maxReservation`; full payment requires
  a client-counter-signed final receipt bound to the delivered response.
- Pricing uses UTF-8 byte counts and on-chain `pricePerByte` / `pricePerRequest`,
  independently computable by clients and miners.
- Withdrawals are delayed so signed receipts remain redeemable before collateral exits.
- Staking is share-based; active and pending unstake shares are slashable pro-rata.
- Score commitments are Brain-local, domain-separated, challenge-windowed, and
  invalidated on equivocation.
- L2 Brain mint/burn authority is immutable and restricted to the canonical L2 bridge.
- Deployment scripts assert bridge/governance reachability before renouncing deployer admin roles.
- Gateway announces are signed, time-bounded, SSRF-guarded, and rebuilt from canonical event history on restart/reorg.
- CI and locks pin dependencies/toolchains for reproducible audit candidates.

## Accepted risks before public testnet

- Validator scoring is heuristic and collusion resistance depends on stake distribution and monitoring.
- Aggregator availability is operational; validators can resubmit to another aggregator but this is not automated on-chain.
- Canonical bridge live message passing must be validated on public testnet.
- The HTTP transport is the testnet path; libp2p is not part of the current production readiness claim.

## Monitoring requirements

- Receipt redemption failures and nonce reuse attempts.
- Gateway announce rejection rates, SSRF blocks, and reorg rebuild events.
- Aggregator quorum progress, candidate divergence, and failed `proposeEpoch` transactions.
- Equivocation signatures and slashing events.
- Guardian pause/cancel actions and timelock queued operations.
- Bridge deposit/withdrawal finality and mismatch between L1 escrow and L2 supply.
