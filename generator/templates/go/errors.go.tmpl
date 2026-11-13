package perata

import (
	"fmt"
	"time"
)

// Error is a request the API refused. Code is the API's: invalid_credential,
// forbidden, not_found, invalid_request, conflict, idempotency_conflict,
// body_too_large or unavailable; the usage ingestion adds invalid_events and
// event_conflict. Fields says, for invalid_request, what is wrong with each
// field. Record is, for the usage ingestion, the position (from 1) in the
// batch of the event the API refused, and 0 for any other error. RetryAfter is
// how long to wait on a 429.
type Error struct {
	StatusCode int
	Code       string
	Message    string
	Fields     map[string][]string
	Record     int
	RetryAfter time.Duration
}

func (e *Error) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("perata: %d %s: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("perata: %d %s", e.StatusCode, e.Code)
}
