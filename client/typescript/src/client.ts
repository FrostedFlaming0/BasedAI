import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseAbi,
  toBytes,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { basedTokenAbi, marketAbi, subnetRegistryAbi } from "./abi.js";
import { newNonce, signReceipt } from "./receipt.js";
import type {
  ClientConfig,
  InferenceRequest,
  InferenceResponse,
  Miner,
  Receipt,
} from "./types.js";

export class BasedClient {
  private readonly config: ClientConfig;
  private readonly publicClient: PublicClient;
  private readonly walletClient?: WalletClient;
  private readonly account?: { address: Address };

  constructor(config: ClientConfig) {
    this.config = config;
    this.publicClient = createPublicClient({
      transport: http(config.rpcUrl),
    });
    if (config.privateKey) {
      const account = privateKeyToAccount(config.privateKey);
      this.account = account;
      this.walletClient = createWalletClient({
        account,
        transport: http(config.rpcUrl),
      });
    }
  }

  // --- Account management ---

  async balance(): Promise<bigint> {
    this.requireAccount();
    return this.publicClient.readContract({
      address: this.config.contracts.based,
      abi: basedTokenAbi,
      functionName: "balanceOf",
      args: [this.account!.address],
    }) as Promise<bigint>;
  }

  async spendingBalance(): Promise<bigint> {
    this.requireAccount();
    return this.publicClient.readContract({
      address: this.config.contracts.market,
      abi: marketAbi,
      functionName: "balances",
      args: [this.account!.address],
    }) as Promise<bigint>;
  }

  async deposit(amount: bigint): Promise<Hex> {
    this.requireWallet();
    // Approve, then deposit. v1 keeps these as separate txs for clarity;
    // production paths use ERC-2612 permit() to combine into one.
    const approveHash = await this.walletClient!.writeContract({
      account: this.account!,
      chain: null,
      address: this.config.contracts.based,
      abi: basedTokenAbi,
      functionName: "approve",
      args: [this.config.contracts.market, amount],
    });
    await this.publicClient.waitForTransactionReceipt({ hash: approveHash });

    return this.walletClient!.writeContract({
      account: this.account!,
      chain: null,
      address: this.config.contracts.market,
      abi: marketAbi,
      functionName: "deposit",
      args: [amount],
    });
  }

  async withdraw(amount: bigint): Promise<Hex> {
    this.requireWallet();
    return this.walletClient!.writeContract({
      account: this.account!,
      chain: null,
      address: this.config.contracts.market,
      abi: marketAbi,
      functionName: "withdraw",
      args: [amount],
    });
  }

  // --- Subnet discovery ---

  async getSubnet(brainId: number) {
    return this.publicClient.readContract({
      address: this.config.contracts.subnetRegistry,
      abi: subnetRegistryAbi,
      functionName: "getSubnet",
      args: [BigInt(brainId)],
    });
  }

  async listMiners(brainId: number): Promise<Miner[]> {
    // v1 implementation queries the gateway; production uses an indexer or libp2p discovery.
    const url = `${this.config.gatewayUrl}/brains/${brainId}/miners`;
    const res = await fetch(url);
    if (!res.ok) return [];
    return (await res.json()) as Miner[];
  }

  // --- Inference ---

  async infer(req: InferenceRequest): Promise<InferenceResponse> {
    this.requireWallet();

    const miners = await this.listMiners(req.brainId);
    if (miners.length === 0) {
      throw new Error(`No miners available for brain ${req.brainId}`);
    }
    // Pick highest-scored miner; ties broken by most recent.
    const miner = miners.sort((a, b) => (b.score ?? 0) - (a.score ?? 0))[0];

    const promptHash = keccak256(toBytes(req.prompt));
    const expiry = req.expiry ?? Math.floor(Date.now() / 1000) + 3600;
    const nonce = newNonce();

    // The user signs an upper-bound receipt: maxBudget. The miner only redeems for the
    // actual cost (which must be ≤ budget). v1 simplification: amount in the signed
    // receipt is the maxBudget; on-chain redemption uses min(receipt.amount, balance).
    const receipt: Receipt = {
      user: this.account!.address,
      miner: miner.address,
      brainId: req.brainId,
      promptHash,
      responseHash: ("0x" + "00".repeat(32)) as Hex, // filled by miner
      amount: req.budget,
      expiry,
      nonce,
    };

    const userSig = await signReceipt(
      this.walletClient!,
      this.config.contracts.market,
      this.config.chainId,
      receipt,
    );

    const url = `${this.config.gatewayUrl}/brains/${req.brainId}/infer`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        prompt: req.prompt,
        max_tokens: req.maxTokens ?? 256,
        temperature: req.temperature ?? 0.7,
        receipt: serializeReceipt(receipt),
        user_signature: userSig,
        target_miner: miner.address,
      }),
    });

    if (!res.ok) {
      throw new Error(`Inference failed: ${res.status} ${await res.text()}`);
    }

    const data = (await res.json()) as {
      text: string;
      prompt_hash: Hex;
      response_hash: Hex;
      tokens_in: number;
      tokens_out: number;
      miner_signature: Hex;
    };

    return {
      text: data.text,
      miner: miner.address,
      promptHash: data.prompt_hash,
      responseHash: data.response_hash,
      tokensIn: data.tokens_in,
      tokensOut: data.tokens_out,
      amount: req.budget,
      minerSignature: data.miner_signature,
    };
  }

  // --- Helpers ---

  private requireAccount(): void {
    if (!this.account) throw new Error("Client has no account configured");
  }

  private requireWallet(): void {
    if (!this.walletClient || !this.account) {
      throw new Error("Client requires a private key for write operations");
    }
  }
}

function serializeReceipt(r: Receipt): Record<string, unknown> {
  return {
    user: r.user,
    miner: r.miner,
    brain_id: r.brainId,
    prompt_hash: r.promptHash,
    response_hash: r.responseHash,
    amount: r.amount.toString(),
    expiry: r.expiry,
    nonce: r.nonce.toString(),
  };
}
