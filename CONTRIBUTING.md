# Contributing

## Development setup

```bash
git clone https://github.com/basedai/basedai
cd basedai
make install
make test
```

## Project structure

See `README.md` for the layout. Each subdirectory has its own README with package-specific instructions.

## Code style

- **Solidity:** `forge fmt`. 120-char lines. Custom errors over revert strings. Events on every state change.
- **Python:** `ruff` for lint, `ruff format` for formatting. Type hints required on all public functions. `from __future__ import annotations` at the top of every file.
- **TypeScript:** strict mode. No `any`. Public API exported from `src/index.ts`.

## Pull requests

- Open against `main`.
- Add tests for any non-trivial change. CI must pass.
- Keep PRs focused. Splitting a refactor + a feature into two PRs is always better than one.
- Squash on merge. Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## Contracts: testing standards

Every contract in `src/` needs:

- A unit test file in `test/` covering happy paths, revert cases, and access control.
- At least one fuzz test for any function that takes user input (amounts, addresses).
- Invariant tests for state-machine contracts (`StakingVault`, `ScoringRegistry`).
- Gas snapshots committed to `.gas-snapshot` (run `forge snapshot` before opening a PR).

## Off-chain components: testing standards

- Unit tests for pure logic (scoring, Merkle construction, receipt signing).
- Integration tests that run against `anvil` for anything touching the chain.
- No tests requiring GPU or model downloads in CI; gate those behind a `slow` marker.

## Security-sensitive changes

Any change to:

- Token mint/burn paths
- Slashing logic
- Emission calculation
- Receipt redemption
- Bridge interfaces

requires two reviewers, one of whom must have a security background. These changes should also trigger a partial re-audit before mainnet promotion.

## Dependencies

We pin major versions of OpenZeppelin and Foundry. Updating them is a security-sensitive change (see above). Adding a new dependency requires justification in the PR.
