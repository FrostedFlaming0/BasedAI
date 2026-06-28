# Validation Report

This report records the reproducible validation gates for the audit-candidate
repository state. It replaces the earlier static-only report.

## Required local commands

Run from the repository root:

```bash
forge --version
anvil --version
python3 --version
node --version
npm --version

cd contracts
forge fmt --check
forge build --sizes
FOUNDRY_PROFILE=ci forge test -vvv
forge coverage --report summary
cd ..

cd miner && ruff check src tests && PYTHONPATH=src pytest -v && cd ..
cd validator && ruff check src tests && PYTHONPATH=src pytest -v && cd ..
cd gateway && ruff check src tests && PYTHONPATH=src pytest -v && cd ..
cd client/python && ruff check basedai_client tests && PYTHONPATH=. pytest -v && cd ../..

cd client/typescript
npm ci
npm audit --omit=dev --audit-level=high
npm run lint
npm run typecheck
npm run build
npm test
cd ../..

ruff check scripts/devnet_e2e.py
PYTHONPATH=client/python:gateway/src:miner/src:validator/src python scripts/devnet_e2e.py
git diff --check
```

## Coverage added before audit

- Stateful staking solvency invariants:
  - vault token balance equals `totalStaked()`;
  - Brain totals sum to total;
  - validator pools sum to Brain stake;
  - effective stake never exceeds raw stake or centralization cap.
- Receipt pricing and fee-conservation fuzz tests.
- Epoch lifecycle fuzz tests for proposal/finalization/invalidation.
- Role reachability tests for deployer renunciation, timelock execution, guardian pause, and role-only functions.
- Full bridge tests:
  - direct canonical L1 bridge path;
  - optional adapter path;
  - L1 release path;
  - endpoint revocation;
  - L2 bridge-only mint/burn and soulbound behavior.
- Deployment-script tests for L1 phase-one, L1 adapter wiring, L2 role handoff, immutable bridge config, and deadlock guards.
- Deterministic devnet E2E script:
  - miner announce/discovery;
  - infer/final receipt/settle;
  - bad receipt failure;
  - candidate aggregation and quorum proposal;
  - forged commitment rejection;
  - gateway cursor restart and reorg-style canonical rebuild.

## Expected limitations

- `forge coverage` may emit Solidity/Yul warnings depending on the Foundry
  release. Treat coverage as a reporting gate, not as the only test signal.
- The deterministic devnet script is CI-safe and does not fork Ink or download a
  model. A public testnet run must still validate real RPC behavior, canonical
  Ink bridge message passing, and long-running service recovery.
- The current scoring algorithm is intentionally simple and must be threat-modeled
  as heuristic routing data, not as cryptographic proof of model quality.
