"use client";

import type { Appearance, ChangeEvent, Locale, PaymentComponent as PerataPaymentComponent, PaymentResult, PerataErrorInfo } from "@perata-sh/js";
import { createElement, forwardRef, useEffect, useImperativeHandle, useRef, type ReactElement, type Ref } from "react";

import { useLatest } from "./latest.ts";
import { usePerataContext } from "./provider.ts";

export interface PaymentComponentProps {
  /** The session's `client_secret`, created on your server. A new one remounts the component. */
  clientSecret: string;
  appearance?: Appearance;
  locale?: Locale;
  onReady?: (state: ChangeEvent) => void;
  onChange?: (event: ChangeEvent) => void;
  /** The payment was made (or, for Pix and boleto, the charge was created: look at `result.pix` and `result.boleto`, and follow `result.statusKey` with `usePaymentStatus`). */
  onSuccess?: (result: PaymentResult) => void;
  onError?: (error: PerataErrorInfo) => void;
  className?: string;
  id?: string;
}

/** What a `ref` on `<PaymentComponent>` gives you. */
export interface PaymentComponentHandle {
  /** The mounted component, to pass as `payment` to `perata.confirmPayment`; `null` until it is drawn. */
  readonly component: PerataPaymentComponent | null;
  /** Puts the cursor in the first field. */
  focus(): void;
  /** What the buyer may see of the fields now; `null` until the component is drawn. */
  getState(): ChangeEvent | null;
}

function PaymentComponentImpl(props: PaymentComponentProps, ref: Ref<PaymentComponentHandle>): ReactElement {
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
      onReady: (state) => latest.current.onReady?.(state),
      onChange: (event) => latest.current.onChange?.(event),
      onSuccess: (result) => latest.current.onSuccess?.(result),
      onError: (error) => latest.current.onError?.(error),
    });
    created.mount(element);
    component.current = created;
    applied.current = JSON.stringify(latest.current.appearance ?? null);
    return () => {
      created.destroy();
      component.current = null;
    };
  }, [perata, clientSecret, locale, latest]);

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
      focus() {
        component.current?.focus();
      },
      getState() {
        return component.current ? component.current.getState() : null;
      },
    }),
    [],
  );

  return createElement("div", { ref: target, className, id });
}

/**
 * Peráta's ready-made payment form: methods, card, Pix and boleto, with its
 * own button, confirming by itself. It draws nothing until Peráta.js has loaded.
 */
export const PaymentComponent = forwardRef<PaymentComponentHandle, PaymentComponentProps>(PaymentComponentImpl);
PaymentComponent.displayName = "PaymentComponent";
