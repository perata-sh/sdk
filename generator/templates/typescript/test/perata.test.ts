import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";

import { Perata, PerataError, verifyWebhook, verifyWebhookSignature, WebhookVerificationError } from "../src/index.ts";

interface Seen {
  method: string;
  url: URL;
  headers: Headers;
  body: string | undefined;
}

function client(answer: (seen: Seen) => Response): { perata: Perata; seen: Seen[] } {
  const seen: Seen[] = [];
  const fake: typeof fetch = async (input, init) => {
    const request = { method: init?.method ?? "GET", url: new URL(String(input)), headers: new Headers(init?.headers), body: init?.body as string | undefined };
    seen.push(request);
    return answer(request);
  };
  return { perata: new Perata({ apiKey: "prk_test_key", baseUrl: "https://perata.test/", fetch: fake }), seen };
}

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

const product = (id: string) => ({ id, name: "Curso", description: "", status: "active", created_at: "2026-10-17T00:00:00Z" });

test("a call carries the key and unwraps the data", async () => {
  const { perata, seen } = client(() => json(200, { data: product("prod_1") }));
  const got = await perata.products.get("prod_1");
  assert.equal(got.id, "prod_1");
  assert.equal(got.status, "active");
  assert.equal(seen[0]?.method, "GET");
  assert.equal(seen[0]?.url.pathname, "/api/v1/products/prod_1");
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer prk_test_key");
});

test("a write sends its body and idempotency key", async () => {
  const { perata, seen } = client(() => json(201, { data: product("prod_1") }));
  await perata.products.create({ name: "Curso" }, { idempotencyKey: "create-1" });
  assert.equal(seen[0]?.method, "POST");
  assert.equal(seen[0]?.headers.get("idempotency-key"), "create-1");
  assert.deepEqual(JSON.parse(seen[0]?.body ?? ""), { name: "Curso" });
});

const session = (clientSecret: string) => ({
  id: "pcl_1",
  url: "https://perata.sh/pagamento/pcl_1",
  product_id: "prod_1",
  price_id: "price_1",
  status: "active",
  label: "",
  quantity: 1,
  success_url: "https://loja.example/obrigado",
  cancel_url: "",
  expires_at: null,
  created_at: "2026-11-16T12:00:00Z",
  session_id: "cs_1",
  client_secret: clientSecret,
  client_secret_expires_at: "2026-11-16T12:30:00Z",
  status_key: "sk_1",
  amount_cents: null,
  items: [],
  metadata: {},
  client_reference_id: "",
});

test("a checkout session hands back the client secret for the browser", async () => {
  let replayed = false;
  const { perata, seen } = client(() => json(201, { data: session(replayed ? "" : "cs_secret_1") }, replayed ? { "Idempotent-Replayed": "true" } : {}));
  const params = { product_id: "prod_1", price_id: "price_1", success_url: "https://loja.example/obrigado" };
  const checkout = await perata.checkouts.create(params, { idempotencyKey: "pedido-1" });
  assert.equal(checkout.client_secret, "cs_secret_1");
  assert.equal(checkout.session_id, "cs_1");
  assert.equal(checkout.status_key, "sk_1");
  assert.equal(checkout.client_secret_expires_at, "2026-11-16T12:30:00Z");
  assert.equal(checkout.url, "https://perata.sh/pagamento/pcl_1");
  assert.equal(checkout.expires_at, null);
  assert.equal(seen[0]?.method, "POST");
  assert.equal(seen[0]?.url.pathname, "/api/v1/checkouts");
  assert.equal(seen[0]?.headers.get("idempotency-key"), "pedido-1");
  assert.deepEqual(JSON.parse(seen[0]?.body ?? ""), params);
  replayed = true;
  const again = await perata.checkouts.create(params, { idempotencyKey: "pedido-1" });
  assert.equal(again.client_secret, "");
  assert.equal(again.session_id, "cs_1");
  assert.equal(again.status_key, "sk_1");
});

