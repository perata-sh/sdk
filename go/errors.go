package perata

import (
	"fmt"
	"time"
)

// Error is a request the API refused. Code is the API's: invalid_credential,
// forbidden, not_found, invalid_request, conflict, idempotency_conflict,
// body_too_large or unavailable. Fields says, for invalid_request, what is
// wrong with each field. RetryAfter is how long to wait on a 429.
type Error struct {
	StatusCode int
	Code       string
	Message    string
	Fields     map[string][]string
	RetryAfter time.Duration
}

func (e *Error) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("perata: %d %s: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("perata: %d %s", e.StatusCode, e.Code)
}
