package perata

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// WebhookEvent is what Peráta posts to an endpoint.
type WebhookEvent struct {
	ID        string            `json:"id"`
	Type      string            `json:"type"`
	Timestamp string            `json:"timestamp"`
	Data      map[string]string `json:"data"`
}

// ErrWebhookSignature is a request Peráta did not sign, or signed too long ago.
var ErrWebhookSignature = errors.New("perata: webhook signature does not verify")

// WebhookTolerance is how far from now a webhook's timestamp may be.
const WebhookTolerance = 5 * time.Minute

// VerifyWebhook checks a webhook Peráta sent, as Standard Webhooks signs it --
// an HMAC-SHA256 of "{webhook-id}.{webhook-timestamp}.{body}" under the key
// the endpoint's whsec_ secret encodes -- and answers its event. Read the
// body raw and verify before parsing it.
func VerifyWebhook(secret string, header http.Header, body []byte) (*WebhookEvent, error) {
	return verifyWebhookAt(secret, header, body, time.Now())
}

func verifyWebhookAt(secret string, header http.Header, body []byte, now time.Time) (*WebhookEvent, error) {
	key, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(secret, "whsec_"))
	if err != nil || len(key) == 0 {
		return nil, errors.New("perata: the webhook secret is whsec_ and a base64 key")
	}
	id, stamp := header.Get("webhook-id"), header.Get("webhook-timestamp")
	seconds, err := strconv.ParseInt(stamp, 10, 64)
	if id == "" || err != nil {
		return nil, ErrWebhookSignature
	}
	if delta := now.Sub(time.Unix(seconds, 0)); delta > WebhookTolerance || delta < -WebhookTolerance {
		return nil, ErrWebhookSignature
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(id + "." + stamp + "."))
	mac.Write(body)
	expected := mac.Sum(nil)
	for _, signature := range strings.Fields(header.Get("webhook-signature")) {
		version, encoded, ok := strings.Cut(signature, ",")
		if !ok || version != "v1" {
			continue
		}
		decoded, err := base64.StdEncoding.DecodeString(encoded)
		if err == nil && hmac.Equal(decoded, expected) {
			var event WebhookEvent
			if err := json.Unmarshal(body, &event); err != nil {
				return nil, err
			}
			return &event, nil
		}
	}
	return nil, ErrWebhookSignature
}
