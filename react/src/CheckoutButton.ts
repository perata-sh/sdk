"use client";

import type { CheckoutSuccessEvent, Theme } from "@perata-sh/js";
import { createElement, type ComponentPropsWithoutRef, type MouseEvent, type ReactElement } from "react";

import { usePerataContext } from "./provider.ts";

export interface CheckoutButtonProps extends Omit<ComponentPropsWithoutRef<"button">, "type" | "onError"> {
  /** The checkout's `url`, as the API returns it. */
  url: string;
  /** `redirect` (default) sends the page to the hosted checkout; `modal` opens it over your page. */
  mode?: "modal" | "redirect";
  /** The look of the modal; ignored by `redirect`. */
  theme?: Theme;
  /** `modal` only: the payment went through. Return `false` to send the buyer to `successURL` yourself. */
  onSuccess?: (event: CheckoutSuccessEvent) => void | boolean;
  /** `modal` only: the buyer closed the modal. */
  onClose?: () => void;
  /** The `url` is not a checkout link of Peráta, or the modal could not be opened. */
  onError?: (error: Error) => void;
}

/**
 * A button that takes the buyer to the hosted checkout. It stays disabled
 * until Peráta.js has loaded.
 */
export function CheckoutButton(props: CheckoutButtonProps): ReactElement {
  const { url, mode = "redirect", theme, onSuccess, onClose, onError, onClick, disabled, children, ...rest } = props;
  const { perata } = usePerataContext();

  const handleClick = (event: MouseEvent<HTMLButtonElement>): void => {
    onClick?.(event);
    if (event.defaultPrevented || !perata) return;
    const fail = (error: unknown): void => {
      if (onError) onError(error instanceof Error ? error : new Error(String(error)));
      else throw error;
    };
    try {
      if (mode === "modal") {
        perata
          .openCheckout({
            url,
            ...(theme !== undefined && { theme }),
            ...(onSuccess !== undefined && { onSuccess }),
            ...(onClose !== undefined && { onClose }),
          })
          .catch(fail);
      } else {
        perata.redirectToCheckout({ url });
      }
    } catch (error) {
      fail(error);
    }
  };

  return createElement("button", { ...rest, type: "button", disabled: disabled || !perata, onClick: handleClick }, children ?? "Pagar");
}
