package perata

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// Error is a request the API refused. Code is the API's: invalid_credential,
// forbidden, not_found, invalid_request, conflict, idempotency_conflict,
// unsupported_media_type, body_too_large, rate_limited or unavailable. Fields says, for invalid_request, what is wrong with each
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

// Error says the status, the code and why: the API's message, or, when it
// sent none, each field with its first message, so a log line carries the
// reason without the body.
func (e *Error) Error() string {
	detail := e.Message
	if detail == "" {
		detail = fieldsSummary(e.Fields)
	}
	if detail != "" {
		return fmt.Sprintf("perata: %d %s: %s", e.StatusCode, e.Code, detail)
	}
	return fmt.Sprintf("perata: %d %s", e.StatusCode, e.Code)
}

// fieldsSummary is "field: message; field: message", in the fields' order.
func fieldsSummary(fields map[string][]string) string {
	keys := make([]string, 0, len(fields))
	for k, messages := range fields {
		if len(messages) > 0 {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+": "+fields[k][0])
	}
	return strings.Join(parts, "; ")
}