test("usage ingestion carries the source credential and its events", async () => {
  const seen: Seen[] = [];
  const fake: typeof fetch = async (input, init) => {
    seen.push({ method: init?.method ?? "GET", url: new URL(String(input)), headers: new Headers(init?.headers), body: init?.body as string | undefined });
    return json(200, { data: { created: 1, replayed: 0 } });
  };
  const usage = new Perata({ apiKey: "pus_live_source", baseUrl: "https://perata.test/", fetch: fake });
  const receipt = await usage.usage.ingest({
    events: [{
      customer_id: "cus_1", external_event_id: "req-1", input_tokens: "1200", output_tokens: "300", cached_tokens: "0",
      occurred_at: "2026-11-13T12:00:00Z", _cost: { amount: "1.250000", currency: "brl" },
    }],
  });
  assert.equal(receipt.created, 1);
  assert.equal(receipt.replayed, 0);
  assert.equal(seen[0]?.method, "POST");
  assert.equal(seen[0]?.url.pathname, "/api/v1/usage/token-events");
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer pus_live_source");
  const sent = JSON.parse(seen[0]?.body ?? "") as { events: Record<string, unknown>[] };
  assert.equal(sent.events.length, 1);
  assert.deepEqual(sent.events[0]?._cost, { amount: "1.250000", currency: "brl" });
  assert.equal("_llm" in (sent.events[0] ?? {}), false);
  assert.equal("parent_id" in (sent.events[0] ?? {}), false);
});

test("usage ingestion errors are the flat error document", async () => {
  const event = { customer_id: "cus_1", external_event_id: "req-1", input_tokens: "1", output_tokens: "0", cached_tokens: "0", occurred_at: "2026-11-13T12:00:00Z" };
  const cases: [number, unknown, string, number, string][] = [
    [401, { error: "invalid_credential" }, "invalid_credential", 0, ""],
    [409, { error: "conflict", record: 2, message: "conflict" }, "conflict", 2, "conflict"],
    [422, { error: "invalid_request", record: 3, message: "validation failed: customer_id", fields: { customer_id: ["unknown"] } }, "invalid_request", 3, "validation failed: customer_id"],
    [400, { error: "invalid_request", message: "malformed JSON" }, "invalid_request", 0, "malformed JSON"],
    [415, { error: "unsupported_media_type" }, "unsupported_media_type", 0, ""],
    [500, { error: "unavailable" }, "unavailable", 0, ""],
  ];
  for (const [status, body, code, record, message] of cases) {
    const { perata } = client(() => json(status, body));
    await assert.rejects(perata.usage.ingest({ events: [event] }), (error: unknown) => {
      assert.ok(error instanceof PerataError);
      assert.equal(error.status, status);
      assert.equal(error.code, code);
      assert.equal(error.record, record);
      assert.equal(error.message, message ? `perata: ${status} ${code}: ${message}` : `perata: ${status} ${code}`);
      if (status === 422) assert.deepEqual(error.fields, { customer_id: ["unknown"] });
      return true;
    });
  }
});

test("an error wrapped in data by an older server is still read", async () => {
  const event = { customer_id: "cus_1", external_event_id: "req-1", input_tokens: "1", output_tokens: "0", cached_tokens: "0", occurred_at: "2026-11-13T12:00:00Z" };
  const { perata } = client(() => json(409, { data: { error: "event_conflict", record: 2, message: "conflict" } }));
  await assert.rejects(perata.usage.ingest({ events: [event] }), (error: unknown) => {
    assert.ok(error instanceof PerataError);
    assert.equal(error.code, "event_conflict");
    assert.equal(error.record, 2);
    return true;
  });
});

