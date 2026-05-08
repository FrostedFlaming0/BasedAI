import type { Address, Hex } from "viem";

export interface ClientConfig {
  rpcUrl: string;
  chainId: number;
  contracts: {
    based: Address;
    subnetRegistry: Address;
    market: Address;
  };
  /** HTTP gateway used to relay inference requests to miners. */
  gatewayUrl: string;
  /** Optional: inject a private key for signing. Otherwise wallet-driven. */
  privateKey?: Hex;
}

export interface InferenceRequest {
  brainId: number;
  prompt: string;
  maxTokens?: number;
  temperature?: number;
  /** Maximum BASED budget for this request, in wei. */
  budget: bigint;
  /** Receipt expiry, unix seconds. Defaults to now + 1h. */
  expiry?: number;
}

export interface InferenceResponse {
  text: string;
  miner: Address;
  promptHash: Hex;
  responseHash: Hex;
  tokensIn: number;
  tokensOut: number;
  amount: bigint;
  minerSignature: Hex;
}

export interface Receipt {
  user: Address;
  miner: Address;
  brainId: number;
  promptHash: Hex;
  responseHash: Hex;
  amount: bigint;
  expiry: number;
  nonce: bigint;
}

export interface Miner {
  address: Address;
  brainId: number;
  /** P2P multiaddr or gateway URL for direct connections. */
  endpoint?: string;
  /** Last-known score from the most recent finalized epoch. */
  score?: number;
}
