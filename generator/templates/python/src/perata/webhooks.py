"""Verifying the webhooks Peráta sends, as Standard Webhooks signs them."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import time
from collections.abc import Mapping
from dataclasses import dataclass

WEBHOOK_TOLERANCE_SECONDS = 300
"""How far from now a webhook's timestamp may be."""


class WebhookVerificationError(Exception):
    """A request Peráta did not sign, or signed too long ago."""

    def __init__(self, message: str = "perata: webhook signature does not verify") -> None:
        super().__init__(message)


@dataclass(frozen=True)
class WebhookEvent:
    """What Peráta posts to an endpoint."""

    id: str
    type: str
    timestamp: str
    data: dict[str, str]


def _header(headers: Mapping[str, str], name: str) -> str:
    for key, value in headers.items():
        if key.lower() == name:
            return value
    return ""


def verify_webhook(secret: str, headers: Mapping[str, str], body: bytes | str, now: float | None = None) -> WebhookEvent:
    """Checks a webhook Peráta sent and answers its event.

    The signature is an HMAC-SHA256 of ``{webhook-id}.{webhook-timestamp}.{body}``
    under the key the endpoint's ``whsec_`` secret encodes. Pass the body
    exactly as it arrived, before parsing it.
    """
    try:
        key = base64.b64decode(secret.removeprefix("whsec_"), validate=True)
    except (binascii.Error, ValueError):
        key = b""
    if not key:
        raise ValueError("perata: the webhook secret is whsec_ and a base64 key")
    raw = body.encode() if isinstance(body, str) else body
    webhook_id = _header(headers, "webhook-id")
    stamp = _header(headers, "webhook-timestamp")
    if not webhook_id or not stamp.isdigit():
        raise WebhookVerificationError()
    if abs((time.time() if now is None else now) - int(stamp)) > WEBHOOK_TOLERANCE_SECONDS:
        raise WebhookVerificationError()
    expected = hmac.new(key, f"{webhook_id}.{stamp}.".encode() + raw, hashlib.sha256).digest()
    for signature in _header(headers, "webhook-signature").split():
        version, _, encoded = signature.partition(",")
        if version != "v1":
            continue
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            continue
        if hmac.compare_digest(decoded, expected):
            event = json.loads(raw)
            return WebhookEvent(id=event["id"], type=event["type"], timestamp=event["timestamp"], data=event.get("data") or {})
    raise WebhookVerificationError()
