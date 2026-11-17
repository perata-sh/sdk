import type { CardComponentOptions, ChangeEvent, ConfirmPaymentParams, InstallmentOption, OpenCheckoutOptions, PaymentComponentOptions, PaymentResult, PerataInstance, WalletComponentOptions } from "@perata-sh/js";

// A stand-in for what Peráta.js returns: it records every call, and the test
// triggers the script's events by hand.
export class StubComponent<Options> {
  mounted: Element | null = null;
  mounts = 0;
  unmounts = 0;
  destroys = 0;
  focuses = 0;
  updates: unknown[] = [];
  listeners = new Map<string, Array<(payload: never) => void>>();
  readonly options: Options;
  constructor(options: Options) {
    this.options = options;
  }
  // Like the script's own: every method that has nothing to answer answers the component.
  mount(target: string | Element): this {
    this.mounted = typeof target === "string" ? document.querySelector(target) : target;
    this.mounts += 1;
    return this;
  }
  unmount(): void {
    this.mounted = null;
    this.unmounts += 1;
  }
  destroy(): void {
    this.unmount();
    this.listeners.clear();
    this.destroys += 1;
  }
  update(options: unknown): this {
    this.updates.push(options);
    return this;
  }
  focus(): this {
    this.focuses += 1;
    return this;
  }
  getState(): ChangeEvent {
    return STATE;
  }
  on(event: string, listener: (payload: never) => void): this {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), listener]);
    return this;
  }
  off(event: string, listener: (payload: never) => void): this {
    this.listeners.set(event, (this.listeners.get(event) ?? []).filter((candidate) => candidate !== listener));
    return this;
  }
  emit(event: string, payload?: unknown): void {
    for (const listener of this.listeners.get(event) ?? []) listener(payload as never);
  }
}

export const STATE: ChangeEvent = { complete: false, brand: "", last4: "", error: null, empty: true, valid: false, method: "card" };

export interface Stub {
  perata: PerataInstance;
  payments: Array<StubComponent<PaymentComponentOptions>>;
  cards: Array<StubComponent<CardComponentOptions>>;
  wallets: Array<StubComponent<WalletComponentOptions>>;
  redirects: string[];
  modals: OpenCheckoutOptions[];
  confirmed: ConfirmPaymentParams[];
  installmentsAsked: string[];
  statusAsked: string[];
  /** The answers `getStatus` gives, in order; the last one repeats. An Error is thrown instead. */
  statuses: Array<PaymentResult | Error>;
}

export const PAID: PaymentResult = { status: "succeeded", orderId: "ord_1", paymentId: "pay_1", statusKey: "sk_12345678" };
export const OPTIONS: InstallmentOption[] = [
  { installments: 1, installmentAmountCents: 10000, totalCents: 10000, interestCents: 0, label: "1x de R$ 100,00 (à vista)" },
  { installments: 3, installmentAmountCents: 3400, totalCents: 10200, interestCents: 200, label: "3x de R$ 34,00 (total R$ 102,00)" },
];

export function stub(): Stub {
  const state: Stub = { perata: undefined as unknown as PerataInstance, payments: [], cards: [], wallets: [], redirects: [], modals: [], confirmed: [], installmentsAsked: [], statusAsked: [], statuses: [] };
  state.perata = {
    version: "v1",
    redirectToCheckout: ({ url }) => {
      state.redirects.push(url);
    },
    openCheckout: async (options) => {
      state.modals.push(options);
      return { close: () => {} };
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
      wallet: (options) => {
        const component = new StubComponent(options);
        state.wallets.push(component);
        return component as unknown as ReturnType<PerataInstance["components"]["wallet"]>;
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
  state.perata.getStatus = async ({ statusKey }) => {
    state.statusAsked.push(statusKey);
    const next = state.statuses.length > 1 ? state.statuses.shift() : state.statuses[0];
    if (next === undefined) return PAID;
    if (next instanceof Error) throw next;
    return next;
  };
  return state;
}
