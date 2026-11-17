"use client";

import type { Appearance, ChangeEvent, CustomerInput, Locale, PaymentResult, PerataErrorInfo, WalletComponent as PerataWalletComponent } from "@perata-sh/js";
import { createElement, forwardRef, useEffect, useImperativeHandle, useRef, type ReactElement, type Ref } from "react";

import { useLatest } from "./latest.ts";
import { usePerataContext } from "./provider.ts";

export interface WalletComponentProps {
  /** The session's `client_secret`, created on your server. A new one remounts the component. */
  clientSecret: string;
  /** Who pays, when the session does not know yet; a change is sent to the mounted component without remounting it. */
  customer?: CustomerInput;
  appearance?: Appearance;
  locale?: Locale;
  /** The frame knows which wallets this browser can pay with: `state.available`, empty when none, and then nothing is drawn. */
  onReady?: (state: ChangeEvent) => void;
  /** The wallet paid (`result.status` is `succeeded` or `confirmed`). */
  onSuccess?: (result: PaymentResult) => void;
  /** The buyer closed the wallet's sheet without paying. */
  onCancel?: (state: ChangeEvent) => void;
  onError?: (error: PerataErrorInfo) => void;
  className?: string;
  id?: string;
}

/** What a `ref` on `<WalletComponent>` gives you. */
export interface WalletComponentHandle {
  /** The mounted component; `null` until it is drawn. */
  readonly component: PerataWalletComponent | null;
  /** The wallets available now, `[]` until the frame says; `null` until the component is drawn. */
  getState(): ChangeEvent | null;
}

function WalletComponentImpl(props: WalletComponentProps, ref: Ref<WalletComponentHandle>): ReactElement {
  const { clientSecret, locale, appearance, customer, className, id } = props;
  const { perata } = usePerataContext();
  const target = useRef<HTMLDivElement>(null);
  const component = useRef<PerataWalletComponent | null>(null);
  const applied = useRef<string>("");
  const latest = useLatest(props);
  const lookKey = JSON.stringify([appearance ?? null, customer ?? null]);

  useEffect(() => {
    const element = target.current;
    if (!perata || !element) return;
    const created = perata.components.wallet({
      clientSecret,
      ...(latest.current.customer !== undefined && { customer: latest.current.customer }),
      ...(latest.current.appearance !== undefined && { appearance: latest.current.appearance }),
      ...(locale !== undefined && { locale }),
      onReady: (state) => latest.current.onReady?.(state),
      onSuccess: (result) => latest.current.onSuccess?.(result),
      onCancel: (state) => latest.current.onCancel?.(state),
      onError: (error) => latest.current.onError?.(error),
    });
    created.mount(element);
    component.current = created;
    applied.current = JSON.stringify([latest.current.appearance ?? null, latest.current.customer ?? null]);
    return () => {
      created.destroy();
      component.current = null;
    };
  }, [perata, clientSecret, locale, latest]);

  useEffect(() => {
    if (!component.current || applied.current === lookKey) return;
    applied.current = lookKey;
    component.current.update({ appearance: appearance ?? {}, ...(customer !== undefined && { customer }) });
  }, [lookKey, appearance, customer]);

  useImperativeHandle(
    ref,
    () => ({
      get component() {
        return component.current;
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
 * The wallets' buttons (Google Pay, Apple Pay) for your own layout: drawn only
 * where the browser can pay with a wallet, in a frame of Peráta's origin, and
 * paying by themselves. It draws nothing until Peráta.js has loaded.
 */
export const WalletComponent = forwardRef<WalletComponentHandle, WalletComponentProps>(WalletComponentImpl);
WalletComponent.displayName = "WalletComponent";