test("a base URL must be https unless it is loopback", () => {
  for (const baseUrl of ["https://perata.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"]) {
    assert.doesNotThrow(() => new Perata({ apiKey: "k", baseUrl }), baseUrl);
  }
  for (const baseUrl of ["http://perata.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "perata.sh", "", "http://[::2]"]) {
    assert.throws(() => new Perata({ apiKey: "k", baseUrl }), /must be https/, baseUrl);
  }
});

const discount = (id: string) => JSON.parse("{\"id\":\"__ID__\",\"name\":\"Black\",\"code\":null,\"type\":\"percentage\",\"basis_points\":1000,\"amount_cents\":0,\"currency\":\"BRL\",\"duration\":\"once\",\"duration_in_months\":0,\"max_redemptions\":null,\"max_redemptions_per_customer\":null,\"redemptions_count\":0,\"starts_at\":\"2026-10-17T00:00:00Z\",\"ends_at\":null,\"status\":\"active\",\"product_ids\":[\"prod_1\"],\"created_at\":\"2026-10-17T00:00:00Z\",\"modified_at\":\"2026-10-17T00:00:00Z\"}".replace("__ID__", id));

test("a discount goes through create, get, list and delete", async () => {
  const { perata, seen } = client(({ method, url }) => {
    if (method === "POST") {
      return json(201, { data: discount("disc_1") });
    }
    if (method === "DELETE") {
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/api/v1/discounts") {
      const page = url.searchParams.get("page");
      return json(200, { data: { items: [discount(`disc_${page}`)], pagination: { total_count: 2, max_page: 2 } } });
    }
    return json(200, { data: discount("disc_1") });
  });
  const created = await perata.discounts.create({ name: "Black", type: "percentage", duration: "once", basis_points: 1000 });
  assert.equal(created.id, "disc_1");
  assert.equal(created.code, null);
  assert.deepEqual(created.product_ids, ["prod_1"]);
  assert.equal((await perata.discounts.get("disc_1")).name, "Black");
  const ids: string[] = [];
  for await (const each of perata.discounts.listIter({ limit: 1 })) {
    ids.push(each.id);
  }
  assert.deepEqual(ids, ["disc_1", "disc_2"]);
  assert.equal(await perata.discounts.delete("disc_1"), undefined);
  assert.deepEqual(
    seen.map((each) => `${each.method} ${each.url.pathname}`),
    ["POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"],
  );
  assert.deepEqual(JSON.parse(seen[0]?.body ?? ""), { name: "Black", type: "percentage", duration: "once", basis_points: 1000 });
});

test("a free-form value decodes nested", async () => {
  const state = {"id": "cus_1", "name": "Ana", "email": "ana@example.com", "external_id": "", "status": "active", "created_at": "2026-10-17T00:00:00Z", "active_subscriptions": [], "granted_benefits": [{"id": "gr_1", "granted_at": "2026-10-17T00:00:00Z", "benefit_id": "ben_1", "benefit_type": "feature_flag", "benefit_metadata": {"flags": {"beta": true, "limits": {"seats": 5, "tiers": ["a", 2, null, 1.5]}}}, "properties": {"links": [{"url": "https://example.com", "expires": null}]}}]};
  const { perata } = client(() => json(200, { data: state }));
  const got = await perata.customers.getState("cus_1");
  const grant = got.granted_benefits[0];
  assert.deepEqual(grant?.benefit_metadata, { flags: { beta: true, limits: { seats: 5, tiers: ["a", 2, null, 1.5] } } });
  assert.deepEqual(grant?.properties, { links: [{ url: "https://example.com", expires: null }] });
});

test("a POST without a key is sent with its own, a GET with none", async () => {
  const { perata, seen } = client(() => json(201, { data: product("prod_1") }));
  await perata.products.create({ name: "Curso" });
  await perata.products.create({ name: "Curso" });
  await perata.products.create({ name: "Curso" }, { idempotencyKey: "mine" });
  await perata.products.get("prod_1");
  const keys = seen.map((each) => each.headers.get("idempotency-key"));
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  assert.match(keys[0] ?? "", uuid);
  assert.match(keys[1] ?? "", uuid);
  assert.notEqual(keys[0], keys[1]);
  assert.equal(keys[2], "mine");
  assert.equal(keys[3], null);
});

test("iterating walks every page", async () => {
  const { perata, seen } = client(({ url }) =>
    json(200, { data: { items: [product(`prod_${url.searchParams.get("page")}`)], pagination: { total_count: 3, max_page: 3 } } }),
  );
  const ids: string[] = [];
  for await (const item of perata.products.listIter({ limit: 1 })) {
    ids.push(item.id);
  }
  assert.deepEqual(ids, ["prod_1", "prod_2", "prod_3"]);
  assert.equal(seen[0]?.url.searchParams.get("limit"), "1");
});

test("a redirect is refused and the key never follows it", async () => {
  const elsewhere: Array<string | undefined> = [];
  const other = createServer((request, response) => {
    elsewhere.push(request.headers.authorization);
    response.end("{}");
  });
  await new Promise<void>((resolve) => other.listen(0, "127.0.0.1", resolve));
  const first = createServer((_request, response) => {
    response.writeHead(302, { Location: `http://127.0.0.1:${(other.address() as AddressInfo).port}/steal` });
    response.end();
  });
  await new Promise<void>((resolve) => first.listen(0, "127.0.0.1", resolve));
  try {
    const perata = new Perata({ apiKey: "prk_test_key", baseUrl: `http://127.0.0.1:${(first.address() as AddressInfo).port}` });
    await assert.rejects(perata.products.get("prod_1"), (error) => error instanceof PerataError && error.status === 302);
    assert.deepEqual(elsewhere, []);
  } finally {
    first.close();
    other.close();
  }
});

test("a metadata filter is sent as one pair a key, the keys sorted and escaped", async () => {
  const empty = { data: { items: [], pagination: { total_count: 0, max_page: 1 } } };
  const { perata, seen } = client(() => json(200, empty));
  const metadata = { pedido: "123", "camera id": "a/b" };
  await perata.orders.list({ client_reference_id: "pedido-1", metadata });
  assert.equal(seen[0]?.url.search, "?client_reference_id=pedido-1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123");
  assert.equal(seen[0]?.url.searchParams.get("metadata[camera id]"), "a/b");
  assert.equal(seen[0]?.url.searchParams.get("metadata[pedido]"), "123");
  for await (const _each of perata.checkouts.listIter({ limit: 1, metadata })) {
    // every page of the walk carries the filter
  }
  assert.equal(seen[1]?.url.search, "?limit=1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123&page=1");
});

test("customers are listed by e-mail", async () => {
  const { perata, seen } = client(() => json(200, { data: { items: [], pagination: { total_count: 0, max_page: 1 } } }));
  await perata.customers.list({ email: "ana@example.com" });
  assert.equal(seen[0]?.url.pathname, "/api/v1/customers");
  assert.equal(seen[0]?.url.search, "?email=ana%40example.com");
});

// A graduated price goes out with its tiers and without the fixed amount, and a
// subscription reads back the quantity it bills and the order reference it came
// from; amount_cents is the cycle's total for that quantity.
test("a graduated price carries its tiers and a subscription its quantity", async () => {
  const tiers = [{ up_to: 1, unit_amount_cents: 25000 }, { up_to: null, unit_amount_cents: 15000 }];
  const { perata, seen } = client(({ method }) =>
    method === "POST"
      ? json(201, { data: { id: "price_1", product_id: "prod_1", type: "recurring", interval: "month", interval_count: 1, currency: "BRL", status: "active", amount_cents: 0, pricing_model: "graduated", unit_amount_cents: null, unit_label: "câmera", unit_label_plural: "câmeras", tiers } })
      : json(200, { data: { id: "sub_1", amount_cents: 55000, quantity: 3, client_reference_id: "pedido-9", metadata: { camera: "c1" }, status: "active" } }),
  );
  const price = await perata.prices.create({ product_id: "prod_1", type: "recurring", interval: "month", pricing_model: "graduated", tiers, unit_label: "câmera", unit_label_plural: "câmeras" });
  assert.equal(seen[0]?.url.pathname, "/api/v1/prices");
  const sent = JSON.parse(seen[0]?.body ?? "") as Record<string, unknown>;
  assert.equal(sent["pricing_model"], "graduated");
  assert.deepEqual(sent["tiers"], tiers);
  assert.equal("amount_cents" in sent, false);
  assert.equal(price.pricing_model, "graduated");
  assert.equal(price.amount_cents, 0);
  assert.equal(price.unit_amount_cents, null);
  assert.deepEqual(price.tiers, tiers);
  const subscription = await perata.subscriptions.get("sub_1");
  assert.equal(seen[1]?.url.pathname, "/api/v1/subscriptions/sub_1");
  assert.equal(subscription.quantity, 3);
  assert.equal(subscription.amount_cents, 55000);
  assert.equal(subscription.client_reference_id, "pedido-9");
});

// A checkout adds the buyer's remaining days to the first period, an extension
// goes out alone (no price_id), and the sale reads back what it took: the
// discount on the order and on the subscription, the change scheduled for the
// next period.
test("a first period extension and the discounts the sale reads back", async () => {
  const pending = { price_id: "price_2", quantity: 5, amount_cents: 90000, effective_at: "2026-12-20T03:00:00Z" };
  const { perata, seen } = client(({ method, url }) => {
    const route = `${method} ${url.pathname}`;
    switch (route) {
      case "POST /api/v1/checkouts":
        return json(201, { data: { id: "pcl_1", url: "https://perata.sh/pagamento/pcl_1", product_id: "prod_1", price_id: "price_1", first_period_extra_days: 30, discount_id: "disc_1", session_id: "cs_1", client_secret: "cs_secret_1" } });
      case "PATCH /api/v1/subscriptions/sub_1":
        return json(200, { data: { id: "sub_1", status: "active", first_period_extra_days: 30, discount_id: "disc_1", discount_ends_at: "2027-03-01T03:00:00Z", pending_update: pending } });
      case "GET /api/v1/subscriptions/sub_2":
        return json(200, { data: { id: "sub_2", status: "active", first_period_extra_days: null, discount_id: null, discount_ends_at: null, pending_update: null } });
      case "GET /api/v1/orders/ord_1":
        return json(200, { data: { id: "ord_1", amount_cents: 9000, subtotal_cents: 10000, discount_cents: 1000, discount_id: "disc_1", discount_code: "BEMVINDO" } });
      default:
        return json(200, { data: { id: "price_1", product_id: "prod_1", type: "recurring", interval: "month", interval_count: 1, currency: "BRL", status: "archived", amount_cents: 9000 } });
    }
  });
  const checkout = await perata.checkouts.create({ product_id: "prod_1", price_id: "price_1", first_period_extra_days: 30 });
  assert.equal(JSON.parse(seen[0]?.body ?? "")["first_period_extra_days"], 30);
  assert.equal(checkout.first_period_extra_days, 30);
  assert.equal(checkout.discount_id, "disc_1");
  const subscription = await perata.subscriptions.update("sub_1", { extend_current_period_days: 15 });
  const sent = JSON.parse(seen[1]?.body ?? "") as Record<string, unknown>;
  assert.equal(seen[1]?.method, "PATCH");
  assert.equal(sent["extend_current_period_days"], 15);
  assert.equal("price_id" in sent, false);
  assert.equal(subscription.first_period_extra_days, 30);
  assert.equal(subscription.discount_id, "disc_1");
  assert.equal(subscription.discount_ends_at, "2027-03-01T03:00:00Z");
  assert.deepEqual(subscription.pending_update, pending);
  const none = await perata.subscriptions.get("sub_2");
  assert.equal(none.pending_update, null);
  assert.equal(none.first_period_extra_days, null);
  assert.equal(none.discount_id, null);
  const order = await perata.orders.get("ord_1");
  assert.equal(order.subtotal_cents, 10000);
  assert.equal(order.discount_cents, 1000);
  assert.equal(order.discount_id, "disc_1");
  assert.equal(order.discount_code, "BEMVINDO");
  const price = await perata.prices.get("price_1");
  assert.equal(seen[4]?.url.pathname, "/api/v1/prices/price_1");
  assert.equal(price.status, "archived");
});

// The payment reads back its fee, its net, its split and the payout that pays it.
test("a payment reads back its fee, its split and its payout", async () => {
  const { perata } = client(() => json(200, {"data":{"id":"pay_1","showcase_id":"x","checkout_id":"x","customer_id":"x","method":"card","state":"unknown","amount_cents":0,"captured_cents":0,"refunded_cents":0,"currency":"BRL","created_at":"2026-11-20T12:00:00Z","metadata":{},"client_reference_id":"x","installments":0,"installment_amount_cents":0,"installment_interest_cents":0,"subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"fee_cents":450,"net_cents":8550,"expected_payout_on":"2026-12-21","payout_deposited_on":null,"payout_id":null,"split":[{"recipient_id":"shw_2","amount_cents":9000,"fee_cents":450,"net_cents":8550}]}}));
  const payment = await perata.payments.get("pay_1");
  assert.equal(payment.fee_cents, 450);
  assert.equal(payment.net_cents, 8550);
  assert.equal(payment.expected_payout_on, "2026-12-21");
  assert.equal(payment.payout_id, null);
  assert.equal(payment.payout_deposited_on, null);
  assert.deepEqual(payment.split, [{ recipient_id: "shw_2", amount_cents: 9000, fee_cents: 450, net_cents: 8550 }]);
});

// The balance carries its period, the payouts are filtered and walked page by
// page, and a payout reads back its lines: a fee has no payment.
test("the balance and the payouts read back what will be deposited", async () => {
  const { perata, seen } = client(({ url }) => {
    if (url.pathname === "/api/v1/balance") return json(200, {"data":{"total_to_receive_cents":100000,"released_cents":10000,"held_cents":5000,"scheduled_cents":60000,"later_cents":25000,"deposited_cents":42000,"period_from":"2026-11-01","period_to":"2026-11-20","currency":"BRL"}});
    if (url.pathname === "/api/v1/payouts/po_20261120") return json(200, {"data":{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2,"items":[{"kind":"sale","payment_id":"pay_1","installment":1,"status":"deposited","amount_cents":10000,"fee_cents":300,"net_cents":9700},{"kind":"fee","payment_id":null,"installment":0,"status":"deposited","amount_cents":0,"fee_cents":150,"net_cents":-150}]}});
    return url.searchParams.get("page") === "2" ? json(200, {"data":{"items":[{"id":"po_20261119","status":"released","expected_on":"2026-11-19","deposited_on":null,"amount_cents":5000,"fee_cents":200,"net_cents":4800,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}) : json(200, {"data":{"items":[{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}});
  });
  const balance = await perata.balance.get({ date_from: "2026-11-01", date_to: "2026-11-20" });
  assert.equal(seen[0]?.url.search, "?date_from=2026-11-01&date_to=2026-11-20");
  assert.equal(balance.total_to_receive_cents, 100000);
  assert.equal(balance.released_cents + balance.held_cents + balance.scheduled_cents + balance.later_cents, balance.total_to_receive_cents);
  assert.equal(balance.deposited_cents, 42000);
  assert.deepEqual([balance.period_from, balance.period_to, balance.currency], ["2026-11-01", "2026-11-20", "BRL"]);
  const walked: string[] = [];
  for await (const payout of perata.payouts.listIter({ status: "deposited", date_from: "2026-11-01", sorting: "-date", limit: 1 })) {
    walked.push(`${payout.id}:${payout.status}`);
    assert.equal(payout.net_cents, payout.amount_cents - payout.fee_cents);
    assert.equal(payout.status === "deposited", payout.deposited_on !== null);
  }
  assert.deepEqual(walked, ["po_20261120:deposited", "po_20261119:released"]);
  assert.deepEqual(Object.fromEntries(seen[1]?.url.searchParams ?? []), { page: "1", limit: "1", status: "deposited", date_from: "2026-11-01", sorting: "-date" });
  const payout = await perata.payouts.get("po_20261120");
  assert.equal(payout.net_cents, 9550);
  assert.equal(payout.items.length, 2);
  assert.deepEqual(payout.items[0], { kind: "sale", payment_id: "pay_1", installment: 1, status: "deposited", amount_cents: 10000, fee_cents: 300, net_cents: 9700 });
  assert.equal(payout.items[1]?.kind, "fee");
  assert.equal(payout.items[1]?.payment_id, null);
  assert.equal(payout.items[1]?.net_cents, -150);
});

// A checkout says how its subscription renews, the subscription reads back the
// mode it resolved to, its label and whether the buyer is written to, an update
// changes them, and the open renewal charge is read by its own route; without
// one the API answers 404 no_open_charge.
test("the renewal mode, the label and the open charge", async () => {
  const { perata, seen } = client(({ method, url }) => {
    switch (`${method} ${url.pathname}`) {
      case "POST /api/v1/checkouts":
        return json(201, {"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"Olho de Águia · Ana","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"x","first_period_extra_days":null,"renewal_mode":"automatic","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}});
      case "PATCH /api/v1/subscriptions/sub_1":
        return json(200, {"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"pix_automatic","label":"Olho de Águia · Ana","notify_customer_email":false}});
      case "GET /api/v1/subscriptions/sub_1/open-charge":
        return json(200, {"data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","reminder":null,"days_until_due":null,"notify_customer_email":true}});
      default:
        return json(404, { error: "no_open_charge", message: "A assinatura não tem cobrança de renovação em aberto." });
    }
  });
  const label = "Olho de Águia · Ana";
  const checkout = await perata.checkouts.create({ product_id: "prod_1", price_id: "price_1", renewal_mode: "automatic", notify_customer_email: false, label });
  assert.deepEqual(
    ["renewal_mode", "notify_customer_email", "label"].map((key) => (JSON.parse(seen[0]?.body ?? "") as Record<string, unknown>)[key]),
    ["automatic", false, label],
  );
  assert.deepEqual([checkout.renewal_mode, checkout.notify_customer_email, checkout.label], ["automatic", false, label]);
  const subscription = await perata.subscriptions.update("sub_1", { renewal_mode: "manual", notify_customer_email: true, label });
  assert.deepEqual(
    ["renewal_mode", "notify_customer_email", "label"].map((key) => (JSON.parse(seen[1]?.body ?? "") as Record<string, unknown>)[key]),
    ["manual", true, label],
  );
  assert.deepEqual([subscription.renewal_mode, subscription.label, subscription.notify_customer_email], ["pix_automatic", label, false]);
  const charge = await perata.subscriptions.getOpenCharge("sub_1");
  assert.equal(seen[2]?.url.pathname, "/api/v1/subscriptions/sub_1/open-charge");
  assert.deepEqual([charge.id, charge.subscription_id, charge.amount_cents, charge.renewal_mode], ["rc_1", "sub_1", 9000, "manual"]);
  assert.deepEqual([charge.payment_url, charge.due_at, charge.expires_at, charge.reminder, charge.days_until_due, charge.notify_customer_email], ["https://perata.sh/pagar/rc_1", "2026-12-20T03:00:00Z", "2026-12-27T03:00:00Z", null, null, true]);
  await assert.rejects(perata.subscriptions.getOpenCharge("sub_2"), (error: unknown) => error instanceof PerataError && error.status === 404 && error.code === "no_open_charge");
});

// The renewal events carry the charge: due, and the reminder with its days.
test("the renewal events carry the charge", async () => {
  const now = (signedAt + 120) * 1000;
  const due = await verifyWebhook(newSecret, webhookHeaders("msg_7", signedAt, "v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w="), '{"id":"msg_7","type":"subscription.renewal_due","timestamp":"2026-10-22T12:00:00Z","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":null,"days_until_due":null}}', now);
  assert.equal(due.type, "subscription.renewal_due");
  assert.equal(due.type === "subscription.renewal_due" && due.data.id, "rc_1");
  assert.equal(due.type === "subscription.renewal_due" && due.data.payment_url, "https://perata.sh/pagar/rc_1");
  assert.equal(due.type === "subscription.renewal_due" && due.data.reminder, null);
  const reminder = await verifyWebhook(newSecret, webhookHeaders("msg_8", signedAt, "v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q="), '{"id":"msg_8","type":"subscription.renewal_reminder","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":"before_due","days_until_due":3}}', now);
  assert.equal(reminder.environment, "live");
  assert.equal(reminder.type === "subscription.renewal_reminder" && reminder.data.reminder, "before_due");
  assert.equal(reminder.type === "subscription.renewal_reminder" && reminder.data.days_until_due, 3);
});

test("a refusal is a typed error", async () => {
  const { perata } = client(({ url }) =>
    url.pathname === "/api/v1/customers"
      ? json(422, { error: "invalid_request", fields: { email: ["send an e-mail"] } })
      : new Response(null, { status: 429, headers: { "Retry-After": "7" } }),
  );
  await assert.rejects(perata.customers.create({ name: "x", email: "x" }), (error: unknown) => {
    assert.ok(error instanceof PerataError);
    assert.equal(error.status, 422);
    assert.equal(error.code, "invalid_request");
    assert.deepEqual(error.fields["email"], ["send an e-mail"]);
    return true;
  });
  await assert.rejects(perata.products.list(), (error: unknown) => {
    assert.ok(error instanceof PerataError);
    assert.equal(error.status, 429);
    assert.equal(error.retryAfter, 7);
    return true;
  });
});

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const referenceSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const oldSecret = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
const newSecret = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
const orderPaid =
  '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}';
const usageRecorded =
  '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}';
const payoutSent = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}';
const orderPaidLive =
  '{"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}';
const payoutSentTest = '{"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","environment":"test","data":{"payout_id":"po_1","amount_cents":5000}}';
const signedAt = 1792670400;
const webhookHeaders = (id: string, at: number, signature: string) => ({ "Webhook-Id": id, "webhook-timestamp": String(at), "webhook-signature": signature });

test("the Standard Webhooks vector verifies", async () => {
  const body = '{"test": 2432232314}';
  const headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
  await verifyWebhookSignature(referenceSecret, headers, body, 1614265330_000);
  await assert.rejects(verifyWebhookSignature(referenceSecret, headers, `${body} `, 1614265330_000), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(referenceSecret, headers, body, (1614265330 + 301) * 1000), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(newSecret, headers, body, 1614265330_000), WebhookVerificationError);
});

test("a timestamp that is not plain digits is refused", async () => {
  const body = '{"test": 2432232314}';
  for (const [stamp, signature] of [["+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="], ["²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="], ["", "x"], ["1_6", "x"]] as const) {
    const headers = { "Webhook-Id": "msg_p5jXN8AQM9LWM0D4loKWxJek", "webhook-timestamp": stamp, "webhook-signature": `v1,${signature}` };
    await assert.rejects(verifyWebhookSignature(referenceSecret, headers, body, 1614265330_000), WebhookVerificationError, stamp);
  }
});

test("a webhook carries the environment it happened in", async () => {
  const now = (signedAt + 120) * 1000;
  const older: [string, string, string][] = [
    ["msg_2", "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=", orderPaid],
    ["msg_3", "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=", usageRecorded],
    ["msg_4", "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=", payoutSent],
  ];
  for (const [id, signature, body] of older) {
    const event = await verifyWebhook(newSecret, webhookHeaders(id, signedAt, signature), body, now);
    assert.equal(event.environment, "", id);
    assert.equal(event.showcase_id, "", id);
  }
  const order = await verifyWebhook(newSecret, webhookHeaders("msg_5", signedAt, "v1,vJOO2qPe9Vzlr42VPwCuIO+a6Sg8ZVfl9z4WuLJItwg="), orderPaidLive, now);
  assert.equal(order.environment, "live");
  assert.equal(order.showcase_id, "shw_1");
  assert.equal(order.data.showcase_id, "shw_1");
  const unknown = await verifyWebhook(newSecret, webhookHeaders("msg_6", signedAt, "v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM="), payoutSentTest, now);
  assert.equal(unknown.environment, "test");
  assert.equal(unknown.showcase_id, "");
});

test("a webhook answers its typed event", async () => {
  const now = (signedAt + 120) * 1000;
  const headers = webhookHeaders("msg_2", signedAt, "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=");
  for (const secret of [newSecret, oldSecret]) {
    const event = await verifyWebhook(secret, headers, orderPaid, now);
    assert.equal(event.type, "order.paid");
    if (event.type !== "order.paid") {
      return;
    }
    assert.deepEqual([event.data.id, event.data.installments, event.data.installment_interest_cents], ["ord_1", 3, 360]);
  }
  await assert.rejects(verifyWebhook(referenceSecret, headers, orderPaid, now), WebhookVerificationError);
  const usage = await verifyWebhook(newSecret, webhookHeaders("msg_3", signedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), usageRecorded, now);
  assert.equal(usage.type === "usage_event.recorded" && usage.data["merchant_id"], "mer_1");
  const unknown = await verifyWebhook(newSecret, webhookHeaders("msg_4", signedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), new TextEncoder().encode(payoutSent), now);
  assert.equal(unknown.type as string, "payout.sent");
  assert.deepEqual(unknown.data, { payout_id: "po_1", amount_cents: 5000 });
});
