import "./setup.ts";

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import type { PerataInstance } from "@perata-sh/js";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { createElement as h, createRef, StrictMode } from "react";

import { CardField, CheckoutButton, PaymentComponent, PerataProvider, useConfirmPayment, usePaymentStatus, usePerata, usePerataStatus } from "../src/index.ts";
import type { CardFieldHandle, PaymentComponentHandle, PaymentStatusState } from "../src/index.ts";
import { OPTIONS, PAID, STATE, stub } from "./stub.ts";

afterEach(() => {
  cleanup();
  delete (window as { Perata?: unknown }).Perata;
  document.head.replaceChildren();
});

function Probe() {
  const perata = usePerata();
  const { status, error } = usePerataStatus();
  return h("p", { "data-testid": "probe" }, `${status}:${perata ? "instance" : "none"}:${error?.message ?? ""}`);
}

test("usePerata outside the provider fails loudly", () => {
  const original = console.error;
  console.error = () => {};
  try {
    assert.throws(() => render(h(Probe)), /inside <PerataProvider>/);
  } finally {
    console.error = original;
  }
});

test("a given instance is ready at once", () => {
  const { perata } = stub();
  render(h(PerataProvider, { instance: perata }, h(Probe)));
  assert.equal(screen.getByTestId("probe").textContent, "ready:instance:");
});

test("a promise of an instance resolves into ready", async () => {
  const { perata } = stub();
  render(h(PerataProvider, { instance: Promise.resolve<PerataInstance | null>(perata) }, h(Probe)));
  assert.equal(screen.getByTestId("probe").textContent, "loading:none:");
  await waitFor(() => assert.equal(screen.getByTestId("probe").textContent, "ready:instance:"));
});

test("without an instance the provider loads the script, with the address and nonce it was given", async () => {
  const { perata } = stub();
  render(h(PerataProvider, { scriptUrl: "http://localhost:9000/v1/perata.js", nonce: "n0nce" }, h(Probe)));
  assert.equal(screen.getByTestId("probe").textContent, "loading:none:");

  const script = document.querySelector("script");
  assert.equal(script?.getAttribute("src"), "http://localhost:9000/v1/perata.js");
  assert.equal(script?.nonce, "n0nce");

  (window as { Perata?: unknown }).Perata = () => perata;
  act(() => {
    script?.dispatchEvent(new window.Event("load"));
  });
  await waitFor(() => assert.equal(screen.getByTestId("probe").textContent, "ready:instance:"));
});

test("a script that cannot be loaded ends in error, with the reason", async () => {
  render(h(PerataProvider, { scriptUrl: "http://localhost:9001/v1/perata.js" }, h(Probe)));
  act(() => {
    document.querySelector("script")?.dispatchEvent(new window.Event("error"));
  });
  await waitFor(() => assert.match(screen.getByTestId("probe").textContent ?? "", /^error:none:perata: could not load/));
});

test("PaymentComponent draws only once Peráta.js is ready, and takes its options through", async () => {
  const state = stub();
  const events: string[] = [];
  const appearance = { theme: "dark" as const };
  const view = render(
    h(PerataProvider, { instance: Promise.resolve<PerataInstance | null>(state.perata) }, h(PaymentComponent, { clientSecret: "cs_1", appearance, locale: "en", className: "slot", onReady: (state) => events.push(`ready:${state.method}`), onChange: (e) => events.push(`change:${e.complete}`), onSuccess: (r) => events.push(`success:${r.orderId}`), onError: (e) => events.push(`error:${e.code}`) })),
  );
  assert.equal(state.payments.length, 0, "nothing before the script is there");
  await waitFor(() => assert.equal(state.payments.length, 1));

  const [payment] = state.payments;
  assert.equal(payment?.options.clientSecret, "cs_1");
  assert.deepEqual(payment?.options.appearance, appearance);
  assert.equal(payment?.options.locale, "en");
  assert.equal(payment?.mounted, view.container.querySelector("div.slot"));

  payment?.options.onReady?.(STATE);
  payment?.options.onChange?.({ ...STATE, complete: true, empty: false, valid: true });
  payment?.options.onSuccess?.(PAID);
  payment?.options.onError?.({ code: "card_declined", message: "Recusado" });
  assert.deepEqual(events, ["ready:card", "change:true", "success:ord_1", "error:card_declined"]);
});

