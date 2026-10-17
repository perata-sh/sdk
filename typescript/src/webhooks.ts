/** What Peráta posts to an endpoint. */
export interface WebhookEvent {
  id: string;
  type: string;
  timestamp: string;
  data: Record<string, string>;
}

/** A request Peráta did not sign, or signed too long ago. */
export class WebhookVerificationError extends Error {
  constructor(message = "perata: webhook signature does not verify") {
    super(message);
    this.name = "WebhookVerificationError";
  }
}

/** How far from now, in seconds, a webhook's timestamp may be. */
export const WEBHOOK_TOLERANCE_SECONDS = 300;

/** A request's headers, from fetch or from Node's http. */
export type HeadersLike = Headers | Record<string, string | string[] | undefined>;

function header(headers: HeadersLike, name: string): string {
  if (typeof (headers as Headers).get === "function") {
    return (headers as Headers).get(name) ?? "";
  }
  for (const [key, value] of Object.entries(headers as Record<string, string | string[] | undefined>)) {
    if (key.toLowerCase() === name) {
      return Array.isArray(value) ? value.join(" ") : (value ?? "");
    }
  }
  return "";
}

function base64(text: string): Uint8Array<ArrayBuffer> {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * Checks a webhook Peráta sent, as Standard Webhooks signs it — an
 * HMAC-SHA256 of "{webhook-id}.{webhook-timestamp}.{body}" under the key the
 * endpoint's whsec_ secret encodes — and answers its event. Pass the body
 * exactly as it arrived, before parsing it.
 */
export async function verifyWebhook(secret: string, headers: HeadersLike, body: string | Uint8Array, now: number = Date.now()): Promise<WebhookEvent> {
  let key: Uint8Array<ArrayBuffer>;
  try {
    key = base64(secret.replace(/^whsec_/, ""));
  } catch {
    key = new Uint8Array();
  }
  if (key.length === 0) {
    throw new Error("perata: the webhook secret is whsec_ and a base64 key");
  }
  const id = header(headers, "webhook-id");
  const stamp = header(headers, "webhook-timestamp");
  const seconds = Number(stamp);
  if (!id || !/^\d+$/.test(stamp) || Math.abs(now / 1000 - seconds) > WEBHOOK_TOLERANCE_SECONDS) {
    throw new WebhookVerificationError();
  }
  const raw = typeof body === "string" ? new TextEncoder().encode(body) : body;
  const signed = new Uint8Array(new TextEncoder().encode(`${id}.${stamp}.`).length + raw.length);
  signed.set(new TextEncoder().encode(`${id}.${stamp}.`));
  signed.set(raw, signed.length - raw.length);
  const hmac = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  for (const signature of header(headers, "webhook-signature").split(/\s+/)) {
    const [version, encoded] = signature.split(",", 2);
    if (version !== "v1" || !encoded) {
      continue;
    }
    let decoded: Uint8Array<ArrayBuffer>;
    try {
      decoded = base64(encoded);
    } catch {
      continue;
    }
    // subtle.verify compares in constant time.
    if (await crypto.subtle.verify("HMAC", hmac, decoded, signed)) {
      return JSON.parse(new TextDecoder().decode(raw)) as WebhookEvent;
    }
  }
  throw new WebhookVerificationError();
}
