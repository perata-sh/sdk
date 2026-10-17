package perata

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
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

func TestAWebhookVerifiesOnlyWhenPerataSignedIt(t *testing.T) {
	key := []byte("0123456789abcdef0123456789abcdef")
	secret := "whsec_" + base64.StdEncoding.EncodeToString(key)
	body := []byte(`{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}`)
	now := time.Unix(1_800_000_000, 0)
	sign := func(id string, at time.Time, payload []byte) http.Header {
		mac := hmac.New(sha256.New, key)
		fmt.Fprintf(mac, "%s.%d.", id, at.Unix())
		mac.Write(payload)
		h := http.Header{}
		h.Set("webhook-id", id)
		h.Set("webhook-timestamp", strconv.FormatInt(at.Unix(), 10))
		h.Set("webhook-signature", "v1,bm90LXRoaXMtb25l v1,"+base64.StdEncoding.EncodeToString(mac.Sum(nil)))
		return h
	}
	event, err := verifyWebhookAt(secret, sign("msg_1", now, body), body, now)
	if err != nil || event.Type != "checkout_session.succeeded" || event.Data["checkout_session_id"] != "cs_1" {
		t.Fatalf("event %+v, %v", event, err)
	}
	if _, err := verifyWebhookAt(secret, sign("msg_1", now, body), append(body, ' '), now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a changed body verified")
	}
	if _, err := verifyWebhookAt(secret, sign("msg_1", now.Add(-10*time.Minute), body), body, now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a stale webhook verified")
	}
}
