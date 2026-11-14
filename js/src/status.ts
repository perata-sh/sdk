import type { PaymentStatus } from "./types.ts";

/**
 * True when a status will not change any more (`succeeded`, `failed`,
 * `expired`): stop following the session. `open` and `confirmed` still can.
 */
export function isFinalStatus(status: PaymentStatus): boolean {
  return status === "succeeded" || status === "failed" || status === "expired";
}
