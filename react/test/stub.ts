import type { CardComponentOptions, ConfirmPaymentParams, InstallmentOption, OpenCheckoutOptions, PaymentComponentOptions, PaymentResult, PerataInstance } from "@perata-sh/js";

// A stand-in for what Peráta.js returns: it records every call, and the test
// triggers the script's events by hand.
export class StubComponent<Options> {
  mounted: Element | null = null;
  mounts = 0;
  unmounts = 0;
  updates: unknown[] = [];
  listeners = new Map<string, Array<(payload: never) => void>>();
  readonly options: Options;
  constructor(options: Options) {
    this.options = options;
  }
  mount(target: string | HTMLElement): void {
    this.mounted = typeof target === "string" ? document.querySelector(target) : target;
    this.mounts += 1;
  }
  unmount(): void {
    this.mounted = null;
    this.unmounts += 1;
  }
  update(options: unknown): void {
    this.updates.push(options);
  }
  on(event: string, listener: (payload: never) => void): void {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), listener]);
  }
  emit(event: string, payload?: unknown): void {
    for (const listener of this.listeners.get(event) ?? []) listener(payload as never);
  }
}

export interface Stub {
  perata: PerataInstance;
  payments: Array<StubComponent<PaymentComponentOptions>>;
  cards: Array<StubComponent<CardComponentOptions>>;
  redirects: string[];
  modals: OpenCheckoutOptions[];
  confirmed: ConfirmPaymentParams[];
  installmentsAsked: string[];
}

export const PAID: PaymentResult = { status: "succeeded", orderId: "ord_1", paymentId: "pay_1" };
export const OPTIONS: InstallmentOption[] = [{ installments: 1, totalCents: 10000 }, { installments: 3, installmentAmountCents: 3400, totalCents: 10200, interestCents: 200 }];

export function stub(): Stub {
  const state: Stub = { perata: undefined as unknown as PerataInstance, payments: [], cards: [], redirects: [], modals: [], confirmed: [], installmentsAsked: [] };
  state.perata = {
    redirectToCheckout: ({ url }) => {
      state.redirects.push(url);
    },
    openCheckout: (options) => {
      state.modals.push(options);
    },
    components: {
      payment: (options) => {
        const component = new StubComponent(options);
        state.payments.push(component);
        return component as unknown as ReturnType<PerataInstance["components"]["payment"]>;
      },
      card: (options) => {
        const component = new StubComponent(options);
        state.cards.push(component);
        return component as unknown as ReturnType<PerataInstance["components"]["card"]>;
      },
    },
    confirmPayment: async (params) => {
      state.confirmed.push(params);
      return PAID;
    },
    getInstallments: async ({ clientSecret }) => {
      state.installmentsAsked.push(clientSecret);
      return OPTIONS;
    },
  };
  return state;
}
