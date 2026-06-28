#!/usr/bin/env python3
"""Generate a source/toolchain deployment manifest skeleton for an audit candidate."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "contracts/src/tokens/BrainNFT.sol",
    "contracts/src/tokens/BrainNFTL2.sol",
    "contracts/src/tokens/BrainBridgeAdapter.sol",
    "contracts/src/staking/StakingVault.sol",
    "contracts/src/subnet/SubnetRegistry.sol",
    "contracts/src/market/ComputeUnitMarket.sol",
    "contracts/src/reward/RewardDistributor.sol",
    "contracts/src/scoring/ScoringRegistry.sol",
    "contracts/src/governance/BasedGovernor.sol",
    "contracts/script/DeployMainnet.s.sol",
    "contracts/script/Deploy.s.sol",
]


def _run(args: list[str]) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def main() -> None:
    manifest = {
        "schema": "basedai.deployment-manifest.v1",
        "audit_commit": _run(["git", "rev-parse", "HEAD"]),
        "audit_tag": "",
        "generated_at_utc": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat(),
        "toolchain": {
            "forge": _run(["forge", "--version"]).splitlines()[0],
            "python": _run(["python3", "--version"]),
            "node": _run(["node", "--version"]),
            "npm": _run(["npm", "--version"]),
            "solc": "0.8.24",
        },
        "submodules": _run(["git", "submodule", "status", "--recursive"]).splitlines(),
        "source_checksums_sha256": {src: _sha256(ROOT / src) for src in SOURCES},
        "networks": {
            "ethereum_l1": {"chain_id": 1, "contracts": {}},
            "ink_l2": {"chain_id": 57073, "contracts": {}},
        },
        "roles": [],
        "validation_commands": [
            "cd contracts && forge fmt --check && forge build --sizes && FOUNDRY_PROFILE=ci forge test -vvv",
            "cd miner && ruff check src tests && PYTHONPATH=src pytest -v",
            "cd validator && ruff check src tests && PYTHONPATH=src pytest -v",
            "cd gateway && ruff check src tests && PYTHONPATH=src pytest -v",
            "cd client/python && ruff check basedai_client tests && PYTHONPATH=. pytest -v",
            "cd client/typescript && npm ci && npm run lint && npm run typecheck && npm test",
            "PYTHONPATH=client/python:gateway/src:miner/src:validator/src python scripts/devnet_e2e.py",
        ],
    }
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
