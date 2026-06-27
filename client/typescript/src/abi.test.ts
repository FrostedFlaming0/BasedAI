import { describe, it, expect } from "vitest";
import { getAbiItem, type AbiFunction } from "viem";
import { basedTokenAbi, marketAbi, subnetRegistryAbi } from "./abi.js";

describe("basedTokenAbi", () => {
  it("exposes approve(address,uint256) -> bool", () => {
    const fn = getAbiItem({ abi: basedTokenAbi, name: "approve" }) as AbiFunction;
    expect(fn.inputs.map((i) => i.type)).toEqual(["address", "uint256"]);
    expect(fn.outputs.map((o) => o.type)).toEqual(["bool"]);
  });

  it("exposes balanceOf as a view function", () => {
    const fn = getAbiItem({ abi: basedTokenAbi, name: "balanceOf" }) as AbiFunction;
    expect(fn.stateMutability).toBe("view");
    expect(fn.outputs.map((o) => o.type)).toEqual(["uint256"]);
  });
});

describe("marketAbi", () => {
  it("declares deposit and withdraw taking a single uint256 amount", () => {
    for (const name of ["deposit", "withdraw"] as const) {
      const fn = getAbiItem({ abi: marketAbi, name }) as AbiFunction;
      expect(fn.stateMutability).toBe("nonpayable");
      expect(fn.inputs.map((i) => i.type)).toEqual(["uint256"]);
    }
  });

  it("declares balances(address) -> uint256 view", () => {
    const fn = getAbiItem({ abi: marketAbi, name: "balances" }) as AbiFunction;
    expect(fn.stateMutability).toBe("view");
    expect(fn.inputs.map((i) => i.type)).toEqual(["address"]);
    expect(fn.outputs.map((o) => o.type)).toEqual(["uint256"]);
  });
});

describe("subnetRegistryAbi", () => {
  it("returns a Subnet tuple from getSubnet matching the on-chain struct", () => {
    const fn = getAbiItem({ abi: subnetRegistryAbi, name: "getSubnet" }) as AbiFunction;
    const tuple = fn.outputs[0] as unknown as {
      type: string;
      components: readonly { name?: string; type: string }[];
    };
    expect(tuple.type).toBe("tuple");
    expect(tuple.components.map((c) => c.name)).toEqual([
      "owner",
      "modelHash",
      "modelURI",
      "registrationFee",
      "ownerSplitBps",
      "minerShareBps",
      "createdAt",
      "active",
    ]);
  });
});
