// A compile-time check, never run: the types accept exactly what perata.js
// accepts and answer exactly what it answers. `@ts-expect-error` marks what
// must not compile.
import type {
  Appearance,
  CardComponent,
  ChangeEvent,
  ConfirmPaymentParams,
  CustomerInput,
  InstallmentOption,
  OpenedCheckout,
  PaymentComponent,
  PaymentResult,
  PaymentStatus,
  PerataError,
  PerataErrorCode,
  PerataInstance,
} from "../src/index.ts";
import { loadPerata } from "../src/index.ts";

declare const perata: PerataInstance;
declare const card: CardComponent;
declare const payment: PaymentComponent;

// appearance: Stripe's names, and the flat spellings
const nested: Appearance = { theme: "auto", variables: { colorPrimary: "#0a7d5a", borderRadius: "8", fontFamily: "display", fontSize: "lg" } };
const flat: Appearance = { primaryColor: "#0a7d5a", borderRadius: "8", fontFamily: "system", size: "sm" };
// @ts-expect-error a theme the script does not know
const badTheme: Appearance = { theme: "sepia" };
// @ts-expect-error a font the script does not know
const badFont: Appearance = { variables: { fontFamily: "comic" } };
void [nested, flat, badTheme, badFont];

// locale: Brazilian Portuguese only
perata.components.payment({ clientSecret: "cs_12345678", locale: "pt-BR" });
// @ts-expect-error no other language yet
perata.components.payment({ clientSecret: "cs_12345678", locale: "en" });
perata.components.wallet({ clientSecret: "cs_12345678", customer: { email: "a@exemplo.com", document: "52998224725" }, onReady: (state) => state.available?.includes("google_pay"), onCancel: () => {}, onSuccess: (result) => result.status }).update({ customer: { email: "b@exemplo.com" } });

// customer: no phone
const customer: CustomerInput = { name: "Ana", email: "ana@exemplo.com", document: "529.982.247-25", address: { street: "Rua A", number: "1", district: "Centro", city: "Recife", state: "PE", postalCode: "50000-000" } };
// @ts-expect-error the session keeps no phone
const withPhone: CustomerInput = { phone: "81999999999" };
void [customer, withPhone];

// change: everything is there
declare const change: ChangeEvent;
const { complete, brand, last4, error, empty, valid, method }: ChangeEvent = change;
void [complete, brand.toLowerCase(), last4, error?.message, empty, valid, method];

// result
declare const result: PaymentResult;
const status: PaymentStatus = result.status;
// @ts-expect-error not a status of the session
const badStatus: PaymentStatus = "pending";
void [status, badStatus, result.orderId, result.paymentId, result.statusKey, result.redirectUrl, result.error?.fields];
void [result.pix?.qrCode, result.pix?.qrCodeImage, result.pix?.copyPaste, result.pix?.expiresAt];
void [result.boleto?.digitableLine, result.boleto?.barcode, result.boleto?.pdfUrl, result.boleto?.dueDate];

// installments: every field, label included
declare const option: InstallmentOption;
void [option.installments, option.installmentAmountCents, option.totalCents, option.interestCents, option.label];

// getStatus follows a Pix
const followed: Promise<PaymentResult> = perata.getStatus({ statusKey: "sk_12345678" });
void followed;

// openCheckout answers a handle
const opened: Promise<OpenedCheckout> = perata.openCheckout({ url: "https://perata.sh/pagamento/pcl_1", theme: "dark", onSuccess: () => false, onError: (error) => error.code });
void opened.then((checkout) => checkout.close());

// components: focus, destroy, chaining
card.mount("#card").focus().on("change", (state) => state.complete).off("error", () => {});
payment.update({ appearance: nested }).getState().method;
payment.destroy();

// confirmPayment
const params: ConfirmPaymentParams = { clientSecret: "cs_12345678", card, method: "card", installments: 3, customer };
void perata.confirmPayment(params);
void perata.getInstallments({ clientSecret: "cs_12345678" });

// errors: a code to switch on, and a rejection that carries it
declare const rejected: PerataError;
const code: PerataErrorCode = rejected.code;
const known: PerataErrorCode[] = ["origin_not_allowed", "load_timeout", "checkout_not_found", "network_error", "http_404", "payment_failed"];
void [code, known, rejected.message];
declare const failure: PaymentResult["error"];
const failureCode: string | undefined = failure?.code;
void failureCode;

// loadPerata: a fixed version takes both its hash and its integrity value
void loadPerata({ pin: { hash: "0123456789abcdef", integrity: "sha384-AAAA" }, nonce: "n" });
// @ts-expect-error a pin without its integrity value
void loadPerata({ pin: { hash: "0123456789abcdef" } });
