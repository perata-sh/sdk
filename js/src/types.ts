// The contract of Peráta.js (https://perata.sh/v1/perata.js, the global
// `window.Perata`), typed. Fields the script's documentation does not fix yet
// are open (an index signature or `string & {}`) so a newer script never
// contradicts these types.

/** The ways a buyer can pay. */
export type PaymentMethodKind = "card" | "pix" | "boleto";

/** The look of the hosted frames, light or dark. */
export type Theme = "light" | "dark";

/**
 * How the components look. `theme` picks light or dark; `variables` overrides
 * the design tokens (colours, radius, font) by name.
 */
export interface Appearance {
  theme?: Theme;
  variables?: Record<string, string>;
  [key: string]: unknown;
}

/** The language of the components; `pt-BR` by default. */
export type Locale = "pt-BR" | "en" | (string & {});

/** An error as the script reports it. `code` is stable and meant for code, `message` for the buyer. */
export interface PerataErrorInfo {
  code: string;
  message: string;
}

/** What `change` carries: whether the form can be confirmed, and what the card looks like so far. Never the full number. */
export interface ChangeEvent {
  /** True when every field is filled and valid. */
  complete: boolean;
  /** The card's brand once it can be told (`visa`, `mastercard`, `elo`…). */
  brand?: string;
  /** The last four digits, once the number is complete. */
  last4?: string;
  /** The problem with what the buyer typed, if any. */
  error?: PerataErrorInfo | null;
}

/** The Pix charge: show the QR code, or offer the copy-and-paste code. */
export interface PixResult {
  qrCode: string;
  /** The QR code as an image (a data URL or an address), ready for an `<img>`. */
  qrCodeImage: string;
  copyPaste: string;
  /** When the code stops working (ISO 8601). */
  expiresAt: string;
}

/** The boleto: show the line, the barcode or open the PDF. */
export interface BoletoResult {
  digitableLine: string;
  barcode: string;
  pdfUrl: string;
  /** The due date (ISO 8601). */
  dueDate: string;
}

/**
 * The state of an order, as the API names it (`open`, `confirmed`,
 * `succeeded`, `failed`, `expired`); the script may report others.
 */
export type PaymentStatus = "open" | "confirmed" | "succeeded" | "failed" | "expired" | (string & {});

/** What `confirmPayment` resolves to and the components' `success` carries. */
export interface PaymentResult {
  status: PaymentStatus;
  orderId: string;
  paymentId: string;
  /** Present when the buyer chose Pix. */
  pix?: PixResult;
  /** Present when the buyer chose boleto. */
  boleto?: BoletoResult;
  /** Present when the payment was refused or could not be made. */
  error?: PerataErrorInfo;
}

/** One way to split a card payment: `getInstallments` lists them. */
export interface InstallmentOption {
  /** In how many instalments; 1 is a single payment. */
  installments: number;
  /** The value of one instalment, in cents. */
  installmentAmountCents?: number;
  /** What the buyer pays in all, in cents. */
  totalCents?: number;
  /** The interest inside the total, in cents; 0 when there is none. */
  interestCents?: number;
  [key: string]: unknown;
}

/** What the buyer gives the checkout besides the payment itself; each field is optional. */
export interface CustomerInput {
  name?: string;
  email?: string;
  /** CPF or CNPJ, digits only. */
  document?: string;
  phone?: string;
  [key: string]: unknown;
}

/** The elements a component can be mounted in: a CSS selector or the element itself. */
export type MountTarget = string | HTMLElement;

/** What every component does. `Events` maps an event name to what its listener receives. */
export interface PerataComponent<Events> {
  /** Draws the component into the element (or the first element the selector matches). */
  mount(target: MountTarget): void;
  /** Removes it from the page; it can be mounted again. */
  unmount(): void;
  /** Changes the look without losing what the buyer typed. */
  update(options: { appearance?: Appearance }): void;
  /** Listens to an event. */
  on<K extends keyof Events & string>(event: K, listener: (payload: Events[K]) => void): void;
}

export interface PaymentComponentEvents {
  ready: undefined;
  change: ChangeEvent;
  success: PaymentResult;
  error: PerataErrorInfo;
}

export interface CardComponentEvents {
  ready: undefined;
  change: ChangeEvent;
  error: PerataErrorInfo;
}

export interface PaymentComponentOptions {
  /** The session's secret, from your server (`client_secret`). */
  clientSecret: string;
  appearance?: Appearance;
  locale?: Locale;
  onReady?: () => void;
  onChange?: (event: ChangeEvent) => void;
  onSuccess?: (result: PaymentResult) => void;
  onError?: (error: PerataErrorInfo) => void;
}

export interface CardComponentOptions {
  clientSecret: string;
  appearance?: Appearance;
  onChange?: (event: ChangeEvent) => void;
}

/** The ready-made component: payment methods, card, Pix and boleto in one, confirming by itself. */
export type PaymentComponent = PerataComponent<PaymentComponentEvents>;

/** The card fields, drawn in a secure frame; you confirm with `confirmPayment({ card })`. */
export type CardComponent = PerataComponent<CardComponentEvents>;

export interface ConfirmPaymentParams {
  clientSecret: string;
  /** The mounted card component; required when `method` is `card`. */
  card?: CardComponent;
  /** `card` by default. */
  method?: PaymentMethodKind;
  /** The number of instalments for a card payment; 1 by default. */
  installments?: number;
  customer?: CustomerInput;
}

export interface GetInstallmentsParams {
  clientSecret: string;
}

/** What the modal tells you about a payment that went through. */
export interface CheckoutSuccessEvent {
  /** The `success_url` of the checkout, when it has one. */
  successURL?: string;
  /** True when Peráta is about to send the buyer to `successURL`. */
  redirect?: boolean;
  [key: string]: unknown;
}

export interface RedirectToCheckoutOptions {
  /** The checkout's `url`, as the API returns it. */
  url: string;
}

export interface OpenCheckoutOptions {
  /** The checkout's `url`, as the API returns it. */
  url: string;
  theme?: Theme;
  onSuccess?: (event: CheckoutSuccessEvent) => void;
  /** The buyer closed the modal. */
  onClose?: () => void;
}

export interface PerataComponents {
  payment(options: PaymentComponentOptions): PaymentComponent;
  card(options: CardComponentOptions): CardComponent;
}

/** What `Perata()` returns: the four ways of taking a payment. */
export interface PerataInstance {
  /** Sends the whole page to the hosted checkout. */
  redirectToCheckout(options: RedirectToCheckoutOptions): void;
  /** Opens the hosted checkout over your page, in a modal. */
  openCheckout(options: OpenCheckoutOptions): void;
  /** The ready-made component and the card field. */
  components: PerataComponents;
  /** Charges the session: with a card from `components.card`, or with Pix or boleto. It resolves with the outcome; a refusal is `result.error`, not a rejection. */
  confirmPayment(params: ConfirmPaymentParams): Promise<PaymentResult>;
  /** The ways the card payment can be split. */
  getInstallments(params: GetInstallmentsParams): Promise<InstallmentOption[]>;
}

/** `window.Perata`: the function the script defines. */
export type PerataFactory = () => PerataInstance;

declare global {
  interface Window {
    Perata?: PerataFactory;
  }
}
