import {
  encodeAbiParameters,
  keccak256,
  toHex,
  type Address,
  type Hex,
  type WalletClient,
} from "viem";
import type { Receipt } from "./types.js";

/**
 * Compute the receipt digest. Mirrors ComputeUnitMarket.redeem on-chain.
 */
export function receiptDigest(
  marketAddress: Address,
  chainId: number,
  r: Receipt,
): Hex {
  const encoded = encodeAbiParameters(
    [
      { type: "address" }, // market
      { type: "uint256" }, // chainId
      { type: "address" }, // user
      { type: "address" }, // miner
      { type: "uint256" }, // brainId
      { type: "bytes32" }, // promptHash
      { type: "bytes32" }, // responseHash
      { type: "uint256" }, // amount
      { type: "uint64" },  // expiry
      { type: "uint256" }, // nonce
    ],
    [
      marketAddress,
      BigInt(chainId),
      r.user,
      r.miner,
      BigInt(r.brainId),
      r.promptHash,
      r.responseHash,
      r.amount,
      BigInt(r.expiry),
      r.nonce,
    ],
  );
  return keccak256(encoded);
}

/**
 * Sign a receipt with the user's wallet. Returns the EIP-191 signature
 * accepted by ComputeUnitMarket.redeem.
 */
export async function signReceipt(
  wallet: WalletClient,
  marketAddress: Address,
  chainId: number,
  r: Receipt,
): Promise<Hex> {
  const digest = receiptDigest(marketAddress, chainId, r);
  if (!wallet.account) throw new Error("Wallet has no account");
  return wallet.signMessage({
    account: wallet.account,
    message: { raw: digest },
  });
}

/**
 * Generate a fresh random nonce for a receipt.
 */
export function newNonce(): bigint {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let n = 0n;
  for (const b of bytes) n = (n << 8n) | BigInt(b);
  return n;
}
