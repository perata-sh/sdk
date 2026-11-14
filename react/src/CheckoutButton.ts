"use client";

import type { CheckoutSuccessEvent, Theme } from "@perata-sh/js";
import { createElement, type ComponentPropsWithoutRef, type MouseEvent, type ReactElement } from "react";

import { usePerataContext } from "./provider.ts";

export interface CheckoutButtonProps extends Omit<ComponentPropsWithoutRef<"button">, "type"> {
  /** The checkout's `url`, as the API returns it. */
  url: string;
  /** `redirect` (default) sends the page to the hosted checkout; `modal` opens it over your page. */
  mode?: "modal" | "redirect";
  /** The look of the modal; ignored by `redirect`. */
  theme?: Theme;
  /** `modal` only: the payment went through. */
  onSuccess?: (event: CheckoutSuccessEvent) => void;
  /** `modal` only: the buyer closed the modal. */
  onClose?: () => void;
}

/**
 * A button that takes the buyer to the hosted checkout. It stays disabled
 * until Peráta.js has loaded.
 */
export function CheckoutButton(props: CheckoutButtonProps): ReactElement {
  const { url, mode = "redirect", theme, onSuccess, onClose, onClick, disabled, children, ...rest } = props;
  const { perata } = usePerataContext();

  const handleClick = (event: MouseEvent<HTMLButtonElement>): void => {
    onClick?.(event);
    if (event.defaultPrevented || !perata) return;
    if (mode === "modal") {
      perata.openCheckout({
        url,
        ...(theme !== undefined && { theme }),
        ...(onSuccess !== undefined && { onSuccess }),
        ...(onClose !== undefined && { onClose }),
      });
    } else {
      perata.redirectToCheckout({ url });
    }
  };

  return createElement("button", { ...rest, type: "button", disabled: disabled || !perata, onClick: handleClick }, children ?? "Pagar");
}
