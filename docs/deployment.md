# Deployment

BasedAI v2 deploys to two chains: **Ethereum mainnet** (Brain NFT issuance) and **Ink L2** (everything else).

## Order of operations

The L1 and L2 sides each reference an address produced by the other (the L1 bridge adapter needs the
L2 NFT; the L2 NFT minter is the canonical bridge). To avoid a circular dependency, **the L1 NFT is
deployed first WITHOUT the adapter**, then the L2 stack, then the adapter is wired in a final phase
once both addresses exist. No phase requires an address from a later phase.

### Phase 1: Ethereum mainnet — Brain NFT only

Deploy ONLY the L1 Brain NFT. Do **not** set `BRAIN_NFT_L2` or `L1_NFT_BRIDGE` yet — leaving them
unset makes `DeployMainnet` skip the adapter, so there is no dependency on the (not-yet-deployed) L2
address. The adapter is deployed in Phase 3.

The Brain NFT references the existing $basedAI (`0x44971ABF...`) and Pepecoin (`0xA9E8aCf0...`) contracts; no new tokens are deployed.

Required env vars:

```
DEPLOYER_PRIVATE_KEY  - the deployer's private key
PEPECOIN              - 0xA9E8aCf069C58aEc8825542845Fd754e41a9489A
BASEDAI               - 0x44971ABF0251958492FeE97dA3e5C5adA88B9185
PEPE_STAKE            - initial Pepecoin stake amount (e.g., 100000000000000000000000 for 100k PEPE)
BASED_STAKE           - initial $basedAI stake amount (e.g., 10000000000000000000000 for 10k basedAI)
GOVERNANCE            - address that can adjust stake amounts (multisig recommended)
# BRAIN_NFT_L2 / L1_NFT_BRIDGE  - OMIT in Phase 1 (set them only in the optional one-shot path)
```

Run:

```bash
forge script script/DeployMainnet.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
```

