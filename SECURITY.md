# Security

## Reporting vulnerabilities

**Do not open public issues for security problems.**

Email: `security@basedai.network` (PGP key: see `docs/pgp.txt`)

Or use the Immunefi program: `https://immunefi.com/bounty/basedai/` (live after mainnet launch).

## Bug bounty scope

Critical (up to $250,000):
- Loss of user funds
- Theft of staked BASED
- Incorrect emission distribution that drains the supply

High (up to $50,000):
- Brain ownership theft
- Validator equivocation that bypasses slashing
- Receipt double-spend

Medium (up to $10,000):
- Griefing miners or validators out of legitimate emissions
- Permission escalation in governance

Out of scope:
- Issues on testnet
- Frontend issues that don't affect contract security
- Social engineering of token holders
- DoS via gas exhaustion (except where it leads to fund loss)

## Audits

This repository is pre-audit. The audit candidate must be identified by an
explicit commit or tag and accompanied by:

- `docs/audit/audit-scope.md`
- `docs/audit/threat-model.md`
- `docs/audit/privilege-matrix.md`
- `docs/audit/deployment-manifest.template.json` or a network-specific manifest generated from it

Highest-priority audit surfaces are the custom contracts (`BrainNFT`,
`StakingVault`, `ScoringRegistry`, `ComputeUnitMarket`, `RewardDistributor`,
`SubnetRegistry`, `BasedGovernor`) and deployment scripts. `BrainNFTL2` is
small and mostly OpenZeppelin, but its immutable bridge/remote-token wiring is
security-critical.

## Known limitations

- Validator scoring is heuristic. Before mainnet, use a non-public eval set,
  add collusion/Sybil monitoring, and treat score roots as routing/slashing
  inputs rather than as proof of model correctness.
- Equivocation fraud proofs require off-chain monitoring. A future version
  should consider permissionless proof rewards funded from slashed stake.
- The HTTP gateway/aggregator path is the testnet transport. The libp2p module
  remains a stub and is explicitly out of mainnet readiness unless separately
  completed and audited.
- Public testnet must still validate live Ink bridge message passing end to end:
  L1 deposit -> L2 mint -> L2 withdrawal -> L1 release.

## Operational security

The bootstrap guardian may hold emergency pause capability for `ComputeUnitMarket`
and timelock cancellation capability only. It cannot:

- Mint BASED outside the emission schedule
- Modify the emission schedule
- Seize Brain NFTs
- Override scoring results
- Withdraw user balances or staked funds

Protocol administration is transferred to the timelocked governor during deployment;
the deployer renounces bootstrap admin roles before the script completes.
