import assert from "node:assert/strict";
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
  return { perata: new Perata({ apiKey: "prk_test_key", baseUrl: "http://perata.test/", fetch: fake }), seen };
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
  '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}';
const usageRecorded =
  '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}';
const payoutSent = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}';
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

test("a webhook answers its typed event", async () => {
  const now = (signedAt + 120) * 1000;
  const headers = webhookHeaders("msg_2", signedAt, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=");
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