Save the `BrainNFT` address (needed by Ink's bridge config and by Phase 3).

### Phase 2: Ink L2

Deploys the L2 stack. `BrainNFTL2` is an OP Stack **`OptimismMintableERC721`** minted/burned ONLY by
Ink's canonical **`L2ERC721Bridge`** (predeploy `0x4200000000000000000000000000000000000014`). L2 Brains
therefore exist solely by bridging a real Brain from L1, so the **L1 Brain NFT address is mandatory**.

> **`L1_BRAIN_NFT` is mandatory.** It is the remote token the L2 representation mints against. Without
> it there is no L2 Brain mint path; since the deploy renounces admin and governance needs a Brain
> quorum, omitting it would permanently deadlock administration. The script reverts if it is unset.

Required env vars:

```
DEPLOYER_PRIVATE_KEY  - the deployer's private key
ADMIN                 - admin/governance address (multisig recommended)
BASEDAI_L2            - bridged $basedAI on Ink
L1_BRAIN_NFT          - the Phase-1 L1 BrainNFT address (remote token) [REQUIRED]
L2_ERC721_BRIDGE      - Ink's L2ERC721Bridge predeploy (default 0x4200..0014; the L2 Brain minter)
L1_REMOTE_CHAIN_ID    - chain id of L1 (default 1 mainnet; use 11155111 for Sepolia)
GOV_QUORUM_VOTES      - governance quorum in Brains (default 4; must be in (0, 64])
GUARDIAN              - optional multisig that can CANCEL queued proposals
MARKET_MAX_RESERVATION- pre-auth draw cap (default 1 ether)
MARKET_PRICE_PER_BYTE    - price per UTF-8 request/response byte (wei)
MARKET_PRICE_PER_REQUEST - fixed request charge (wei); at least one price must be nonzero
```

Run:

```bash
forge script script/Deploy.s.sol --rpc-url $INK_RPC --broadcast --verify
```

The script deploys `BrainNFTL2` (minter = the canonical bridge, fixed at construction), `SubnetRegistry`,
`StakingVault`, `ScoringRegistry`, `ComputeUnitMarket`, `TimelockController`, and `BasedGovernor`; grants
`SLASHER_ROLE` to `ScoringRegistry`, wires the fee/reward roles, then **asserts governance reachability**
(L2 minter = canonical bridge, L1 remote token wired, governor can propose, execution open) before the
deployer renounces its keys. Save the `BrainNFTL2` address.

> **Governance bootstrapping.** Because L2 Brains exist only by bridging from L1, governance has zero
> voting power until Brains are bridged. Seed it by minting the reserved admin Brains (0–6) on L1 and
> bridging them to L2 before relying on on-chain governance.

### Phase 3: Bridge wiring (after both chains are deployed)

Ink uses the standard OP Stack ERC-721 bridge — **no custom bridge or placeholder is required.** Once
both the L1 `BrainNFT` and L2 `BrainNFTL2` addresses exist, authorize the bridge on L1:

1. **Authorize Ink's canonical L1ERC721Bridge** on the L1 BrainNFT — it is the escrow for **both**
   deposit (locks the Brain) and withdrawal (releases it), so it must be an allowed endpoint or
   escrow→user withdrawal reverts (the one-way lock). Call `BrainNFT.setBridge(<L1ERC721Bridge>)`.
2. **(Optional) deploy `BrainBridgeAdapter`** for a one-call deposit UX (`BRAIN_NFT_L2` = the L2
   `BrainNFTL2`, `L1_NFT_BRIDGE` = Ink's L1ERC721Bridge), and authorize it as an additional endpoint
   via `BrainNFT.setBridgeEndpoint(<adapter>, true)`. Users may instead approve the L1ERC721Bridge
   directly and call `bridgeERC721To(BrainNFT, BrainNFTL2, to, tokenId, minGas, "")`.
3. **L2 minter:** already fixed at construction to the `L2ERC721Bridge` predeploy — nothing to grant.

#### Ink bridge contract addresses (from docs.inkonchain.com)

| Contract | Ethereum mainnet | Sepolia testnet |
|----------|------------------|-----------------|
| `L1ERC721Bridge` | `0x661235a238b11191211fa95d4dd9e423d521e0be` | `0xd1c901bbd7796546a7ba2492e0e199911fae68c7` |
| `L1StandardBridge` | `0x88FF1e5b602916615391F55854588EFcBB7663f0` | `0x33f60714bbd74d62b66d79213c348614de51901c` |
| `L1CrossDomainMessenger` | `0x69d3cf86b2bf1a9e99875b7e2d9b6a84426c171f` | `0x9fe1d3523f5342535e6e7770ed09ed85dbc1acc2` |
| `L2ERC721Bridge` (predeploy) | `0x4200000000000000000000000000000000000014` | same |

The `IL1ERC721Bridge.bridgeERC721To` ABI in `BrainBridgeAdapter` is the real OP Stack interface (no
longer a placeholder), matching Ink's deployed L1ERC721Bridge.

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
- [ ] `BrainNFTL2.bridge()` equals Ink's canonical `L2ERC721Bridge` predeploy
- [ ] `BrainNFTL2.remoteToken()` equals the deployed L1 `BrainNFT`
- [ ] L1 `BrainNFT.bridge()` equals Ink's canonical `L1ERC721Bridge`
- [ ] Optional `BrainBridgeAdapter` is authorized via `BrainNFT.setBridgeEndpoint(adapter, true)`
- [ ] Admin Brain IDs (0–6) staked and minted to operator multisig
- [ ] Subgraph or indexer running for miner/validator discovery
- [ ] Gateway service running for HTTP miner discovery/proxy
- [ ] Gateway configured with `GATEWAY_SCORING_REGISTRY` and durable `GATEWAY_CURSOR_FILE`
- [ ] Aggregator running via `basedai-validator aggregator --config <config>`
- [ ] Deployment manifest generated with `python scripts/generate_deployment_manifest.py`
- [ ] Documentation links updated with mainnet addresses
- [ ] Reference miner and validator deployed for at least one reference Brain
- [ ] Bug bounty live on Immunefi

## Upgrade strategy

Contracts are deployed as non-upgradable in v1. Upgrades happen by:

1. Deploying new contract versions
2. Migrating state where necessary
3. Updating the bridge configuration if the L2 representation changes

This is intentional: upgradability is the most common cause of "trustless" protocols turning out to be trusted. v1 ships immutable.
