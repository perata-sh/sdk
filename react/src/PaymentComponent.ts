"use client";

import type { Appearance, ChangeEvent, Locale, PaymentComponent as PerataPaymentComponent, PaymentResult, PerataErrorInfo } from "@perata-sh/js";
import { createElement, useEffect, useRef, type ReactElement } from "react";

import { useLatest } from "./latest.ts";
import { usePerataContext } from "./provider.ts";

export interface PaymentComponentProps {
  /** The session's `client_secret`, created on your server. A new one remounts the component. */
  clientSecret: string;
  appearance?: Appearance;
  locale?: Locale;
  onReady?: () => void;
  onChange?: (event: ChangeEvent) => void;
  /** The payment was made (or, for Pix and boleto, the charge was created: look at `result.pix` and `result.boleto`). */
  onSuccess?: (result: PaymentResult) => void;
  onError?: (error: PerataErrorInfo) => void;
  className?: string;
  id?: string;
}

/**
 * Peráta's ready-made payment form: methods, card, Pix and boleto, confirming
 * by itself. It draws nothing until Peráta.js has loaded.
 */
export function PaymentComponent(props: PaymentComponentProps): ReactElement {
  const { clientSecret, locale, appearance, className, id } = props;
  const { perata } = usePerataContext();
  const target = useRef<HTMLDivElement>(null);
  const component = useRef<PerataPaymentComponent | null>(null);
  const applied = useRef<string>("");
  const latest = useLatest(props);
  const appearanceKey = JSON.stringify(appearance ?? null);

  useEffect(() => {
    const element = target.current;
    if (!perata || !element) return;
    const created = perata.components.payment({
      clientSecret,
      ...(latest.current.appearance !== undefined && { appearance: latest.current.appearance }),
      ...(locale !== undefined && { locale }),
      onReady: () => latest.current.onReady?.(),
      onChange: (event) => latest.current.onChange?.(event),
      onSuccess: (result) => latest.current.onSuccess?.(result),
      onError: (error) => latest.current.onError?.(error),
    });
    created.mount(element);
    component.current = created;
    applied.current = JSON.stringify(latest.current.appearance ?? null);
    return () => {
      created.unmount();
      component.current = null;
    };
  }, [perata, clientSecret, locale, latest]);

  useEffect(() => {
    if (!component.current || applied.current === appearanceKey) return;
    applied.current = appearanceKey;
    component.current.update({ appearance: appearance ?? {} });
  }, [appearanceKey, appearance]);

  return createElement("div", { ref: target, className, id });
}
