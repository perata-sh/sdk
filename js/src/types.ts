// The contract of Peráta.js (https://perata.sh/v1/perata.js, the global
// `window.Perata`), typed from the script itself (perata.sh `public/perata.js`):
// what it accepts and what it answers, field by field.

/** The ways a buyer can pay. */
export type PaymentMethodKind = "card" | "pix" | "boleto";

/** The look of the hosted checkout opened by `openCheckout`. */
export type Theme = "light" | "dark";

/**
 * The look of the components: a theme and four variables, named as Stripe
 * names them. The flat spellings `primaryColor`, `borderRadius`, `fontFamily`
 * and `size` are accepted too, and `variables` wins when both are given. A
 * value the script does not recognise is ignored.
 */
export interface Appearance {
  /** `auto` follows the buyer's device. */
  theme?: "light" | "dark" | "auto";
  variables?: AppearanceVariables;
  /** Same as `variables.colorPrimary`. */
  primaryColor?: string;
  /** Same as `variables.borderRadius`. */
  borderRadius?: string;
  /** Same as `variables.fontFamily`. */
  fontFamily?: "display" | "system";
  /** Same as `variables.fontSize`. */
  size?: "sm" | "md" | "lg";
}

export interface AppearanceVariables {
  /** The main colour, as `#rrggbb`. */
  colorPrimary?: string;
  /** The corner radius in pixels, written as a string (`"8"` or `"8px"`); from 0 to 24. */
  borderRadius?: string;
  /** `display` is Peráta's own face, `system` the device's. */
  fontFamily?: "display" | "system";
  fontSize?: "sm" | "md" | "lg";
}

/** The language of the components. Only Brazilian Portuguese for now. */
export type Locale = "pt-BR";

/** An error as the script reports it. `code` is stable and meant for code, `message` for the buyer. */
export interface PerataErrorInfo {
  code: string;
  message: string;
  /** What the API found wrong, field by field, when it said. */
  fields?: Record<string, unknown>;
}

/**
 * What a buyer may see of the fields, which is all the page ever learns: what
 * `change` carries and what `getState()` answers. Never the number, the expiry
 * or the code.
 */
export interface ChangeEvent {
  /** True when every field is filled. */
  complete: boolean;
  /** The card's brand in lowercase (`visa`, `mastercard`, `elo`…), once it can be told; empty before. */
  brand: string;
  /** The last four digits, once the number is complete; empty before. */
  last4: string;
  /** The problem with what the buyer typed, or `null`. */
  error: PerataErrorInfo | null;
  /** True when nothing has been typed. */
  empty: boolean;
  /** True when what was typed is valid. */
  valid: boolean;
  /** The method the buyer picked: `card` in the card field, any of the methods in the payment component. */
  method: PaymentMethodKind | (string & {});
}

/** The Pix charge: show the QR code, or offer the copy-and-paste code. */
export interface PixResult {
  /** The code the QR draws, the same text as `copyPaste`. */
  qrCode: string;
  /** The QR code as an SVG data URL (`data:image/svg+xml;base64,…`), ready for an `<img>`; empty if it could not be made. */
  qrCodeImage: string;
  /** The "copia e cola" text. */
  copyPaste: string;
  /** When the code stops working (ISO 8601). */
  expiresAt: string;
}

/** The boleto: show the line, the barcode or open the PDF. */
export interface BoletoResult {
  digitableLine: string;
  /** The 44 digits of the bar code, worked out from the 47 of the line; empty if the line is not 47 digits. */
  barcode: string;
  pdfUrl: string;
  /** The due date (ISO 8601). */
  dueDate: string;
}

/**
 * Where the session stands: `open` (nothing paid), `confirmed` (the payment is
 * requested and not settled: a Pix or a boleto waiting for the buyer),
 * `succeeded`, `failed` or `expired`. A payment the issuer refused is `failed`.
 */
export type PaymentStatus = "open" | "confirmed" | "succeeded" | "failed" | "expired";

