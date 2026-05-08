/**
 * BasedAI TypeScript client.
 *
 * Two layers:
 *  - On-chain: read subnet state, manage BASED spending account.
 *  - Off-chain: submit prompts to miners over libp2p (or HTTP gateway).
 *
 * v1 ships an HTTP gateway adapter; native libp2p in browsers is non-trivial.
 */

export { BasedClient } from "./client.js";
export type { ClientConfig, InferenceRequest, InferenceResponse, Receipt } from "./types.js";
export { signReceipt } from "./receipt.js";
