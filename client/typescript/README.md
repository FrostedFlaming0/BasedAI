# @basedai/client

TypeScript client for BasedAI.

## Install

```bash
npm install @basedai/client viem
```

## Usage

```typescript
import { BasedClient } from "@basedai/client";

const client = new BasedClient({
  rpcUrl: "https://rpc-gel.inkonchain.com",
  chainId: 57073,
  contracts: {
    based: "0x...",
    subnetRegistry: "0x...",
    market: "0x...",
  },
  gatewayUrl: "https://gateway.basedai.network",
  privateKey: process.env.PRIVATE_KEY as `0x${string}`,
});

// Top up your spending account
await client.deposit(10n * 10n ** 18n); // 10 BASED

// Run inference
const result = await client.infer({
  brainId: 8,
  prompt: "Why is the sky blue?",
  maxTokens: 256,
  budget: 1n * 10n ** 17n, // 0.1 BASED max
});

console.log(result.text);
```

## Notes

- This client uses a gateway service to relay prompts to miners over P2P. Browsers can't easily speak libp2p directly; for Node.js workloads that want native P2P, use the Python client or run a local gateway.
- All amounts are in `bigint` wei (18 decimals). Use `parseEther` from viem for conversions.
- The `infer()` call signs an upper-bound receipt for `budget`; the miner only redeems for the actual cost.
