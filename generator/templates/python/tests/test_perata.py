import json
import unittest
from urllib.parse import parse_qs, urlparse

from perata import (
    IdentifiersWebhookEvent,
    OrderWebhookEvent,
    Perata,
    PerataError,
    UnknownWebhookEvent,
    WebhookVerificationError,
    verify_webhook,
    verify_webhook_signature,
)

# The webhook vectors every SDK checks: Standard Webhooks' own example, and
# Peráta events signed under two secrets, as while one is rotated.
REFERENCE_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
OLD_SECRET = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
NEW_SECRET = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
ORDER_PAID = b'{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}'
USAGE_RECORDED = b'{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}'
PAYOUT_SENT = b'{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}'
SIGNED_AT = 1792670400


def webhook_headers(webhook_id, at, signature):
    return {"Webhook-Id": webhook_id, "webhook-timestamp": str(at), "webhook-signature": signature}


def product(identifier):
    return {"id": identifier, "name": "Curso", "description": "", "status": "active", "created_at": "2026-10-17T00:00:00Z"}


class Recorder:
    def __init__(self, answer):
        self.answer = answer
        self.seen = []

    def __call__(self, method, url, headers, body, timeout):
        request = {"method": method, "url": urlparse(url), "headers": headers, "body": body}
        self.seen.append(request)
        status, payload, extra = self.answer(request)
        return status, extra, b"" if payload is None else json.dumps(payload).encode()


def client(answer):
    recorder = Recorder(answer)
    return Perata("prk_test_key", base_url="http://perata.test/", transport=recorder), recorder


class PerataTest(unittest.TestCase):
    def test_a_call_carries_the_key_and_unwraps_the_data(self):
        perata, recorder = client(lambda request: (200, {"data": product("prod_1")}, {}))
        got = perata.products.get("prod_1")
        self.assertEqual(got.id, "prod_1")
        self.assertEqual(got.status, "active")
        seen = recorder.seen[0]
        self.assertEqual(seen["method"], "GET")
        self.assertEqual(seen["url"].path, "/api/v1/products/prod_1")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer prk_test_key")

    def test_a_write_sends_its_body_and_idempotency_key(self):
        perata, recorder = client(lambda request: (201, {"data": product("prod_1")}, {}))
        perata.products.create({"name": "Curso"}, idempotency_key="create-1")
        seen = recorder.seen[0]
        self.assertEqual(seen["method"], "POST")
        self.assertEqual(seen["headers"]["Idempotency-Key"], "create-1")
        self.assertEqual(json.loads(seen["body"]), {"name": "Curso"})

    def test_iterating_walks_every_page(self):
        def answer(request):
            page = parse_qs(request["url"].query)["page"][0]
            return 200, {"data": {"items": [product(f"prod_{page}")], "pagination": {"total_count": 3, "max_page": 3}}}, {}

        perata, recorder = client(answer)
        self.assertEqual([item.id for item in perata.products.list_iter(limit=1)], ["prod_1", "prod_2", "prod_3"])
        self.assertEqual(parse_qs(recorder.seen[0]["url"].query)["limit"], ["1"])

    def test_a_refusal_is_a_typed_error(self):
        def answer(request):
            if request["url"].path == "/api/v1/customers":
                return 422, {"error": "invalid_request", "fields": {"email": ["send an e-mail"]}}, {}
            return 429, None, {"retry-after": "7"}

        perata, _ = client(answer)
        with self.assertRaises(PerataError) as refused:
            perata.customers.create({"name": "x", "email": "x"})
        self.assertEqual((refused.exception.status, refused.exception.code), (422, "invalid_request"))
        self.assertEqual(refused.exception.fields["email"], ["send an e-mail"])
        with self.assertRaises(PerataError) as limited:
            perata.products.list()
        self.assertEqual((limited.exception.status, limited.exception.retry_after), (429, 7))

    def test_the_standard_webhooks_vector_verifies(self):
        body = b'{"test": 2432232314}'
        headers = webhook_headers("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
        verify_webhook_signature(REFERENCE_SECRET, headers, body, now=1614265330)
        for secret, payload, now in [
            (REFERENCE_SECRET, body + b" ", 1614265330),
            (REFERENCE_SECRET, body, 1614265330 + 301),
            (NEW_SECRET, body, 1614265330),
        ]:
            with self.assertRaises(WebhookVerificationError):
                verify_webhook_signature(secret, headers, payload, now=now)

    def test_a_webhook_answers_its_typed_event(self):
        now = SIGNED_AT + 120
        headers = webhook_headers("msg_2", SIGNED_AT, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
        for secret in (NEW_SECRET, OLD_SECRET):
            event = verify_webhook(secret, headers, ORDER_PAID, now=now)
            self.assertIsInstance(event, OrderWebhookEvent)
            assert isinstance(event, OrderWebhookEvent)
            self.assertEqual((event.type, event.data.id, event.data.installments, event.data.installment_interest_cents), ("order.paid", "ord_1", 3, 360))
        with self.assertRaises(WebhookVerificationError):
            verify_webhook(REFERENCE_SECRET, headers, ORDER_PAID, now=now)
        usage = verify_webhook(NEW_SECRET, webhook_headers("msg_3", SIGNED_AT, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), USAGE_RECORDED, now=now)
        self.assertIsInstance(usage, IdentifiersWebhookEvent)
        self.assertEqual((usage.id, usage.data["merchant_id"]), ("msg_3", "mer_1"))
        unknown = verify_webhook(NEW_SECRET, webhook_headers("msg_4", SIGNED_AT, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), PAYOUT_SENT.decode(), now=now)
        self.assertIsInstance(unknown, UnknownWebhookEvent)
        self.assertEqual((unknown.type, unknown.data), ("payout.sent", {"payout_id": "po_1", "amount_cents": 5000}))


if __name__ == "__main__":
    unittest.main()
