from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any


class PerataError(Exception):
    """A request the API refused.

    ``code`` is the API's: invalid_credential, forbidden, not_found,
    invalid_request, conflict, idempotency_conflict, body_too_large or
    unavailable; the usage ingestion adds invalid_events and event_conflict.
    ``fields`` says, for invalid_request, what is wrong with each field.
    ``record`` is, for the usage ingestion, the position (from 1) in the batch
    of the event the API refused, and 0 for any other error. ``retry_after`` is
    how many seconds to wait on a 429.
    """

    def __init__(self, status: int, code: str, message: str = "", fields: dict[str, list[str]] | None = None, retry_after: int | None = None, record: int = 0) -> None:
        super().__init__(f"perata: {status} {code}: {message}" if message else f"perata: {status} {code}")
        self.status = status
        self.code = code
        self.message = message
        self.fields = fields or {}
        self.retry_after = retry_after
        self.record = record

    @classmethod
    def from_response(cls, status: int, headers: Mapping[str, str], body: bytes) -> PerataError:
        data: dict[str, Any] = {}
        try:
            loaded = json.loads(body or b"{}")
            if isinstance(loaded, dict):
                data = loaded
        except ValueError:
            pass  # A refusal without a JSON body is still a refusal.
        # The API's errors are the problem itself; the usage ingestion's are
        # wrapped in data, as its answers are.
        wrapped = data.get("data")
        if "error" not in data and isinstance(wrapped, dict):
            data = wrapped
        retry_after = headers.get("retry-after", "")
        record = data.get("record")
        return cls(status, data.get("error", ""), data.get("message", ""), data.get("fields") or {}, int(retry_after) if retry_after.isdigit() else None, record if isinstance(record, int) else 0)
