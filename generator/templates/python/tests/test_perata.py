import base64
import hashlib
import hmac
import json
import unittest
from urllib.parse import parse_qs, urlparse

from perata import Perata, PerataError, WebhookVerificationError, verify_webhook


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

    def test_a_webhook_verifies_only_when_perata_signed_it(self):
        key = b"0123456789abcdef0123456789abcdef"
        secret = "whsec_" + base64.b64encode(key).decode()
        body = b'{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}'
        now = 1_800_000_000

        def sign(at, payload):
            mac = hmac.new(key, f"msg_1.{at}.".encode() + payload, hashlib.sha256).digest()
            return {"webhook-id": "msg_1", "webhook-timestamp": str(at), "webhook-signature": "v1,bm90LXRoaXMtb25l v1," + base64.b64encode(mac).decode()}

        event = verify_webhook(secret, sign(now, body), body, now=now)
        self.assertEqual(event.type, "checkout_session.succeeded")
        self.assertEqual(event.data["checkout_session_id"], "cs_1")
        with self.assertRaises(WebhookVerificationError):
            verify_webhook(secret, sign(now, body), body + b" ", now=now)
        with self.assertRaises(WebhookVerificationError):
            verify_webhook(secret, sign(now - 600, body), body, now=now)


if __name__ == "__main__":
    unittest.main()