/** What `confirmPayment` and `getStatus` resolve to, and what the components' `success` carries. */
export interface PaymentResult {
  status: PaymentStatus;
  /** The order; empty when the payment could not be started. */
  orderId: string;
  /** The payment; empty when none was made. */
  paymentId: string;
  /**
   * The key to follow this session with `getStatus` once the `clientSecret` is
   * spent: keep it for a Pix or a boleto. Missing on a result that never
   * reached the server.
   */
  statusKey?: string;
  /** Present when the buyer chose Pix. */
  pix?: PixResult;
  /** Present when the buyer chose boleto. */
  boleto?: BoletoResult;
  /** Present when the buyer must go to the issuer's page (3-D Secure): send them there with `window.location.assign`. */
  redirectUrl?: string;
  /** Present when the payment was refused, expired or could not be made. */
  error?: PerataErrorInfo;
}

/** One way to split a card payment: `getInstallments` lists them, the single payment first. */
export interface InstallmentOption {
  /** In how many instalments; 1 is a single payment. */
  installments: number;
  /** The value of one instalment, in cents. */
  installmentAmountCents: number;
  /** What the buyer pays in all, in cents. */
  totalCents: number;
  /** The interest inside the total, in cents; 0 when there is none. */
  interestCents: number;
  /** Ready to show: `3x de R$ 34,00 sem juros`, `1x de R$ 100,00 (à vista)`. */
  label: string;
}

/** The buyer's address, every field optional. */
export interface CustomerAddress {
  street?: string;
  number?: string;
  complement?: string;
  /** Bairro. */
  district?: string;
  city?: string;
  /** The UF, two letters. */
  state?: string;
  /** The CEP, with or without the hyphen. */
  postalCode?: string;
}

/**
 * What the buyer gives the checkout besides the payment itself; each field is
 * optional. There is no phone: the session does not keep one.
 */
export interface CustomerInput {
  name?: string;
  email?: string;
  /** CPF (11 characters) or CNPJ (14, which may have letters), with or without punctuation. */
  document?: string;
  address?: CustomerAddress;
}

/** Where a component is drawn: a CSS selector or the element itself. */
export type MountTarget = string | Element;

/** What every component does. `Events` maps an event name to what its listener receives. */
export interface PerataComponent<Events> {
  /** Draws the component into the element (or the first element the selector matches) and answers itself. Throws `mount_target_not_found` when there is none. */
  mount(target: MountTarget): this;
  /** Takes it off the page; it can be mounted again. A payment being confirmed resolves with an `element_unmounted` error. */
  unmount(): void;
  /** Unmounts it and forgets every listener; the component is not used again. */
  destroy(): void;
  /** Changes the look without losing what the buyer typed. */
  update(options: { appearance?: Appearance }): this;
  /** Puts the cursor in the first field. */
  focus(): this;
  /** Listens to an event; answers itself, so calls chain. */
  on<K extends keyof Events & string>(event: K, listener: (payload: Events[K]) => void): this;
  /** Stops listening. */
  off<K extends keyof Events & string>(event: K, listener: (payload: Events[K]) => void): this;
  /** What the buyer may see of the fields now. */
  getState(): ChangeEvent;
}

export interface PaymentComponentEvents {
  /** The frame is drawn; carries the fields' state. */
  ready: ChangeEvent;
  change: ChangeEvent;
  success: PaymentResult;
  error: PerataErrorInfo;
}

export interface CardComponentEvents {
  ready: ChangeEvent;
  change: ChangeEvent;
  error: PerataErrorInfo;
}

export interface PaymentComponentOptions {
  /** The session's secret, from your server (`client_secret`). */
  clientSecret: string;
  appearance?: Appearance;
  locale?: Locale;
  onReady?: (state: ChangeEvent) => void;
  onChange?: (event: ChangeEvent) => void;
  onSuccess?: (result: PaymentResult) => void;
  onError?: (error: PerataErrorInfo) => void;
}

export interface CardComponentOptions {
  clientSecret: string;
  appearance?: Appearance;
  onReady?: (state: ChangeEvent) => void;
  onChange?: (event: ChangeEvent) => void;
  onError?: (error: PerataErrorInfo) => void;
}

