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

v1 contracts are audited by [TBD]. Audit reports live in `docs/audits/`.

The custom contracts (`ScoringRegistry`, `ComputeUnitMarket`, `SubnetRegistry`, `StakingVault`, `BasedGovernor`) are highest priority for audit. The L2 NFT (`BrainNFTL2`) is mostly OpenZeppelin and has less new attack surface. The mainnet `BrainNFT` has custom dual-asset stake-mint logic and should also be audited carefully.

## Known limitations

- The `ScoringRegistry` v1 simplification iterates a fixed set of Brain IDs when summing signer stake. Production needs an indexer or per-epoch signer-set declaration. Tracked as issue #TBD.
- The `StakingVault` slashing mechanism v1 burns at the validator level rather than rebasing per-staker. A staker who unstakes after a slash receives a proportional reduction; pre-slash unstake requests are not retroactively slashed. Tracked as issue #TBD.
- Equivocation fraud proofs in v1 require off-chain monitoring. A future version should incentivize fraud-proof submission with a portion of the slashed stake.

## Operational security

The admin multisig holds emergency pause capability for `ComputeUnitMarket` only. It cannot:

- Mint BASED outside the emission schedule
- Modify the emission schedule
- Seize Brain NFTs
- Override scoring results

After the bootstrap period (12 months), admin keys transfer to the timelocked governance contract.
