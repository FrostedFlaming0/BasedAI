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
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { basedTokenAbi, marketAbi, subnetRegistryAbi } from "./abi.js";
import { newNonce, signReceipt } from "./receipt.js";
import type {
  ClientConfig,
  InferenceRequest,
  InferenceResponse,
  Miner,
  Receipt,
} from "./types.js";

/**
 * Default pre-authorization reservation (the bounded no-delivery fallback) when a request does not
 * set one: 0.01 BASED. Must not exceed the market's on-chain `maxReservation`.
 */
export const DEFAULT_RESERVATION = 10n ** 16n;

export class BasedClient {
  private readonly config: ClientConfig;
  private readonly publicClient: PublicClient;
  private readonly walletClient?: WalletClient;
  private readonly account?: PrivateKeyAccount;

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

  /** Begin a withdrawal (step 1 of 2). Funds remain redeemable by miners during the delay. */
  async requestWithdraw(amount: bigint): Promise<Hex> {
    this.requireWallet();
    return this.walletClient!.writeContract({
      account: this.account!,
      chain: null,
      address: this.config.contracts.market,
      abi: marketAbi,
      functionName: "requestWithdraw",
      args: [amount],
    });
  }

  /** Complete a withdrawal (step 2 of 2) after the delay. Takes no amount: the contract pays out
   *  min(requested, current balance). */
  async withdraw(): Promise<Hex> {
    this.requireWallet();
    return this.walletClient!.writeContract({
      account: this.account!,
      chain: null,
      address: this.config.contracts.market,
      abi: marketAbi,
      functionName: "withdraw",
      args: [],
    });
  }

  /** (pricePerByte, pricePerRequest) from the market. */
  private async readPricing(): Promise<[bigint, bigint]> {
    try {
      const ppt = (await this.publicClient.readContract({
        address: this.config.contracts.market,
        abi: marketAbi,
        functionName: "pricePerByte",
      })) as bigint;
      const ppr = (await this.publicClient.readContract({
        address: this.config.contracts.market,
        abi: marketAbi,
        functionName: "pricePerRequest",
      })) as bigint;
      return [ppt, ppr];
    } catch {
      return [0n, 0n];
    }
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

    // The pre-authorization is only a bounded no-delivery FALLBACK: its amount is capped on-chain
    // at the market's maxReservation, so a miner can never draw the whole budget from a receipt
    // signed before any output exists. Full payment goes through the counter-signed FINAL receipt
    // below (bound to the real responseHash + actual cost), which we sign only after verifying the
    // delivered output. The sentinel must match keccak256(abi.encodePacked(promptHash, nonce)).
    let reservation = req.reservation && req.reservation > 0n ? req.reservation : DEFAULT_RESERVATION;
    if (reservation > req.budget) reservation = req.budget;

    const sentinel = keccak256(
      ("0x" + promptHash.slice(2) + nonce.toString(16).padStart(64, "0")) as Hex,
    );
    const preauth: Receipt = {
      user: this.account!.address,
      miner: miner.address,
      brainId: req.brainId,
      promptHash,
      responseHash: sentinel,
      amount: reservation,
      expiry,
      nonce,
    };

    const preauthSig = await signReceipt(
      this.walletClient!,
      this.config.contracts.market,
      this.config.chainId,
      preauth,
    );

    const url = `${this.config.gatewayUrl}/brains/${req.brainId}/infer`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        prompt: req.prompt,
        max_tokens: req.maxTokens ?? 256,
        temperature: req.temperature ?? 0.7,
        budget: req.budget.toString(),
        receipt: serializeReceipt(preauth),
        user_signature: preauthSig,
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
      final_receipt?: {
        user: Hex; miner: Hex; brain_id: number; prompt_hash: Hex;
        response_hash: Hex; amount: string; expiry: number; nonce: string;
      };
    };

    // Verify the delivered output matches the committed response hash before paying.
    if (keccak256(toBytes(data.text)).toLowerCase() !== data.response_hash.toLowerCase()) {
      throw new Error("response hash does not match returned text");
    }

    // Counter-sign the FINAL receipt (binds delivered output + actual cost) and settle it. Only
    // this receipt — signed after verifying the response — authorizes the full charge.
    let charged = reservation; // what the miner can draw if settlement never happens
    if (data.final_receipt) {
      const fr = data.final_receipt;
      const finalReceipt: Receipt = {
        user: fr.user, miner: fr.miner, brainId: fr.brain_id, promptHash: fr.prompt_hash,
        responseHash: fr.response_hash, amount: BigInt(fr.amount), expiry: fr.expiry, nonce: BigInt(fr.nonce),
      };
      assertFinalReceiptIdentity(preauth, finalReceipt);
      if (finalReceipt.amount > req.budget) throw new Error("final amount exceeds budget");
      // UTF-8 bytes are independently measurable without trusting miner token accounting.
      const [ppt, ppr] = await this.readPricing();
      if (ppt <= 0n && ppr <= 0n) throw new Error("market pricing is disabled");
      const inputBytes = BigInt(new TextEncoder().encode(req.prompt).length);
      const outputBytes = BigInt(new TextEncoder().encode(data.text).length);
      const quoted = ppr + ppt * (inputBytes + outputBytes);
      const expected = quoted < req.budget ? quoted : req.budget;
      if (finalReceipt.amount !== expected) {
        throw new Error(`incorrect metered charge: amount ${finalReceipt.amount}, expected ${expected}`);
      }
      // The final must bind the DELIVERED output, not the pre-auth sentinel.
      if (finalReceipt.responseHash.toLowerCase() !== data.response_hash.toLowerCase()) {
        throw new Error("final receipt response hash does not match delivered text");
      }
      const finalSig = await signReceipt(
        this.walletClient!,
        this.config.contracts.market,
        this.config.chainId,
        finalReceipt,
      );
      charged = finalReceipt.amount;
      try {
        await fetch(`${this.config.gatewayUrl}/brains/${req.brainId}/settle`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ receipt: serializeReceipt(finalReceipt), user_signature: finalSig }),
        });
      } catch {
        // Settlement is best-effort; the signed pre-auth remains the miner's bounded fallback.
      }
    }

    return {
      text: data.text,
      miner: miner.address,
      promptHash: data.prompt_hash,
      responseHash: data.response_hash,
      tokensIn: data.tokens_in,
      tokensOut: data.tokens_out,
      amount: charged,
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

export function assertFinalReceiptIdentity(preauth: Receipt, finalReceipt: Receipt): void {
  if (
    finalReceipt.user.toLowerCase() !== preauth.user.toLowerCase() ||
    finalReceipt.miner.toLowerCase() !== preauth.miner.toLowerCase() ||
    finalReceipt.brainId !== preauth.brainId ||
    finalReceipt.promptHash.toLowerCase() !== preauth.promptHash.toLowerCase() ||
    finalReceipt.expiry !== preauth.expiry ||
    finalReceipt.nonce !== preauth.nonce
  ) {
    throw new Error("final receipt identity does not match preauthorization");
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
