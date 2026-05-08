# Deployment

BasedAI v2 deploys to two chains: **Ethereum mainnet** (Brain NFT issuance) and **Ink L2** (everything else).

## Order of operations

The order matters because L2 contracts reference each other and need addresses at construction time.

### Phase 1: Ethereum mainnet

Deploy the Brain NFT and bridge adapter. These are independent of L2 deployment.

The Brain NFT references the existing $basedAI (`0x44971ABF...`) and Pepecoin (`0xA9E8aCf0...`) contracts; no new tokens are deployed.

Required env vars:

```
DEPLOYER_PRIVATE_KEY  - the deployer's private key
PEPECOIN              - 0xA9E8aCf069C58aEc8825542845Fd754e41a9489A
BASEDAI               - 0x44971ABF0251958492FeE97dA3e5C5adA88B9185
PEPE_STAKE            - initial Pepecoin stake amount (e.g., 100000000000000000000000 for 100k PEPE)
BASED_STAKE           - initial $basedAI stake amount (e.g., 10000000000000000000000 for 10k basedAI)
GOVERNANCE            - address that can adjust stake amounts (multisig recommended)
BRAIN_NFT_L2          - L2 BrainNFT representation address (from Phase 2 below)
L1_NFT_BRIDGE         - Ink's canonical L1 NFT bridge address (look up from Ink docs)
```

Run:

```bash
forge script script/DeployMainnet.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
```

Save the `BrainNFT` address.

### Phase 2: Ink L2

Deploys the L2 stack. Requires the bridged $basedAI address (the canonical bridge representation of the mainnet contract).

Required env vars:

```
DEPLOYER_PRIVATE_KEY  - the deployer's private key
ADMIN                 - admin/governance address (multisig recommended)
BASEDAI_L2            - bridged $basedAI on Ink
```

Run:

```bash
forge script script/Deploy.s.sol --rpc-url $INK_RPC --broadcast --verify
```

The script deploys, in order:

1. **`BrainNFTL2`** — L2 representation of the mainnet Brain NFT
2. **`SubnetRegistry`** — per-Brain configuration; references BrainNFTL2 and $basedAI
3. **`StakingVault`** — staking mechanics
4. **`ScoringRegistry`** — epoch commitments and slashing; references StakingVault
5. **`ComputeUnitMarket`** — receipt redemption
6. **`TimelockController`** — 48-hour governance timelock
7. **`BasedGovernor`** — GigaBrain voting

After deployment, it grants `SLASHER_ROLE` on `StakingVault` to `ScoringRegistry`.

### Phase 3: Bridge configuration

Grant `BRIDGE_ROLE` on `BrainNFTL2` to Ink's canonical L1→L2 NFT bridge contract. The exact address depends on Ink's bridge deployment for ERC-721s; check Ink's bridge registry at `https://docs.inkonchain.com`.

### Phase 4: Reserve admin Brain IDs

Pre-mint Brains 0–6 to the bootstrap operator's multisig. These are reserved for administrative use (network coordination, reference inference, eval set host, bug bounty portal, plus three reserved IDs).

Reserved Brains require staking like all others — the multisig must hold either Pepecoin or $basedAI to seed these. They are subject to the same lock period (90 days) as public Brains.

## Network configurations

### Ink Sepolia (testnet)

- RPC: `https://rpc-gel-sepolia.inkonchain.com`
- Chain ID: 763373
- Bridge: `https://inkonchain.com` (testnet variant)
- Explorer: `https://explorer-sepolia.inkonchain.com`

For testnet, you'll need test versions of Pepecoin and $basedAI — deploy mocks if real testnet versions don't exist on Ink Sepolia.

### Ink mainnet

- RPC: `https://rpc-gel.inkonchain.com`
- Chain ID: 57073
- Bridge: `https://inkonchain.com`
- Explorer: `https://explorer.inkonchain.com`

## Verification

After deployment, verify all contracts on Ink's explorer:

```bash
forge verify-contract <address> src/tokens/BrainNFTL2.sol:BrainNFTL2 \
  --chain ink --watch
```

The deploy scripts can do this automatically with the `--verify` flag if `INK_EXPLORER_API_KEY` is set.

## Post-deployment checklist

- [ ] All contracts verified on Ink's explorer and Etherscan (for L1 contracts)
- [ ] `SLASHER_ROLE` granted to `ScoringRegistry` on `StakingVault`
- [ ] `BRIDGE_ROLE` granted to canonical L1 bridge on `BrainNFTL2`
- [ ] Admin Brain IDs (0–6) staked and minted to operator multisig
- [ ] Subgraph or indexer running for miner/validator discovery
- [ ] Gateway service running for HTTP-to-libp2p relay
- [ ] Documentation links updated with mainnet addresses
- [ ] Reference miner and validator deployed for at least one reference Brain
- [ ] Bug bounty live on Immunefi

## Upgrade strategy

Contracts are deployed as non-upgradable in v1. Upgrades happen by:

1. Deploying new contract versions
2. Migrating state where necessary
3. Updating the bridge configuration if the L2 representation changes

This is intentional: upgradability is the most common cause of "trustless" protocols turning out to be trusted. v1 ships immutable.