test("PaymentComponent calls the latest callback without remounting", async () => {
  const state = stub();
  const seen: string[] = [];
  const tree = (label: string) => h(PerataProvider, { instance: state.perata }, h(PaymentComponent, { clientSecret: "cs_1", onSuccess: () => seen.push(label) }));
  const view = render(tree("first"));
  await waitFor(() => assert.equal(state.payments.length, 1));
  view.rerender(tree("second"));
  state.payments[0]?.options.onSuccess?.(PAID);
  assert.deepEqual(seen, ["second"]);
  assert.equal(state.payments.length, 1);
  assert.equal(state.payments[0]?.unmounts, 0);
});

test("PaymentComponent updates the look in place and remounts for a new session", async () => {
  const state = stub();
  const tree = (secret: string, theme: "light" | "dark") => h(PerataProvider, { instance: state.perata }, h(PaymentComponent, { clientSecret: secret, appearance: { theme } }));
  const view = render(tree("cs_1", "light"));
  await waitFor(() => assert.equal(state.payments.length, 1));

  view.rerender(tree("cs_1", "dark"));
  assert.deepEqual(state.payments[0]?.updates, [{ appearance: { theme: "dark" } }]);
  assert.equal(state.payments.length, 1);

  view.rerender(tree("cs_1", "dark"));
  assert.equal(state.payments[0]?.updates.length, 1, "an equal appearance is not applied again");

  view.rerender(tree("cs_2", "dark"));
  assert.equal(state.payments.length, 2);
  assert.equal(state.payments[0]?.unmounts, 1);
  assert.equal(state.payments[1]?.options.clientSecret, "cs_2");
});

test("PaymentComponent removes the component when it leaves the page", async () => {
  const state = stub();
  const view = render(h(PerataProvider, { instance: state.perata }, h(PaymentComponent, { clientSecret: "cs_1" })));
  await waitFor(() => assert.equal(state.payments.length, 1));
  view.unmount();
  assert.equal(state.payments[0]?.unmounts, 1);
  assert.equal(state.payments[0]?.destroys, 1, "destroyed, so its listeners are forgotten too");
});

test("PaymentComponent's ref focuses it and reads its state", async () => {
  const state = stub();
  const handle = createRef<PaymentComponentHandle>();
  render(h(PerataProvider, { instance: state.perata }, h(PaymentComponent, { ref: handle, clientSecret: "cs_1" })));
  await waitFor(() => assert.equal(state.payments.length, 1));
  handle.current?.focus();
  assert.equal(state.payments[0]?.focuses, 1);
  assert.equal(handle.current?.component, state.payments[0]);
  assert.deepEqual(handle.current?.getState(), STATE);
});

test("in StrictMode the double effect leaves exactly one component mounted", async () => {
  const state = stub();
  render(h(StrictMode, null, h(PerataProvider, { instance: state.perata }, h(PaymentComponent, { clientSecret: "cs_1" }), h(CardField, { clientSecret: "cs_1" }))));
  await waitFor(() => assert.ok(state.payments.length >= 1));
  const livePayments = state.payments.filter((component) => component.mounted !== null);
  const liveCards = state.cards.filter((component) => component.mounted !== null);
  assert.equal(livePayments.length, 1);
  assert.equal(liveCards.length, 1);
});

test("CardField confirms through its ref, with the card it drew", async () => {
  const state = stub();
  const handle = createRef<CardFieldHandle>();
  const changes: string[] = [];
  const events: string[] = [];
  render(h(PerataProvider, { instance: state.perata }, h(CardField, { ref: handle, clientSecret: "cs_9", onChange: (e) => changes.push(`${e.brand}:${e.last4}`), onReady: () => events.push("ready"), onError: (e) => events.push(e.code) })));
  await waitFor(() => assert.equal(state.cards.length, 1));
  const [card] = state.cards;

  card?.options.onChange?.({ ...STATE, complete: true, brand: "visa", last4: "4242" });
  card?.emit("ready", STATE);
  card?.emit("error", { code: "invalid_number", message: "x" });
  assert.deepEqual(changes, ["visa:4242"]);
  assert.deepEqual(events, ["ready", "invalid_number"]);

  assert.equal(handle.current?.component, card);
  const result = await handle.current?.confirmPayment({ installments: 3, customer: { email: "a@b.co" } });
  assert.deepEqual(result, PAID);
  assert.deepEqual(state.confirmed, [{ method: "card", installments: 3, customer: { email: "a@b.co" }, clientSecret: "cs_9", card }]);

  assert.deepEqual(await handle.current?.getInstallments(), OPTIONS);
  assert.deepEqual(state.installmentsAsked, ["cs_9"]);

  handle.current?.focus();
  assert.equal(card?.focuses, 1);
  assert.deepEqual(handle.current?.getState(), STATE);
});

