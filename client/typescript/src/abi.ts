/**
 * Minimal ABIs the client needs. Full ABIs are exported separately for tools that want them.
 */

export const basedTokenAbi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const marketAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
  },
  // Two-step withdrawal: requestWithdraw(amount) starts the delay, withdraw() (no args) completes it.
  {
    type: "function",
    name: "requestWithdraw",
    stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "balances",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  // Metered pricing — read so the client derives the charge independently of the miner.
  {
    type: "function",
    name: "pricePerByte",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "pricePerRequest",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const subnetRegistryAbi = [
  {
    type: "function",
    name: "getSubnet",
    stateMutability: "view",
    inputs: [{ name: "brainId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "modelHash", type: "bytes32" },
          { name: "modelURI", type: "string" },
          { name: "registrationFee", type: "uint256" },
          { name: "ownerSplitBps", type: "uint16" },
          { name: "minerShareBps", type: "uint16" },
          { name: "createdAt", type: "uint64" },
          { name: "active", type: "bool" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "minerCount",
    stateMutability: "view",
    inputs: [{ name: "brainId", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
] as const;
