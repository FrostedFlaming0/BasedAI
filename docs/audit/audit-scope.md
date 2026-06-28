# Audit Scope

## Audit candidate

The audit candidate is the clean Git commit or tag produced after all validation
commands in `docs/validation-report.md` pass. Auditors should treat uncommitted
changes as out of scope.

## In scope

### Solidity contracts

- `contracts/src/tokens/BrainNFT.sol`
- `contracts/src/tokens/BrainNFTL2.sol`
- `contracts/src/tokens/BrainBridgeAdapter.sol`
- `contracts/src/staking/StakingVault.sol`
- `contracts/src/subnet/SubnetRegistry.sol`
- `contracts/src/market/ComputeUnitMarket.sol`
- `contracts/src/reward/RewardDistributor.sol`
- `contracts/src/scoring/ScoringRegistry.sol`
- `contracts/src/governance/BasedGovernor.sol`
- all interfaces in `contracts/src/interfaces/`

### Deployment scripts

- `contracts/script/DeployMainnet.s.sol`
- `contracts/script/Deploy.s.sol`

### Off-chain testnet services and clients

- `gateway/src/basedai_gateway/`
- `miner/src/basedai_miner/`
- `validator/src/basedai_validator/`
- `client/python/basedai_client/`
- `client/typescript/src/`
- `scripts/devnet_e2e.py`
- CI workflows and dependency lockfiles

## Out of scope

- OpenZeppelin, forge-std, viem, web3.py, aiohttp, and other third-party packages except for correct integration and version pinning.
- Ink/OP Stack canonical bridge internals.
- RPC provider correctness and availability.
- GPU/model runtime correctness and model-output quality.
- Frontend/UI code; none is included in this repository.
- libp2p production transport; HTTP is the current testnet path.

## Specific questions for auditors

- Can any receipt mutation, replay, domain confusion, expiry edge case, or withdrawal race result in unpaid inference or overcharge?
- Do staking share, slashing, reward, pending-unstake, and rounding paths preserve solvency under arbitrary call sequences?
- Are fee splits value-conserving under all Brain configurations and inactive-subnet cases?
- Can a score root be proposed/finalized for the wrong Brain, current epoch, insufficient stake, duplicate signer set, or invalidated commitment?
- Can a validator avoid slashing after signing conflicting roots?
- Are deployment scripts free of deadlocks and residual deployer superuser privileges?
- Can bridge configuration lock Brains one-way or mint an L2 Brain without L1 escrow?
- Can the gateway accept SSRF endpoints, stale announces, orphaned reorg events, or unverified score updates?
- Are all operational privileged actions documented in `docs/audit/privilege-matrix.md`?

## Known limitations to include in report

- Public testnet must still execute live Ink bridge message passing.
- Validator scoring remains heuristic and needs operational anti-collusion monitoring.
- Aggregator and gateway are operational services; high availability is not enforced by contracts.
- No upgrade proxies are used; fixes require redeployment/migration.
