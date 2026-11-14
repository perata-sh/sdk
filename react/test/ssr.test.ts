// No jsdom here: this file runs with no window and no document, as a server does.
import assert from "node:assert/strict";
import { test } from "node:test";

import { createElement as h } from "react";
import { renderToString } from "react-dom/server";

import { CardField, CheckoutButton, PaymentComponent, PerataProvider, usePaymentStatus } from "../src/index.ts";

test("the provider and every component render on the server without touching the browser", () => {
  assert.equal(typeof window, "undefined");
  assert.equal(typeof document, "undefined");
  const html = renderToString(
    h(PerataProvider, null, h(PaymentComponent, { clientSecret: "cs_1", className: "pay" }), h(CardField, { clientSecret: "cs_1", className: "card" }), h(CheckoutButton, { url: "https://perata.sh/pagamento/pcl_1", mode: "modal" }, "Comprar")),
  );
  assert.match(html, /<div class="pay"><\/div>/);
  assert.match(html, /<div class="card"><\/div>/);
  assert.match(html, /<button[^>]*disabled=""[^>]*>Comprar<\/button>/);
});

test("usePaymentStatus renders on the server as nothing yet and asks nothing", () => {
  function Waiting() {
    const { result, loading, done } = usePaymentStatus({ statusKey: "sk_12345678", intervalMs: 3000 });
    return h("p", null, `${result?.status ?? "none"}:${loading}:${done}`);
  }
  assert.match(renderToString(h(PerataProvider, null, h(Waiting))), /<p>none:false:false<\/p>/);
});
