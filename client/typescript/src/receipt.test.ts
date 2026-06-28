import { describe, it, expect } from "vitest";
import { getAddress, type Hex } from "viem";
import { receiptDigest, newNonce } from "./receipt.js";
import type { Receipt } from "./types.js";
import { assertFinalReceiptIdentity } from "./client.js";

const MARKET = getAddress("0x3333333333333333333333333333333333333333");
const CHAIN_ID = 763373;

function fixtureReceipt(): Receipt {
  return {
    user: getAddress("0x1111111111111111111111111111111111111111"),
    miner: getAddress("0x2222222222222222222222222222222222222222"),
    brainId: 7,
    promptHash: ("0x" + "aa".repeat(32)) as Hex,
    responseHash: ("0x" + "bb".repeat(32)) as Hex,
    amount: 1_000_000_000_000_000_000n,
    expiry: 1893456000,
    nonce: 42n,
  };
}

describe("receiptDigest", () => {
  // Golden vector derived independently from viem's abi.encode + keccak256,
  // mirroring ComputeUnitMarket.redeem. Guards the field order and ABI types
  // against accidental drift from the on-chain digest.
  it("matches the on-chain digest golden vector", () => {
    const digest = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    expect(digest).toBe(
      "0xb62ff1422902bee388e9860d6cdeb2b7436eabbe933a4ee24ba5edba86e84fb7",
    );
  });

  it("returns a 32-byte hex string", () => {
    const digest = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    expect(digest).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("is deterministic for identical inputs", () => {
    const a = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    const b = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    expect(a).toBe(b);
  });

  it("changes when the nonce changes", () => {
    const base = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    const bumped = receiptDigest(MARKET, CHAIN_ID, {
      ...fixtureReceipt(),
      nonce: 43n,
    });
    expect(bumped).not.toBe(base);
  });

  it("changes when the amount changes", () => {
    const base = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    const bumped = receiptDigest(MARKET, CHAIN_ID, {
      ...fixtureReceipt(),
      amount: 1_000_000_000_000_000_001n,
    });
    expect(bumped).not.toBe(base);
  });

  it("changes when the chain id changes (replay protection)", () => {
    const base = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    const other = receiptDigest(MARKET, CHAIN_ID + 1, fixtureReceipt());
    expect(other).not.toBe(base);
  });

  it("changes when the market address changes (domain separation)", () => {
    const base = receiptDigest(MARKET, CHAIN_ID, fixtureReceipt());
    const other = receiptDigest(
      getAddress("0x4444444444444444444444444444444444444444"),
      CHAIN_ID,
      fixtureReceipt(),
    );
    expect(other).not.toBe(base);
  });
});

describe("newNonce", () => {
  it("returns a bigint within the uint64 range", () => {
    for (let i = 0; i < 256; i++) {
      const n = newNonce();
      expect(typeof n).toBe("bigint");
      expect(n).toBeGreaterThanOrEqual(0n);
      expect(n).toBeLessThan(1n << 64n);
    }
  });

  it("produces distinct values across many calls", () => {
    const seen = new Set<bigint>();
    for (let i = 0; i < 1000; i++) seen.add(newNonce());
    // Collisions in 1000 draws from 2^64 are astronomically unlikely.
    expect(seen.size).toBe(1000);
  });
});

describe("final receipt binding", () => {
  it("allows only response hash and amount to change", () => {
    const preauth = fixtureReceipt();
    const final = {
      ...preauth,
      responseHash: ("0x" + "cc".repeat(32)) as Hex,
      amount: 123n,
    };
    expect(() => assertFinalReceiptIdentity(preauth, final)).not.toThrow();
    expect(() => assertFinalReceiptIdentity(preauth, { ...final, nonce: 43n })).toThrow(/identity/);
  });
});
