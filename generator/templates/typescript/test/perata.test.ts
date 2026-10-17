import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";

import { Perata, PerataError, verifyWebhook, WebhookVerificationError } from "../src/index.ts";

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

test("a webhook verifies only when Peráta signed it", async () => {
  const key = Buffer.from("0123456789abcdef0123456789abcdef");
  const secret = `whsec_${key.toString("base64")}`;
  const body = '{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}';
  const now = 1_800_000_000_000;
  const sign = (at: number, payload: string) => ({
    "webhook-id": "msg_1",
    "webhook-timestamp": String(at / 1000),
    "webhook-signature": `v1,bm90LXRoaXMtb25l v1,${createHmac("sha256", key).update(`msg_1.${at / 1000}.${payload}`).digest("base64")}`,
  });
  const event = await verifyWebhook(secret, sign(now, body), body, now);
  assert.equal(event.type, "checkout_session.succeeded");
  assert.equal(event.data["checkout_session_id"], "cs_1");
  await assert.rejects(verifyWebhook(secret, sign(now, body), `${body} `, now), WebhookVerificationError);
  await assert.rejects(verifyWebhook(secret, sign(now - 600_000, body), body, now), WebhookVerificationError);
});
