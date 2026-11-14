"use client";

import type { Appearance, CardComponent, ChangeEvent, ConfirmPaymentParams, InstallmentOption, PaymentResult, PerataErrorInfo } from "@perata-sh/js";
import { createElement, forwardRef, useEffect, useImperativeHandle, useRef, type ReactElement, type Ref } from "react";

import { useLatest } from "./latest.ts";
import { usePerataContext } from "./provider.ts";

export interface CardFieldProps {
  /** The session's `client_secret`, created on your server. A new one remounts the field. */
  clientSecret: string;
  appearance?: Appearance;
  onReady?: (state: ChangeEvent) => void;
  onChange?: (event: ChangeEvent) => void;
  onError?: (error: PerataErrorInfo) => void;
  className?: string;
  id?: string;
}

/** What a `ref` on `<CardField>` gives you. */
export interface CardFieldHandle {
  /** The mounted card component, to pass as `card` to `perata.confirmPayment`; `null` until it is drawn. */
  readonly component: CardComponent | null;
  /** Charges the card. The same as `perata.confirmPayment({ clientSecret, card, method: "card", ... })`. */
  confirmPayment(params?: Omit<ConfirmPaymentParams, "clientSecret" | "card">): Promise<PaymentResult>;
  /** The ways this payment can be split. */
  getInstallments(): Promise<InstallmentOption[]>;
  /** Puts the cursor in the card number. */
  focus(): void;
  /** What the buyer may see of the card so far; `null` until the field is drawn. */
  getState(): ChangeEvent | null;
}

function CardFieldImpl(props: CardFieldProps, ref: Ref<CardFieldHandle>): ReactElement {
  const { clientSecret, appearance, className, id } = props;
  const { perata } = usePerataContext();
  const target = useRef<HTMLDivElement>(null);
  const component = useRef<CardComponent | null>(null);
  const applied = useRef<string>("");
  const latest = useLatest(props);
  const appearanceKey = JSON.stringify(appearance ?? null);

  useEffect(() => {
    const element = target.current;
    if (!perata || !element) return;
    const created = perata.components.card({
      clientSecret,
      ...(latest.current.appearance !== undefined && { appearance: latest.current.appearance }),
      onChange: (event) => latest.current.onChange?.(event),
    });
    created.on("ready", (state) => latest.current.onReady?.(state));
    created.on("error", (error) => latest.current.onError?.(error));
    created.mount(element);
    component.current = created;
    applied.current = JSON.stringify(latest.current.appearance ?? null);
    return () => {
      created.destroy();
      component.current = null;
    };
  }, [perata, clientSecret, latest]);

  useEffect(() => {
    if (!component.current || applied.current === appearanceKey) return;
    applied.current = appearanceKey;
    component.current.update({ appearance: appearance ?? {} });
  }, [appearanceKey, appearance]);

  useImperativeHandle(
    ref,
    () => ({
      get component() {
        return component.current;
      },
      confirmPayment(params = {}) {
        if (!perata) return Promise.reject(new Error("perata: Peráta.js is not loaded yet"));
        const card = component.current;
        if (!card) return Promise.reject(new Error("perata: the card field is not mounted yet"));
        return perata.confirmPayment({ method: "card", ...params, clientSecret, card });
      },
      getInstallments() {
        if (!perata) return Promise.reject(new Error("perata: Peráta.js is not loaded yet"));
        return perata.getInstallments({ clientSecret });
      },
      focus() {
        component.current?.focus();
      },
      getState() {
        return component.current ? component.current.getState() : null;
      },
    }),
    [perata, clientSecret],
  );

  return createElement("div", { ref: target, className, id });
}

/**
 * The card number, expiry and CVC, drawn by Peráta in a secure frame: the
 * numbers never reach your page. Put a `ref` on it and call
 * `ref.current.confirmPayment()` when the buyer submits.
 */
export const CardField = forwardRef<CardFieldHandle, CardFieldProps>(CardFieldImpl);
CardField.displayName = "CardField";
