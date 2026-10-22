package perata

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func server(t *testing.T, handle func(w http.ResponseWriter, r *http.Request)) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(handle))
	t.Cleanup(srv.Close)
	return New("prk_test_key", WithBaseURL(srv.URL))
}

func TestACallCarriesTheKeyAndUnwrapsTheData(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer prk_test_key" || r.URL.Path != "/api/v1/products/prod_1" || r.Method != http.MethodGet {
			t.Errorf("request %s %s %q", r.Method, r.URL.Path, r.Header.Get("Authorization"))
		}
		fmt.Fprint(w, `{"data":{"id":"prod_1","name":"Curso","description":"","status":"active","created_at":"2026-10-17T00:00:00Z"}}`)
	})
	product, err := client.Products.Get(context.Background(), "prod_1")
	if err != nil || product.ID != "prod_1" || product.Status != ProductStatusActive {
		t.Fatalf("product %+v, %v", product, err)
	}
}

func TestAWriteSendsItsBodyAndIdempotencyKey(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if r.Method != http.MethodPost || r.Header.Get("Idempotency-Key") != "create-1" || body["name"] != "Curso" {
			t.Errorf("request %s %q %v", r.Method, r.Header.Get("Idempotency-Key"), body)
		}
		if _, sent := body["description"]; sent {
			t.Error("an optional field left out was sent")
		}
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"id":"prod_1","name":"Curso","description":"","status":"active","created_at":"2026-10-17T00:00:00Z"}}`)
	})
	product, err := client.Products.Create(context.Background(), ProductsCreateParams{Name: "Curso"}, WithIdempotencyKey("create-1"))
	if err != nil || product.Name != "Curso" {
		t.Fatalf("product %+v, %v", product, err)
	}
}

func TestIteratingWalksEveryPage(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		if r.URL.Query().Get("limit") != "1" {
			t.Errorf("limit %q", r.URL.Query().Get("limit"))
		}
		fmt.Fprintf(w, `{"data":{"items":[{"id":"prod_%d","name":"P","description":"","status":"active","created_at":"2026-10-17T00:00:00Z"}],"pagination":{"total_count":3,"max_page":3}}}`, page)
	})
	var ids []string
	for product, err := range client.Products.ListIter(context.Background(), &ProductsListParams{Limit: 1}) {
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, product.ID)
	}
	if fmt.Sprint(ids) != "[prod_1 prod_2 prod_3]" {
		t.Fatalf("walked %v", ids)
	}
}

func TestARefusalIsATypedError(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/customers" {
			w.WriteHeader(http.StatusUnprocessableEntity)
			fmt.Fprint(w, `{"error":"invalid_request","fields":{"email":["send an e-mail"]}}`)
			return
		}
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(http.StatusTooManyRequests)
	})
	_, err := client.Customers.Create(context.Background(), CustomersCreateParams{Name: "x", Email: "x"})
	var refused *Error
	if !errors.As(err, &refused) || refused.StatusCode != 422 || refused.Code != "invalid_request" || refused.Fields["email"][0] != "send an e-mail" {
		t.Fatalf("error %#v", err)
	}
	_, err = client.Products.List(context.Background(), nil)
	if !errors.As(err, &refused) || refused.StatusCode != 429 || refused.RetryAfter != 7*time.Second {
		t.Fatalf("error %#v", err)
	}
}

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const (
	referenceSecret    = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	referenceSignature = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
	oldSecret          = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
	newSecret          = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
	orderPaid          = `{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}`
	usageRecorded      = `{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}`
	payoutSent         = `{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}`
	signedAt           = 1792670400
)

func webhookHeader(id string, at int64, signature string) http.Header {
	h := http.Header{}
	h.Set("Webhook-Id", id)
	h.Set("webhook-timestamp", strconv.FormatInt(at, 10))
	h.Set("webhook-signature", signature)
	return h
}

func TestTheStandardWebhooksVectorVerifies(t *testing.T) {
	body := []byte(`{"test": 2432232314}`)
	header := webhookHeader("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, referenceSignature)
	if err := verifyWebhookSignatureAt(referenceSecret, header, body, time.Unix(1614265330, 0)); err != nil {
		t.Fatal(err)
	}
	if err := verifyWebhookSignatureAt(referenceSecret, header, append(body, ' '), time.Unix(1614265330, 0)); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a changed body verified")
	}
	if err := verifyWebhookSignatureAt(referenceSecret, header, body, time.Unix(1614265330+301, 0)); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a stale webhook verified")
	}
	if err := verifyWebhookSignatureAt(newSecret, header, body, time.Unix(1614265330, 0)); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("another secret verified")
	}
}

func TestAWebhookAnswersItsTypedEvent(t *testing.T) {
	now := time.Unix(signedAt+120, 0)
	header := webhookHeader("msg_2", signedAt, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
	for _, secret := range []string{newSecret, oldSecret} {
		event, err := verifyWebhookAt(secret, header, []byte(orderPaid), now)
		order, ok := event.(*OrderWebhookEvent)
		if err != nil || !ok || order.Type != "order.paid" || order.Data.ID != "ord_1" || order.Data.Installments != 3 || order.Data.InstallmentInterestCents != 360 {
			t.Fatalf("event %#v, %v", event, err)
		}
	}
	if _, err := verifyWebhookAt(referenceSecret, header, []byte(orderPaid), now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a secret that signed nothing verified")
	}
	event, err := verifyWebhookAt(newSecret, webhookHeader("msg_3", signedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), []byte(usageRecorded), now)
	usage, ok := event.(*IdentifiersWebhookEvent)
	if err != nil || !ok || usage.Message().ID != "msg_3" || usage.Data["merchant_id"] != "mer_1" {
		t.Fatalf("event %#v, %v", event, err)
	}
	event, err = verifyWebhookAt(newSecret, webhookHeader("msg_4", signedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), []byte(payoutSent), now)
	unknown, ok := event.(*UnknownWebhookEvent)
	if err != nil || !ok || unknown.Type != "payout.sent" || string(unknown.Data) != `{"payout_id":"po_1","amount_cents":5000}` {
		t.Fatalf("event %#v, %v", event, err)
	}
}
