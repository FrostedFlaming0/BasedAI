# Getting Started

Three roles can participate: **Brain owner**, **miner**, **validator**. This guide covers all three plus running a local devnet.

## Prerequisites

- Foundry (for contracts): `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- Node.js 18+ (for the TypeScript client)
- Python 3.10+ (for miner, validator, and Python client)
- An RPC endpoint for Ink (mainnet or Sepolia)
- Either Pepecoin or $basedAI on Ethereum mainnet (to acquire a Brain) — testnet equivalents are deployed for Sepolia

## Local devnet

```bash
# Start a local Ink-like fork
anvil --fork-url $INK_SEPOLIA_RPC --port 8545 &

# Deploy contracts (requires BASEDAI_L2 — use a mock or the bridged address)
cd contracts
DEPLOYER_PRIVATE_KEY=0xac0974... \
BASEDAI_L2=0x... \
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

The deploy script prints all contract addresses. Save them for the configs below.

## Becoming a Brain owner

1. Acquire either Pepecoin (for Pepecoin-stake mint) or $basedAI (for basedAI-stake mint) on Ethereum mainnet.
2. Approve the `BrainNFT` contract to spend your stake amount.
3. Call `BrainNFT.mintByPepecoinStake()` or `mintByBasedStake()`. The Brain NFT is minted to your address.
4. Bridge the NFT to Ink via the canonical bridge.
5. Call `SubnetRegistry.activate(brainId, modelHash, modelURI)` on Ink, where `modelURI` points to a HuggingFace model spec.
6. (Optional) Adjust `setRegistrationFee()` and `setEmissionSplit()` to attract miners and validators.

To recover your stake, wait 90 days, then call `BrainNFT.deactivateAndUnstake(brainId)`. The stake is returned and the NFT is burned.

## Running a miner

```bash
cd miner
pip install -e .

# Configure
cp config.example.yaml config.yaml
# Edit config.yaml: set chain addresses, brain_id, wallet private key, model

# Register and run
basedai-miner register --config config.yaml
basedai-miner run --config config.yaml
```

The miner will:

- Auto-register on the configured Brain (paying the registration fee in $basedAI; the fee is burned).
- Subscribe to the Brain's gossip topic on libp2p.
- Serve inference requests and accumulate signed receipts.
- Batch-submit receipts every 5 minutes (configurable).

GPU is required for production inference. Llama-3-8B fits on a single 24GB consumer GPU (RTX 4090, A6000) with AWQ quantization.

## Running a validator

```bash
cd validator
pip install -e .

cp config.example.yaml config.yaml
# Edit config.yaml: set chain addresses, brain_id, wallet private key, eval_set_path

basedai-validator run --config config.yaml
```

The validator will:

- Auto-register on the configured Brain.
- Issue periodic challenge prompts to miners.
- Score miners on latency, quality (vs. eval set), and consistency (vs. mode).
- At each epoch boundary, sign a Merkle root and submit it to the aggregator.

CPU is sufficient for validation. The eval set is a JSON file of `{"prompt": "...", "reference": "..."}` pairs.

## Using the network as a user

```typescript
import { BasedClient } from "@basedai/client";
import { parseEther } from "viem";

const client = new BasedClient({
  rpcUrl: "https://rpc-gel.inkonchain.com",
  chainId: 57073,
  contracts: {
    based: "0x...",                 // bridged $basedAI on Ink
    subnetRegistry: "0x...",
    market: "0x...",
  },
  gatewayUrl: "https://gateway.basedai.network",
  privateKey: process.env.PRIVATE_KEY,
});

await client.deposit(parseEther("10"));        // 10 basedAI into spending account
const result = await client.infer({
  brainId: 8,
  prompt: "Why is the sky blue?",
  budget: parseEther("0.1"),                    // up to 0.1 basedAI for this prompt
});
console.log(result.text);
```

Python equivalent:

```python
from basedai_client import BasedClient, ClientConfig, InferenceRequest

client = BasedClient(ClientConfig(
    rpc_url="https://rpc-gel.inkonchain.com",
    chain_id=57073,
    based="0x...",
    subnet_registry="0x...",
    market="0x...",
    gateway_url="https://gateway.basedai.network",
    private_key=os.environ["PRIVATE_KEY"],
))

client.deposit(10 * 10**18)
result = client.infer(InferenceRequest(
    brain_id=8,
    prompt="Why is the sky blue?",
    budget=10**17,
))
print(result.text)
```

## Common issues

**"No miners available for brain N"** — Either the Brain hasn't been activated, no miners have registered, or the gateway hasn't indexed them yet. Check `SubnetRegistry.minerCount(brainId)`.

**"InsufficientBalance" on infer** — Your spending account is empty. Deposit more $basedAI via `client.deposit()`.

**"NotBrainOwner" on activate** — The L2 representation NFT for this Brain ID isn't held by your address. Check that the bridge transfer completed.

**"StakeLockNotElapsed" on deactivate** — The 90-day initial lock hasn't elapsed yet. Brain stake is locked for 90 days from minting.

**"TransferRestricted" on transfer attempt** — Stake-minted Brains are non-transferable by design in v1. Use `deactivateAndUnstake` to recover the stake instead.

**Receipt redemption failing** — Receipts expire (default 1 hour). If a miner waits too long to batch, redemption fails. The miner's batching interval should be well below the receipt expiry.