/** The ready-made component: payment methods, card, Pix and boleto in one, with its own button, confirming by itself. */
export type PaymentComponent = PerataComponent<PaymentComponentEvents>;

/** The card fields, drawn in a secure frame; you confirm with `confirmPayment({ card })`. */
export type CardComponent = PerataComponent<CardComponentEvents>;

export interface ConfirmPaymentParams {
  clientSecret: string;
  /** The mounted card component; required when `method` is `card`. */
  card?: CardComponent;
  /** A mounted payment component, to confirm it from a button of your own; `method` then defaults to what the buyer picked in it. */
  payment?: PaymentComponent;
  /** `card` by default. */
  method?: PaymentMethodKind;
  /** The number of instalments for a card payment; 1 by default. */
  installments?: number;
  customer?: CustomerInput;
}

export interface GetInstallmentsParams {
  clientSecret: string;
}

export interface GetStatusParams {
  /** The `statusKey` of a result. */
  statusKey: string;
}

/** What the modal tells you about a payment that went through. */
export interface CheckoutSuccessEvent {
  /** The `success_url` of the checkout; empty when it has none. */
  successURL: string;
  /** True when Peráta is about to send the buyer to `successURL`. */
  redirect: boolean;
}

export interface RedirectToCheckoutOptions {
  /** The checkout's `url`, as the API returns it. It must be a checkout link of the Peráta that served the script. */
  url: string;
}

export interface OpenCheckoutOptions {
  /** The checkout's `url`, as the API returns it. It must be a checkout link of the Peráta that served the script. */
  url: string;
  theme?: Theme;
  /** The checkout is drawn. */
  onLoaded?: (checkout: OpenedCheckout) => void;
  /** The payment is under way: the modal cannot be closed until it is decided. */
  onConfirmed?: () => void;
  /** The payment went through. Return `false` to stop Peráta from sending the buyer to `successURL` and do it yourself. */
  onSuccess?: (event: CheckoutSuccessEvent) => void | boolean;
  /** The buyer closed the modal. */
  onClose?: () => void;
}

/** The modal that `openCheckout` opened. */
export interface OpenedCheckout {
  /** Takes the modal off the page. */
  close(): void;
}

export interface PerataComponents {
  payment(options: PaymentComponentOptions): PaymentComponent;
  card(options: CardComponentOptions): CardComponent;
}

/** What `Perata()` returns: the four ways of taking a payment. */
export interface PerataInstance {
  /** The script's version (`v1`). */
  version: string;
  /** Sends the whole page to the hosted checkout. Throws `invalid_checkout_url` for any other address. */
  redirectToCheckout(options: RedirectToCheckoutOptions): void;
  /** Opens the hosted checkout over your page, in a modal; resolves once it is drawn, with a handle to close it. Rejects with `invalid_checkout_url` for any other address. */
  openCheckout(options: OpenCheckoutOptions): Promise<OpenedCheckout>;
  /** The ready-made component and the card field. */
  components: PerataComponents;
  /**
   * Charges the session: with a card from `components.card`, or with Pix or
   * boleto. It resolves with the outcome, a refusal being `result.error`; it
   * rejects only for a call that cannot be made (a malformed `clientSecret`, a
   * card payment with no card component).
   */
  confirmPayment(params: ConfirmPaymentParams): Promise<PaymentResult>;
  /** The ways the card payment can be split. */
  getInstallments(params: GetInstallmentsParams): Promise<InstallmentOption[]>;
  /**
   * Where a session stands, by the `statusKey` of its result, after the
   * `clientSecret` is spent: this is how a Pix or a boleto is followed until it
   * is paid. Rejects with an error whose `code` is `invalid_status_key` or
   * `http_<status>`.
   */
  getStatus(params: GetStatusParams): Promise<PaymentResult>;
}

/** `window.Perata`: the function the script defines. It works with or without `new`. */
export interface PerataFactory {
  (settings?: Record<string, unknown>): PerataInstance;
  version: string;
}

declare global {
  interface Window {
    Perata?: PerataFactory;
  }
}
