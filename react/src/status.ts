"use client";

import { isFinalStatus, type PaymentResult } from "@perata-sh/js";
import { useCallback, useEffect, useRef, useState } from "react";

import { useLatest } from "./latest.ts";
import { usePerataContext } from "./provider.ts";

export interface UsePaymentStatusOptions {
  /** The `statusKey` of a `PaymentResult`. Nothing is asked while it is empty. */
  statusKey: string | null | undefined;
  /**
   * Milliseconds between asks. Without it the status is read once (and again on
   * `refresh()`); with it the hook asks again until the status is final
   * (`succeeded`, `failed`, `expired`), which is how a Pix or a boleto is followed.
   */
  intervalMs?: number;
  /** `false` pauses everything; `true` by default. */
  enabled?: boolean;
  /** Called with every answer. */
  onResult?: (result: PaymentResult) => void;
}

export interface PaymentStatusState {
  /** The latest answer; `null` before the first. */
  result: PaymentResult | null;
  /** The latest failure to ask; cleared by the next answer. */
  error: Error | null;
  /** True from the moment an ask leaves until it is answered. */
  loading: boolean;
  /** True once the status can no longer change. */
  done: boolean;
  /** Asks now; resolves with the answer, or `null` when it could not be asked. */
  refresh: () => Promise<PaymentResult | null>;
}

// An answer that will not get better by asking again: stop polling on it.
function permanent(error: unknown): boolean {
  const code = typeof error === "object" && error !== null ? String((error as { code?: unknown }).code ?? "") : "";
  return code === "invalid_status_key" || /^http_4\d\d$/.test(code);
}

/**
 * Follows a payment by its `statusKey` after the `clientSecret` is spent: a
 * Pix or a boleto waiting for the buyer. Polls every `intervalMs` until the
 * status is final, and stops when the component leaves the page.
 *
 *     const { result } = usePaymentStatus({ statusKey: paid.statusKey, intervalMs: 3000 });
 */
export function usePaymentStatus(options: UsePaymentStatusOptions): PaymentStatusState {
  const { statusKey, intervalMs, enabled = true } = options;
  const { perata } = usePerataContext();
  const latest = useLatest(options);
  const [state, setState] = useState<{ result: PaymentResult | null; error: Error | null; loading: boolean }>({ result: null, error: null, loading: false });
  const alive = useRef(0);

  const ask = useCallback(
    async (generation: number): Promise<{ result: PaymentResult | null; stop: boolean }> => {
      if (!perata || !statusKey) return { result: null, stop: true };
      setState((current) => (current.loading ? current : { ...current, loading: true }));
      try {
        const result = await perata.getStatus({ statusKey });
        if (generation !== alive.current) return { result: null, stop: true };
        setState({ result, error: null, loading: false });
        latest.current.onResult?.(result);
        return { result, stop: isFinalStatus(result.status) };
      } catch (caught) {
        if (generation !== alive.current) return { result: null, stop: true };
        setState((current) => ({ ...current, error: caught instanceof Error ? caught : new Error(String(caught)), loading: false }));
        return { result: null, stop: permanent(caught) };
      }
    },
    [perata, statusKey, latest],
  );

  useEffect(() => {
    if (!enabled || !perata || !statusKey) return;
    alive.current += 1;
    const generation = alive.current;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const step = async (): Promise<void> => {
      const { stop } = await ask(generation);
      if (generation !== alive.current || stop || !intervalMs || intervalMs <= 0) return;
      timer = setTimeout(() => void step(), intervalMs);
    };
    void step();
    return () => {
      alive.current += 1;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [enabled, perata, statusKey, intervalMs, ask]);

  const refresh = useCallback(async () => (await ask(alive.current)).result, [ask]);

  return { ...state, done: state.result !== null && isFinalStatus(state.result.status), refresh };
}