test("CardField's ref rejects before the field exists", async () => {
  const handle = createRef<CardFieldHandle>();
  render(h(PerataProvider, { scriptUrl: "http://localhost:9002/v1/perata.js", timeoutMs: 20 }, h(CardField, { ref: handle, clientSecret: "cs_1" })));
  await assert.rejects(handle.current!.confirmPayment(), /not loaded yet/);
  await assert.rejects(handle.current!.getInstallments(), /not loaded yet/);
});

test("CheckoutButton stays disabled until ready, then redirects", async () => {
  const state = stub();
  render(h(PerataProvider, { instance: Promise.resolve<PerataInstance | null>(state.perata) }, h(CheckoutButton, { url: "https://perata.sh/pagamento/pcl_1" }, "Comprar")));
  const button = screen.getByRole("button", { name: "Comprar" }) as HTMLButtonElement;
  assert.equal(button.type, "button");
  assert.equal(button.disabled, true);
  await waitFor(() => assert.equal(button.disabled, false));
  fireEvent.click(button);
  assert.deepEqual(state.redirects, ["https://perata.sh/pagamento/pcl_1"]);
  assert.equal(state.modals.length, 0);
});

test("CheckoutButton in modal mode opens the checkout over the page", async () => {
  const state = stub();
  const seen: string[] = [];
  render(h(PerataProvider, { instance: state.perata }, h(CheckoutButton, { url: "https://perata.sh/pagamento/pcl_1", mode: "modal", theme: "dark", className: "buy", onSuccess: () => seen.push("success"), onClose: () => seen.push("close") })));
  const button = screen.getByRole("button", { name: "Pagar" });
  assert.equal(button.className, "buy");
  fireEvent.click(button);
  assert.equal(state.redirects.length, 0);
  const [modal] = state.modals;
  assert.equal(modal?.url, "https://perata.sh/pagamento/pcl_1");
  assert.equal(modal?.theme, "dark");
  modal?.onSuccess?.({ successURL: "https://seller.test/ok", redirect: false });
  modal?.onClose?.();
  assert.deepEqual(seen, ["success", "close"]);
});

test("CheckoutButton respects an onClick that prevents the default", async () => {
  const state = stub();
  render(h(PerataProvider, { instance: state.perata }, h(CheckoutButton, { url: "https://perata.sh/pagamento/pcl_1", onClick: (e) => e.preventDefault() }, "Comprar")));
  fireEvent.click(screen.getByRole("button", { name: "Comprar" }));
  assert.equal(state.redirects.length, 0);
});

test("CheckoutButton reports a checkout that cannot be opened to onError", async () => {
  const state = stub();
  const problems: string[] = [];
  const refusal = Object.assign(new Error("Perata: o endereço não é um link de checkout da Peráta"), { code: "invalid_checkout_url" });
  state.perata.openCheckout = () => Promise.reject(refusal);
  state.perata.redirectToCheckout = () => {
    throw refusal;
  };
  render(
    h(PerataProvider, { instance: state.perata }, h(CheckoutButton, { url: "https://evil.test/", mode: "modal", onError: (error) => problems.push(`modal:${error.message}`) }, "Modal"), h(CheckoutButton, { url: "https://evil.test/", onError: (error) => problems.push(`redirect:${error.message}`) }, "Redirecionar")),
  );
  fireEvent.click(screen.getByRole("button", { name: "Modal" }));
  fireEvent.click(screen.getByRole("button", { name: "Redirecionar" }));
  await waitFor(() => assert.equal(problems.length, 2));
  assert.deepEqual(problems.sort(), ["modal:Perata: o endereço não é um link de checkout da Peráta", "redirect:Perata: o endereço não é um link de checkout da Peráta"]);
});

test("useConfirmPayment confirms Pix without a card and rejects while loading", async () => {
  const state = stub();
  let api: ReturnType<typeof useConfirmPayment> | undefined;
  function Grab() {
    api = useConfirmPayment();
    return null;
  }
  render(h(PerataProvider, { instance: state.perata }, h(Grab)));
  assert.deepEqual(await api?.confirmPayment({ clientSecret: "cs_1", method: "pix" }), PAID);
  assert.deepEqual(state.confirmed, [{ clientSecret: "cs_1", method: "pix" }]);
  assert.deepEqual(await api?.getInstallments({ clientSecret: "cs_1" }), OPTIONS);
  assert.deepEqual(await api?.getStatus({ statusKey: "sk_12345678" }), PAID);
  assert.deepEqual(state.statusAsked, ["sk_12345678"]);
  cleanup();

  render(h(PerataProvider, { scriptUrl: "http://localhost:9003/v1/perata.js", timeoutMs: 20 }, h(Grab)));
  await assert.rejects(api!.confirmPayment({ clientSecret: "cs_1", method: "pix" }), /not loaded yet/);
  await assert.rejects(api!.getStatus({ statusKey: "sk_12345678" }), /not loaded yet/);
});

