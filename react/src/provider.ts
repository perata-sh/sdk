"use client";

import { loadPerata, type ConfirmPaymentParams, type InstallmentOption, type LoadPerataOptions, type PaymentResult, type PerataInstance } from "@perata-sh/js";
import { createContext, createElement, useCallback, useContext, useEffect, useMemo, useState, type ReactElement, type ReactNode } from "react";

/** `loading` until Peráta.js is on the page, `ready` after, `error` when it could not be loaded. */
export type PerataStatus = "loading" | "ready" | "error";

export interface PerataContextValue {
  perata: PerataInstance | null;
  status: PerataStatus;
  error: Error | null;
}

const PerataContext = createContext<PerataContextValue | undefined>(undefined);

export interface PerataProviderProps extends LoadPerataOptions {
  /**
   * An instance (or a promise of one, from `loadPerata()`) you already have,
   * to share it with code outside React or to give tests a stand-in. When
   * given, nothing is loaded here.
   */
  instance?: PerataInstance | Promise<PerataInstance | null> | null;
  children?: ReactNode;
}

function isPromise(value: unknown): value is Promise<PerataInstance | null> {
  return typeof value === "object" && value !== null && typeof (value as { then?: unknown }).then === "function";
}

function initialState(instance: PerataProviderProps["instance"]): PerataContextValue {
  if (instance && !isPromise(instance)) return { perata: instance, status: "ready", error: null };
  return { perata: null, status: "loading", error: null };
}

/**
 * Loads Peráta.js and shares the instance with the components below. It does
 * nothing on the server: the script is requested in an effect, so the page
 * renders in Next.js and other SSR with no `window`.
 */
export function PerataProvider(props: PerataProviderProps): ReactElement {
  const { instance, scriptUrl, nonce, timeoutMs, children } = props;
  const [state, setState] = useState<PerataContextValue>(() => initialState(instance));

  useEffect(() => {
    let active = true;
    const loading: Promise<PerataInstance | null> =
      instance === undefined
        ? loadPerata({
            ...(scriptUrl !== undefined && { scriptUrl }),
            ...(nonce !== undefined && { nonce }),
            ...(timeoutMs !== undefined && { timeoutMs }),
          })
        : Promise.resolve(instance);
    loading.then(
      (perata) => {
        if (!active) return;
        setState((current) => (current.perata === perata && current.status === "ready" ? current : perata ? { perata, status: "ready", error: null } : { perata: null, status: "error", error: new Error("perata: Peráta.js is not available here") }));
      },
      (error: unknown) => {
        if (active) setState({ perata: null, status: "error", error: error instanceof Error ? error : new Error(String(error)) });
      },
    );
    return () => {
      active = false;
    };
  }, [instance, scriptUrl, nonce, timeoutMs]);

  return createElement(PerataContext.Provider, { value: state }, children);
}

/** The context, for the package's own components. */
export function usePerataContext(): PerataContextValue {
  const value = useContext(PerataContext);
  if (value === undefined) throw new Error("perata: this hook or component must be used inside <PerataProvider>");
  return value;
}

/** The Peráta.js instance, or `null` while it loads (and on the server). */
export function usePerata(): PerataInstance | null {
  return usePerataContext().perata;
}

/** Whether Peráta.js is loading, ready or failed, and why. */
export function usePerataStatus(): { status: PerataStatus; error: Error | null } {
  const { status, error } = usePerataContext();
  return useMemo(() => ({ status, error }), [status, error]);
}

/**
 * `confirmPayment` and `getInstallments` bound to the provider's instance, for
 * a custom form (Pix and boleto need no card field). They reject until
 * Peráta.js is ready.
 */
export function useConfirmPayment(): {
  confirmPayment: (params: ConfirmPaymentParams) => Promise<PaymentResult>;
  getInstallments: (params: { clientSecret: string }) => Promise<InstallmentOption[]>;
} {
  const perata = usePerata();
  const confirmPayment = useCallback(
    (params: ConfirmPaymentParams) => (perata ? perata.confirmPayment(params) : Promise.reject(new Error("perata: Peráta.js is not loaded yet"))),
    [perata],
  );
  const getInstallments = useCallback(
    (params: { clientSecret: string }) => (perata ? perata.getInstallments(params) : Promise.reject(new Error("perata: Peráta.js is not loaded yet"))),
    [perata],
  );
  return useMemo(() => ({ confirmPayment, getInstallments }), [confirmPayment, getInstallments]);
}