// A Pix: confirmed while it waits, succeeded when it is paid.
const WAITING = { status: "confirmed", orderId: "ord_1", paymentId: "pay_1", statusKey: "sk_12345678" } as const;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function Status(props: { statusKey: string | null; intervalMs?: number; enabled?: boolean; out: { current: PaymentStatusState | undefined }; onResult?: (status: string) => void }) {
  const state = usePaymentStatus({ statusKey: props.statusKey, ...(props.intervalMs !== undefined && { intervalMs: props.intervalMs }), ...(props.enabled !== undefined && { enabled: props.enabled }), ...(props.onResult && { onResult: (r) => props.onResult?.(r.status) }) });
  props.out.current = state;
  return h("p", { "data-testid": "status" }, `${state.result?.status ?? "none"}:${state.done}:${state.error?.message ?? ""}`);
}

test("usePaymentStatus reads the status once without an interval", async () => {
  const state = stub();
  state.statuses = [WAITING];
  const out: { current: PaymentStatusState | undefined } = { current: undefined };
  render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: "sk_12345678", out })));
  await waitFor(() => assert.equal(screen.getByTestId("status").textContent, "confirmed:false:"));
  await sleep(40);
  assert.deepEqual(state.statusAsked, ["sk_12345678"], "asked once");
});

test("usePaymentStatus polls a Pix until it is paid, then stops", async () => {
  const state = stub();
  state.statuses = [WAITING, WAITING, PAID];
  const seen: string[] = [];
  const out: { current: PaymentStatusState | undefined } = { current: undefined };
  render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, out, onResult: (status) => seen.push(status) })));
  await waitFor(() => assert.equal(screen.getByTestId("status").textContent, "succeeded:true:"));
  await sleep(60);
  assert.equal(state.statusAsked.length, 3, "no ask after the final status");
  assert.deepEqual(seen, ["confirmed", "confirmed", "succeeded"]);
});

test("usePaymentStatus stops on a failed or expired status too", async () => {
  const state = stub();
  state.statuses = [{ ...WAITING, status: "expired", error: { code: "checkout_expired", message: "expirou" } }];
  const out: { current: PaymentStatusState | undefined } = { current: undefined };
  render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, out })));
  await waitFor(() => assert.equal(screen.getByTestId("status").textContent, "expired:true:"));
  await sleep(40);
  assert.equal(state.statusAsked.length, 1);
});

test("usePaymentStatus asks nothing without a key, while disabled or before the script is ready", async () => {
  const state = stub();
  const out: { current: PaymentStatusState | undefined } = { current: undefined };
  render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: null, intervalMs: 10, out })));
  cleanup();
  render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, enabled: false, out })));
  cleanup();
  render(h(PerataProvider, { scriptUrl: "http://localhost:9004/v1/perata.js", timeoutMs: 20 }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, out })));
  await sleep(60);
  assert.deepEqual(state.statusAsked, []);
});

test("usePaymentStatus keeps polling through a network error but stops on a refusal of the key", async () => {
  const state = stub();
  state.statuses = [Object.assign(new Error("offline"), { code: "network" }), PAID];
  const out: { current: PaymentStatusState | undefined } = { current: undefined };
  render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, out })));
  await waitFor(() => assert.equal(screen.getByTestId("status").textContent, "succeeded:true:"), { timeout: 2000 });
  assert.equal(state.statusAsked.length, 2);
  cleanup();

  const refused = stub();
  refused.statuses = [Object.assign(new Error("Não foi possível ler o pagamento."), { code: "http_404" })];
  render(h(PerataProvider, { instance: refused.perata }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, out })));
  await waitFor(() => assert.equal(screen.getByTestId("status").textContent, "none:false:Não foi possível ler o pagamento."));
  await sleep(50);
  assert.equal(refused.statusAsked.length, 1, "a 404 is not asked again");
});

test("usePaymentStatus stops polling when the component leaves, and refresh asks at once", async () => {
  const state = stub();
  state.statuses = [WAITING];
  const out: { current: PaymentStatusState | undefined } = { current: undefined };
  const view = render(h(PerataProvider, { instance: state.perata }, h(Status, { statusKey: "sk_12345678", intervalMs: 10, out })));
  await waitFor(() => assert.ok(state.statusAsked.length >= 2));
  const refreshed = await out.current?.refresh();
  assert.equal(refreshed?.status, "confirmed");
  view.unmount();
  const asked = state.statusAsked.length;
  await sleep(60);
  assert.equal(state.statusAsked.length, asked, "no ask after unmount");
});
