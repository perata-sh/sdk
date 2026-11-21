package perata

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
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

// The server creates the session and hands the browser its client_secret; the
// answer carries the secret once, and a replay of the same Idempotency-Key
// carries it empty.
func TestACheckoutSessionHandsBackTheClientSecretForTheBrowser(t *testing.T) {
	replayed := false
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/checkouts" || r.Header.Get("Idempotency-Key") != "pedido-1" ||
			body["product_id"] != "prod_1" || body["price_id"] != "price_1" || body["success_url"] != "https://loja.example/obrigado" {
			t.Errorf("request %s %s %q %v", r.Method, r.URL.Path, r.Header.Get("Idempotency-Key"), body)
		}
		secret := "cs_secret_1"
		if replayed {
			w.Header().Set("Idempotent-Replayed", "true")
			secret = ""
		}
		w.WriteHeader(http.StatusCreated)
		fmt.Fprintf(w, `{"data":{"id":"pcl_1","url":"https://perata.sh/pagamento/pcl_1","product_id":"prod_1","price_id":"price_1","status":"active","label":"","quantity":1,"success_url":"https://loja.example/obrigado","cancel_url":"","expires_at":null,"created_at":"2026-11-16T12:00:00Z","session_id":"cs_1","client_secret":%q,"client_secret_expires_at":"2026-11-16T12:30:00Z","status_key":"sk_1","amount_cents":null,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1"}}`, secret)
	})
	ctx := context.Background()
	successURL := "https://loja.example/obrigado"
	params := CheckoutsCreateParams{ProductID: "prod_1", PriceID: "price_1", SuccessURL: &successURL}
	checkout, err := client.Checkouts.Create(ctx, params, WithIdempotencyKey("pedido-1"))
	if err != nil || checkout.ClientSecret != "cs_secret_1" || checkout.SessionID != "cs_1" || checkout.StatusKey != "sk_1" ||
		checkout.ClientSecretExpiresAt != "2026-11-16T12:30:00Z" || checkout.URL != "https://perata.sh/pagamento/pcl_1" || checkout.ExpiresAt != nil {
		t.Fatalf("checkout %+v, %v", checkout, err)
	}
	replayed = true
	again, err := client.Checkouts.Create(ctx, params, WithIdempotencyKey("pedido-1"))
	if err != nil || again.ClientSecret != "" || again.SessionID != "cs_1" || again.StatusKey != "sk_1" {
		t.Fatalf("replay %+v, %v", again, err)
	}
}

// A model that may be null decodes both ways: the session as the buyer's browser
// reads it has no customer, discount or payment until there is one.
func TestASessionAsTheBrowserReadsItDecodesItsNullableModels(t *testing.T) {
	var empty, filled CheckoutClient
	if err := json.Unmarshal([]byte(`{"customer":null,"discount":null,"payment":null}`), &empty); err != nil {
		t.Fatal(err)
	}
	if empty.Customer != nil || empty.Discount != nil || empty.Payment != nil {
		t.Fatalf("empty %+v", empty)
	}
	raw := `{"customer":{"email":"ana@exemplo.com"},"payment":{"pix":{"copia_e_cola":"000201"},"boleto":null}}`
	if err := json.Unmarshal([]byte(raw), &filled); err != nil {
		t.Fatal(err)
	}
	if filled.Customer == nil || filled.Customer.Email != "ana@exemplo.com" || filled.Payment == nil || filled.Payment.Boleto != nil || filled.Payment.Pix == nil {
		t.Fatalf("filled %+v", filled)
	}
}

func TestUsageIngestionCarriesTheSourceCredentialAndItsEvents(t *testing.T) {
	var seen *http.Request
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r
		var body struct {
			Events []map[string]any `json:"events"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		event := body.Events[0]
		cost, _ := event["_cost"].(map[string]any)
		if len(body.Events) != 1 || event["customer_id"] != "cus_1" || event["external_event_id"] != "req-1" || event["input_tokens"] != "1200" ||
			cost["amount"] != "1.250000" || cost["currency"] != "brl" || event["parent_id"] != nil {
			t.Errorf("body %v", body)
		}
		if _, sent := event["_llm"]; sent {
			t.Error("an optional object left out was sent")
		}
		fmt.Fprint(w, `{"data":{"created":1,"replayed":0}}`)
	}))
	t.Cleanup(srv.Close)
	usage := New("pus_live_source", WithBaseURL(srv.URL))
	event := UsageIngestEvent{
		CustomerID: "cus_1", ExternalEventID: "req-1", InputTokens: "1200", OutputTokens: "300", CachedTokens: "0",
		OccurredAt: "2026-11-13T12:00:00Z", Cost: &UsageIngestEventCost{Amount: "1.250000", Currency: "brl"},
	}
	receipt, err := usage.Usage.Ingest(context.Background(), UsageIngestParams{Events: []UsageIngestEvent{event}})
	if err != nil || receipt.Created != 1 || receipt.Replayed != 0 {
		t.Fatalf("receipt %+v, %v", receipt, err)
	}
	if seen.Method != http.MethodPost || seen.URL.Path != "/api/v1/usage/token-events" || seen.Header.Get("Authorization") != "Bearer pus_live_source" {
		t.Errorf("request %s %s %q", seen.Method, seen.URL.Path, seen.Header.Get("Authorization"))
	}
}

func TestUsageIngestionErrorsAreTheFlatErrorDocument(t *testing.T) {
	for _, tc := range []struct {
		status          int
		body, code      string
		record          int
		message         string
		fields          string
		retryAfterAsked bool
	}{
		{status: 401, body: `{"error":"invalid_credential"}`, code: "invalid_credential"},
		{status: 409, body: `{"error":"conflict","record":2,"message":"conflict"}`, code: "conflict", record: 2, message: "conflict"},
		{status: 422, body: `{"error":"invalid_request","record":3,"message":"validation failed: customer_id","fields":{"customer_id":["unknown"]}}`, code: "invalid_request", record: 3, message: "validation failed: customer_id", fields: "[unknown]"},
		{status: 400, body: `{"error":"invalid_request","message":"malformed JSON"}`, code: "invalid_request", message: "malformed JSON"},
		{status: 415, body: `{"error":"unsupported_media_type"}`, code: "unsupported_media_type"},
		{status: 500, body: `{"error":"unavailable"}`, code: "unavailable"},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(tc.status)
			fmt.Fprint(w, tc.body)
		}))
		usage := New("pus_test_source", WithBaseURL(srv.URL))
		event := UsageIngestEvent{CustomerID: "cus_1", ExternalEventID: "req-1", InputTokens: "1", OutputTokens: "0", CachedTokens: "0", OccurredAt: "2026-11-13T12:00:00Z"}
		_, err := usage.Usage.Ingest(context.Background(), UsageIngestParams{Events: []UsageIngestEvent{event}})
		srv.Close()
		var apiErr *Error
		if !errors.As(err, &apiErr) || apiErr.StatusCode != tc.status || apiErr.Code != tc.code || apiErr.Record != tc.record || apiErr.Message != tc.message {
			t.Fatalf("%d: error %#v", tc.status, err)
		}
		if tc.fields != "" && fmt.Sprint(apiErr.Fields["customer_id"]) != tc.fields {
			t.Fatalf("%d: fields %v", tc.status, apiErr.Fields)
		}
	}
}

func TestAnErrorWrappedInDataByAnOlderServerIsStillRead(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(409)
		fmt.Fprint(w, `{"data":{"error":"event_conflict","record":2,"message":"conflict"}}`)
	}))
	defer srv.Close()
	usage := New("pus_test_source", WithBaseURL(srv.URL))
	event := UsageIngestEvent{CustomerID: "cus_1", ExternalEventID: "req-1", InputTokens: "1", OutputTokens: "0", CachedTokens: "0", OccurredAt: "2026-11-13T12:00:00Z"}
	_, err := usage.Usage.Ingest(context.Background(), UsageIngestParams{Events: []UsageIngestEvent{event}})
	var apiErr *Error
	if !errors.As(err, &apiErr) || apiErr.StatusCode != 409 || apiErr.Code != "event_conflict" || apiErr.Record != 2 || apiErr.Message != "conflict" {
		t.Fatalf("error %#v", err)
	}
}

func TestABaseURLMustBeHTTPSUnlessItIsLoopback(t *testing.T) {
	for base, ok := range map[string]bool{
		"https://perata.sh": true, "http://localhost:8080": true, "http://LOCALHOST": true, "http://127.0.0.1:1": true,
		"http://127.255.0.3": true, "http://[::1]:8080": true,
		"http://perata.sh": false, "http://localhost.evil.test": false, "http://127.0.0.1.evil.test": false,
		"http://10.0.0.1": false, "ftp://localhost": false, "perata.sh": false, "": false, "http://[::2]": false,
	} {
		if got := checkBaseURL(base) == nil; got != ok {
			t.Errorf("%q accepted: %v, want %v", base, got, ok)
		}
	}
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
	t.Cleanup(srv.Close)
	client := New("prk_test_key", WithBaseURL("http://perata.test"))
	if _, err := client.Products.Get(context.Background(), "prod_1"); !errors.Is(err, ErrInsecureBaseURL) || called {
		t.Fatalf("error %v, called %v", err, called)
	}
}

func TestADiscountGoesThroughCreateGetListAndDelete(t *testing.T) {
	discount := func(id string) string {
		return fmt.Sprintf(`{"id":"%s","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}`, id)
	}
	var seen []string
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Method+" "+r.URL.Path)
		switch {
		case r.Method == http.MethodPost:
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["name"] != "Black" || body["type"] != "percentage" || body["basis_points"] != float64(1000) {
				t.Errorf("body %v", body)
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprintf(w, `{"data":%s}`, discount("disc_1"))
		case r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/api/v1/discounts":
			page, _ := strconv.Atoi(r.URL.Query().Get("page"))
			fmt.Fprintf(w, `{"data":{"items":[%s],"pagination":{"total_count":2,"max_page":2}}}`, discount(fmt.Sprintf("disc_%d", page)))
		default:
			fmt.Fprintf(w, `{"data":%s}`, discount("disc_1"))
		}
	})
	ctx := context.Background()
	basisPoints := int64(1000)
	created, err := client.Discounts.Create(ctx, DiscountsCreateParams{Name: "Black", Type: "percentage", Duration: "once", BasisPoints: &basisPoints})
	if err != nil || created.ID != "disc_1" || created.Code != nil || created.ProductIds[0] != "prod_1" {
		t.Fatalf("created %+v, %v", created, err)
	}
	if got, err := client.Discounts.Get(ctx, "disc_1"); err != nil || got.Name != "Black" {
		t.Fatalf("got %+v, %v", got, err)
	}
	var ids []string
	for each, err := range client.Discounts.ListIter(ctx, &DiscountsListParams{Limit: 1}) {
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, each.ID)
	}
	if fmt.Sprint(ids) != "[disc_1 disc_2]" {
		t.Fatalf("walked %v", ids)
	}
	if err := client.Discounts.Delete(ctx, "disc_1"); err != nil {
		t.Fatal(err)
	}
	if got := fmt.Sprint(seen); got != "[POST /api/v1/discounts GET /api/v1/discounts/disc_1 GET /api/v1/discounts GET /api/v1/discounts DELETE /api/v1/discounts/disc_1]" {
		t.Fatalf("requests %v", got)
	}
}

func TestAFreeFormValueDecodesNested(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"data":{"id": "cus_1", "name": "Ana", "email": "ana@example.com", "external_id": "", "status": "active", "created_at": "2026-10-17T00:00:00Z", "active_subscriptions": [], "granted_benefits": [{"id": "gr_1", "granted_at": "2026-10-17T00:00:00Z", "benefit_id": "ben_1", "benefit_type": "feature_flag", "benefit_metadata": {"flags": {"beta": true, "limits": {"seats": 5, "tiers": ["a", 2, null, 1.5]}}}, "properties": {"links": [{"url": "https://example.com", "expires": null}]}}]}}`)
	})
	state, err := client.Customers.GetState(context.Background(), "cus_1")
	if err != nil {
		t.Fatal(err)
	}
	grant := state.GrantedBenefits[0]
	limits := grant.BenefitMetadata["flags"].(map[string]any)["limits"].(map[string]any)
	tiers := limits["tiers"].([]any)
	link := grant.Properties["links"].([]any)[0].(map[string]any)
	if grant.BenefitMetadata["flags"].(map[string]any)["beta"] != true || limits["seats"] != float64(5) ||
		tiers[0] != "a" || tiers[1] != float64(2) || tiers[2] != nil || tiers[3] != 1.5 || link["url"] != "https://example.com" || link["expires"] != nil {
		t.Fatalf("decoded %v %v", grant.BenefitMetadata, grant.Properties)
	}
}

func TestAPostWithoutAKeyIsSentWithItsOwn(t *testing.T) {
	var keys []string
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		keys = append(keys, r.Method+" "+r.Header.Get("Idempotency-Key"))
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"id":"prod_1","name":"Curso","description":"","status":"active","created_at":"2026-10-17T00:00:00Z"}}`)
	})
	for range 2 {
		if _, err := client.Products.Create(context.Background(), ProductsCreateParams{Name: "Curso"}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := client.Products.Create(context.Background(), ProductsCreateParams{Name: "Curso"}, WithIdempotencyKey("mine")); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Products.Get(context.Background(), "prod_1"); err != nil {
		t.Fatal(err)
	}
	uuid := regexp.MustCompile(`^POST [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	if !uuid.MatchString(keys[0]) || !uuid.MatchString(keys[1]) || keys[0] == keys[1] || keys[2] != "POST mine" || keys[3] != "GET " {
		t.Fatalf("keys %q", keys)
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

// The metadata filter is one pair a key, metadata[key]=value, the keys sorted
// and escaped, and the server reads each pair back; every page of a walk keeps
// the filter.
func TestAMetadataFilterIsSentAsOnePairAKey(t *testing.T) {
	var queries []string
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		queries = append(queries, r.URL.RawQuery)
		if got := r.URL.Query(); got.Get("metadata[pedido]") != "123" || got.Get("metadata[camera id]") != "a/b" {
			t.Errorf("the server reads %v", got)
		}
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		fmt.Fprintf(w, `{"data":{"items":[],"pagination":{"total_count":0,"max_page":%d}}}`, max(page, 1))
	})
	metadata := map[string]string{"pedido": "123", "camera id": "a/b"}
	if _, err := client.Orders.List(context.Background(), &OrdersListParams{ClientReferenceID: "pedido-1", Metadata: metadata}); err != nil {
		t.Fatal(err)
	}
	want := "client_reference_id=pedido-1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123"
	if queries[0] != want {
		t.Fatalf("query %q, want %q", queries[0], want)
	}
	for _, err := range client.Checkouts.ListIter(context.Background(), &CheckoutsListParams{Limit: 1, Metadata: metadata}) {
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(queries) != 2 || queries[1] != "limit=1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123&page=1" {
		t.Fatalf("queries %q", queries)
	}
}

// A customer is found by its e-mail: the filter goes in the query.
func TestCustomersAreListedByEmail(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/customers" || r.URL.RawQuery != "email=ana%40example.com" {
			t.Errorf("request %s ? %s", r.URL.Path, r.URL.RawQuery)
		}
		fmt.Fprint(w, `{"data":{"items":[],"pagination":{"total_count":0,"max_page":1}}}`)
	})
	if _, err := client.Customers.List(context.Background(), &CustomersListParams{Email: "ana@example.com"}); err != nil {
		t.Fatal(err)
	}
}

// A graduated price goes out with its tiers and without the fixed amount, and a
// subscription reads back the quantity it bills and the order reference it came
// from; amount_cents is the cycle's total for that quantity.
func TestAGraduatedPriceCarriesItsTiersAndASubscriptionItsQuantity(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/api/v1/prices" {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			tiers, _ := body["tiers"].([]any)
			if body["pricing_model"] != "graduated" || body["interval"] != "month" || len(tiers) != 2 {
				t.Errorf("body %v", body)
			}
			first, _ := tiers[0].(map[string]any)
			last, _ := tiers[1].(map[string]any)
			if first["up_to"] != float64(1) || first["unit_amount_cents"] != float64(25000) || last["up_to"] != nil || last["unit_amount_cents"] != float64(15000) {
				t.Errorf("tiers %v", tiers)
			}
			if _, sent := body["amount_cents"]; sent {
				t.Error("a graduated price was sent with a fixed amount")
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprint(w, `{"data":{"id":"price_1","product_id":"prod_1","type":"recurring","interval":"month","interval_count":1,"currency":"BRL","status":"active","amount_cents":0,"pricing_model":"graduated","unit_amount_cents":null,"unit_label":"câmera","unit_label_plural":"câmeras","tiers":[{"up_to":1,"unit_amount_cents":25000},{"up_to":null,"unit_amount_cents":15000}]}}`)
			return
		}
		if r.URL.Path != "/api/v1/subscriptions/sub_1" {
			t.Errorf("request %s %s", r.Method, r.URL.Path)
		}
		fmt.Fprint(w, `{"data":{"id":"sub_1","amount_cents":55000,"quantity":3,"client_reference_id":"pedido-9","metadata":{"camera":"c1"},"status":"active"}}`)
	})
	model := PricePricingModelGraduated
	interval := PriceIntervalMonth
	label, plural := "câmera", "câmeras"
	one := int64(1)
	price, err := client.Prices.Create(context.Background(), PricesCreateParams{
		ProductID:       "prod_1",
		Type:            PriceTypeRecurring,
		Interval:        &interval,
		PricingModel:    &model,
		Tiers:           []PricesCreateTier{{UpTo: &one, UnitAmountCents: 25000}, {UnitAmountCents: 15000}},
		UnitLabel:       &label,
		UnitLabelPlural: &plural,
	})
	if err != nil || price.PricingModel != PricePricingModelGraduated || price.AmountCents != 0 || price.UnitAmountCents != nil || len(price.Tiers) != 2 {
		t.Fatalf("price %+v, %v", price, err)
	}
	if price.Tiers[0].UpTo == nil || *price.Tiers[0].UpTo != 1 || price.Tiers[1].UpTo != nil || price.Tiers[1].UnitAmountCents != 15000 || price.UnitLabelPlural != "câmeras" {
		t.Fatalf("tiers %+v", price.Tiers)
	}
	subscription, err := client.Subscriptions.Get(context.Background(), "sub_1")
	if err != nil || subscription.Quantity != 3 || subscription.AmountCents != 55000 || subscription.ClientReferenceID != "pedido-9" {
		t.Fatalf("subscription %+v, %v", subscription, err)
	}
}

// A checkout adds the buyer's remaining days to the first period, an extension
// goes out alone (no price_id), and the sale reads back what it took: the
// discount on the order and on the subscription, and the change scheduled for the
// next period.
func TestAFirstPeriodExtensionAndTheDiscountsTheSaleReadsBack(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		switch r.Method + " " + r.URL.Path {
		case "POST /api/v1/checkouts":
			if body["first_period_extra_days"] != float64(30) {
				t.Errorf("checkout body %v", body)
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprint(w, `{"data":{"id":"pcl_1","url":"https://perata.sh/pagamento/pcl_1","product_id":"prod_1","price_id":"price_1","status":"active","quantity":1,"first_period_extra_days":30,"discount_id":"disc_1","session_id":"cs_1","client_secret":"cs_secret_1"}}`)
		case "PATCH /api/v1/subscriptions/sub_1":
			if body["extend_current_period_days"] != float64(15) {
				t.Errorf("update body %v", body)
			}
			if _, sent := body["price_id"]; sent {
				t.Error("an extension was sent with a price_id")
			}
			fmt.Fprint(w, `{"data":{"id":"sub_1","status":"active","first_period_extra_days":30,"discount_id":"disc_1","discount_ends_at":"2027-03-01T03:00:00Z","pending_update":{"price_id":"price_2","quantity":5,"amount_cents":90000,"effective_at":"2026-12-20T03:00:00Z"}}}`)
		case "GET /api/v1/subscriptions/sub_2":
			fmt.Fprint(w, `{"data":{"id":"sub_2","status":"active","first_period_extra_days":null,"discount_id":null,"discount_ends_at":null,"pending_update":null}}`)
		case "GET /api/v1/orders/ord_1":
			fmt.Fprint(w, `{"data":{"id":"ord_1","amount_cents":9000,"subtotal_cents":10000,"discount_cents":1000,"discount_id":"disc_1","discount_code":"BEMVINDO"}}`)
		case "GET /api/v1/prices/price_1":
			fmt.Fprint(w, `{"data":{"id":"price_1","product_id":"prod_1","type":"recurring","interval":"month","interval_count":1,"currency":"BRL","status":"archived","amount_cents":9000}}`)
		default:
			t.Errorf("request %s %s", r.Method, r.URL.Path)
		}
	})
	ctx := context.Background()
	extra := int64(30)
	checkout, err := client.Checkouts.Create(ctx, CheckoutsCreateParams{ProductID: "prod_1", PriceID: "price_1", FirstPeriodExtraDays: &extra})
	if err != nil || checkout.FirstPeriodExtraDays == nil || *checkout.FirstPeriodExtraDays != 30 || checkout.DiscountID != "disc_1" {
		t.Fatalf("checkout %+v, %v", checkout, err)
	}
	days := int64(15)
	subscription, err := client.Subscriptions.Update(ctx, "sub_1", SubscriptionsUpdateParams{ExtendCurrentPeriodDays: &days})
	if err != nil || subscription.FirstPeriodExtraDays == nil || *subscription.FirstPeriodExtraDays != 30 || subscription.DiscountID == nil ||
		subscription.DiscountEndsAt == nil || *subscription.DiscountEndsAt != "2027-03-01T03:00:00Z" {
		t.Fatalf("subscription %+v, %v", subscription, err)
	}
	if pending := subscription.PendingUpdate; pending == nil || pending.PriceID != "price_2" || pending.Quantity != 5 || pending.AmountCents != 90000 || pending.EffectiveAt != "2026-12-20T03:00:00Z" {
		t.Fatalf("pending update %+v", subscription.PendingUpdate)
	}
	none, err := client.Subscriptions.Get(ctx, "sub_2")
	if err != nil || none.PendingUpdate != nil || none.FirstPeriodExtraDays != nil || none.DiscountID != nil {
		t.Fatalf("subscription without any %+v, %v", none, err)
	}
	order, err := client.Orders.Get(ctx, "ord_1")
	if err != nil || order.SubtotalCents != 10000 || order.DiscountCents != 1000 || order.DiscountID == nil || *order.DiscountID != "disc_1" || order.DiscountCode == nil || *order.DiscountCode != "BEMVINDO" {
		t.Fatalf("order %+v, %v", order, err)
	}
	price, err := client.Prices.Get(ctx, "price_1")
	if err != nil || price.ID != "price_1" || price.Status != PriceStatusArchived {
		t.Fatalf("price %+v, %v", price, err)
	}
}

// The payment reads back its fee, its net, its split and the payout that pays it.
func TestAPaymentReadsBackItsFeeItsSplitAndItsPayout(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"data":{"id":"pay_1","showcase_id":"x","checkout_id":"x","customer_id":"x","method":"card","state":"unknown","amount_cents":0,"captured_cents":0,"refunded_cents":0,"currency":"BRL","created_at":"2026-11-20T12:00:00Z","metadata":{},"client_reference_id":"x","installments":0,"installment_amount_cents":0,"installment_interest_cents":0,"subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"fee_cents":450,"net_cents":8550,"expected_payout_on":"2026-12-21","payout_deposited_on":null,"payout_id":null,"split":[{"recipient_id":"shw_2","amount_cents":9000,"fee_cents":450,"net_cents":8550}]}}`)
	})
	payment, err := client.Payments.Get(context.Background(), "pay_1")
	if err != nil || payment.FeeCents != 450 || payment.NetCents != 8550 || payment.ExpectedPayoutOn == nil || *payment.ExpectedPayoutOn != "2026-12-21" || payment.PayoutID != nil || payment.PayoutDepositedOn != nil {
		t.Fatalf("payment %+v, %v", payment, err)
	}
	if len(payment.Split) != 1 || payment.Split[0].RecipientID == nil || *payment.Split[0].RecipientID != "shw_2" || payment.Split[0].AmountCents != 9000 || payment.Split[0].FeeCents != 450 || payment.Split[0].NetCents != 8550 {
		t.Fatalf("split %+v", payment.Split)
	}
}

// The balance carries its period, the payouts are filtered and walked page by
// page, and a payout reads back its lines: a fee has no payment.
func TestTheBalanceAndThePayoutsReadBackWhatWillBeDeposited(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		switch r.URL.Path {
		case "/api/v1/balance":
			if query.Get("date_from") != "2026-11-01" || query.Get("date_to") != "2026-11-20" {
				t.Errorf("balance query %v", query)
			}
			fmt.Fprint(w, `{"data":{"total_to_receive_cents":100000,"released_cents":10000,"held_cents":5000,"scheduled_cents":60000,"later_cents":25000,"deposited_cents":42000,"period_from":"2026-11-01","period_to":"2026-11-20","currency":"BRL"}}`)
		case "/api/v1/payouts":
			if query.Get("status") != "deposited" || query.Get("date_from") != "2026-11-01" || query.Get("sorting") != "-date" || query.Get("limit") != "1" {
				t.Errorf("payouts query %v", query)
			}
			if query.Get("page") == "2" {
				fmt.Fprint(w, `{"data":{"items":[{"id":"po_20261119","status":"released","expected_on":"2026-11-19","deposited_on":null,"amount_cents":5000,"fee_cents":200,"net_cents":4800,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}`)
				return
			}
			fmt.Fprint(w, `{"data":{"items":[{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}`)
		case "/api/v1/payouts/po_20261120":
			fmt.Fprint(w, `{"data":{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2,"items":[{"kind":"sale","payment_id":"pay_1","installment":1,"status":"deposited","amount_cents":10000,"fee_cents":300,"net_cents":9700},{"kind":"fee","payment_id":null,"installment":0,"status":"deposited","amount_cents":0,"fee_cents":150,"net_cents":-150}]}}`)
		default:
			t.Errorf("request %s %s", r.Method, r.URL.Path)
		}
	})
	ctx := context.Background()
	balance, err := client.Balance.Get(ctx, &BalanceGetParams{DateFrom: "2026-11-01", DateTo: "2026-11-20"})
	if err != nil || balance.TotalToReceiveCents != 100000 || balance.ReleasedCents+balance.HeldCents+balance.ScheduledCents+balance.LaterCents != balance.TotalToReceiveCents ||
		balance.DepositedCents != 42000 || balance.PeriodFrom != "2026-11-01" || balance.PeriodTo != "2026-11-20" || balance.Currency != "BRL" {
		t.Fatalf("balance %+v, %v", balance, err)
	}
	var walked []string
	for payout, err := range client.Payouts.ListIter(ctx, &PayoutsListParams{Limit: 1, Status: PayoutStatusDeposited, DateFrom: "2026-11-01", Sorting: "-date"}) {
		if err != nil {
			t.Fatal(err)
		}
		walked = append(walked, payout.ID+":"+payout.Status)
		if payout.NetCents != payout.AmountCents-payout.FeeCents {
			t.Errorf("payout %+v", payout)
		}
		if (payout.Status == PayoutStatusDeposited) != (payout.DepositedOn != nil) {
			t.Errorf("deposited_on of %+v", payout)
		}
	}
	if fmt.Sprint(walked) != "[po_20261120:deposited po_20261119:released]" {
		t.Fatalf("walked %v", walked)
	}
	payout, err := client.Payouts.Get(ctx, "po_20261120")
	if err != nil || payout.NetCents != 9550 || len(payout.Items) != 2 {
		t.Fatalf("payout %+v, %v", payout, err)
	}
	if sale := payout.Items[0]; sale.Kind != PayoutItemKindSale || sale.PaymentID == nil || *sale.PaymentID != "pay_1" || sale.Installment != 1 || sale.NetCents != 9700 {
		t.Fatalf("sale %+v", sale)
	}
	if fee := payout.Items[1]; fee.Kind != PayoutItemKindFee || fee.PaymentID != nil || fee.NetCents != -150 {
		t.Fatalf("fee %+v", fee)
	}
}

// A checkout says how its subscription renews, the subscription reads back the
// mode it resolved to, its label and whether the buyer is written to, an update
// changes them, and the open renewal charge is read by its own route; without
// one the API answers 404 no_open_charge.
func TestTheRenewalModeTheLabelAndTheOpenCharge(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		switch r.Method + " " + r.URL.Path {
		case "POST /api/v1/checkouts":
			if body["renewal_mode"] != "automatic" || body["notify_customer_email"] != false || body["label"] != "Olho de Águia · Ana" {
				t.Errorf("checkout body %v", body)
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprint(w, `{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"Olho de Águia · Ana","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"x","first_period_extra_days":null,"renewal_mode":"automatic","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}`)
		case "PATCH /api/v1/subscriptions/sub_1":
			if body["renewal_mode"] != "manual" || body["notify_customer_email"] != true || body["label"] != "Olho de Águia · Ana" {
				t.Errorf("update body %v", body)
			}
			fmt.Fprint(w, `{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"pix_automatic","label":"Olho de Águia · Ana","notify_customer_email":false}}`)
		case "GET /api/v1/subscriptions/sub_1/open-charge":
			fmt.Fprint(w, `{"data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","reminder":null,"days_until_due":null,"notify_customer_email":true}}`)
		case "GET /api/v1/subscriptions/sub_2/open-charge":
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"error":"no_open_charge","message":"A assinatura não tem cobrança de renovação em aberto."}`)
		default:
			t.Errorf("request %s %s", r.Method, r.URL.Path)
		}
	})
	ctx := context.Background()
	mode, label, notify := "automatic", "Olho de Águia · Ana", false
	checkout, err := client.Checkouts.Create(ctx, CheckoutsCreateParams{ProductID: "prod_1", PriceID: "price_1", RenewalMode: &mode, Label: &label, NotifyCustomerEmail: &notify})
	if err != nil || checkout.RenewalMode != CheckoutCreatedRenewalModeAutomatic || checkout.NotifyCustomerEmail || checkout.Label != label {
		t.Fatalf("checkout %+v, %v", checkout, err)
	}
	manual, yes := "manual", true
	subscription, err := client.Subscriptions.Update(ctx, "sub_1", SubscriptionsUpdateParams{RenewalMode: &manual, NotifyCustomerEmail: &yes, Label: &label})
	if err != nil || subscription.RenewalMode != SubscriptionRenewalModePixAutomatic || subscription.Label != label || subscription.NotifyCustomerEmail {
		t.Fatalf("subscription %+v, %v", subscription, err)
	}
	charge, err := client.Subscriptions.GetOpenCharge(ctx, "sub_1")
	if err != nil || charge.ID != "rc_1" || charge.SubscriptionID != "sub_1" || charge.AmountCents != 9000 || charge.RenewalMode != RenewalChargeRenewalModeManual ||
		charge.PaymentURL != "https://perata.sh/pagar/rc_1" || charge.DueAt != "2026-12-20T03:00:00Z" || charge.ExpiresAt == nil || charge.Reminder != nil || charge.DaysUntilDue != nil || !charge.NotifyCustomerEmail {
		t.Fatalf("charge %+v, %v", charge, err)
	}
	_, err = client.Subscriptions.GetOpenCharge(ctx, "sub_2")
	var refused *Error
	if !errors.As(err, &refused) || refused.StatusCode != 404 || refused.Code != "no_open_charge" {
		t.Fatalf("error %#v", err)
	}
}

// The renewal events carry the charge: due, and the reminder with its days.
func TestTheRenewalEventsCarryTheCharge(t *testing.T) {
	now := time.Unix(signedAt+120, 0)
	event, err := verifyWebhookAt(newSecret, webhookHeader("msg_7", signedAt, "v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w="), []byte(renewalDue), now)
	due, ok := event.(*RenewalChargeWebhookEvent)
	if err != nil || !ok || due.Type != "subscription.renewal_due" || due.Data.ID != "rc_1" || due.Data.PaymentURL != "https://perata.sh/pagar/rc_1" || due.Data.Reminder != nil {
		t.Fatalf("event %#v, %v", event, err)
	}
	event, err = verifyWebhookAt(newSecret, webhookHeader("msg_8", signedAt, "v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q="), []byte(renewalReminderLive), now)
	reminder, ok := event.(*RenewalChargeWebhookEvent)
	if err != nil || !ok || reminder.Type != "subscription.renewal_reminder" || reminder.Environment != "live" || reminder.Data.Reminder == nil || *reminder.Data.Reminder != "before_due" || reminder.Data.DaysUntilDue == nil || *reminder.Data.DaysUntilDue != 3 {
		t.Fatalf("event %#v, %v", event, err)
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

func TestARedirectIsRefusedAndTheKeyNeverFollowsIt(t *testing.T) {
	elsewhere := 0
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { elsewhere++ }))
	t.Cleanup(other.Close)
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/steal", http.StatusFound)
	})
	_, err := client.Products.Get(context.Background(), "prod_1")
	var refused *Error
	if !errors.As(err, &refused) || refused.StatusCode != http.StatusFound || elsewhere != 0 {
		t.Fatalf("error %#v, the redirect target was called %d times", err, elsewhere)
	}
}

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const (
	referenceSecret     = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	referenceSignature  = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
	oldSecret           = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
	newSecret           = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
	orderPaid           = `{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}`
	usageRecorded       = `{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}`
	payoutSent          = `{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}`
	orderPaidLive       = `{"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}`
	payoutSentTest      = `{"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","environment":"test","data":{"payout_id":"po_1","amount_cents":5000}}`
	renewalDue          = `{"id":"msg_7","type":"subscription.renewal_due","timestamp":"2026-10-22T12:00:00Z","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":null,"days_until_due":null}}`
	renewalReminderLive = `{"id":"msg_8","type":"subscription.renewal_reminder","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":"before_due","days_until_due":3}}`
	signedAt            = 1792670400
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

func TestATimestampThatIsNotPlainDigitsIsRefused(t *testing.T) {
	body := []byte(`{"test": 2432232314}`)
	for stamp, signature := range map[string]string{"+1614265330": "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8=", "²": "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY=", "": "x", "1_6": "x"} {
		header := http.Header{}
		header.Set("Webhook-Id", "msg_p5jXN8AQM9LWM0D4loKWxJek")
		header.Set("webhook-timestamp", stamp)
		header.Set("webhook-signature", "v1,"+signature)
		if err := verifyWebhookSignatureAt(referenceSecret, header, body, time.Unix(1614265330, 0)); !errors.Is(err, ErrWebhookSignature) {
			t.Errorf("%q verified: %v", stamp, err)
		}
	}
}

func TestAWebhookAnswersItsTypedEvent(t *testing.T) {
	now := time.Unix(signedAt+120, 0)
	header := webhookHeader("msg_2", signedAt, "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=")
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

func TestAWebhookCarriesTheEnvironmentItHappenedIn(t *testing.T) {
	now := time.Unix(signedAt+120, 0)
	older := map[string]struct {
		signature, body string
	}{
		"msg_2": {"v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=", orderPaid},
		"msg_3": {"v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=", usageRecorded},
		"msg_4": {"v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=", payoutSent},
	}
	for id, sent := range older {
		event, err := verifyWebhookAt(newSecret, webhookHeader(id, signedAt, sent.signature), []byte(sent.body), now)
		if err != nil || event.Message().Environment != "" || event.Message().ShowcaseID != "" {
			t.Fatalf("a body without an environment: %#v, %v", event, err)
		}
	}
	event, err := verifyWebhookAt(newSecret, webhookHeader("msg_5", signedAt, "v1,vJOO2qPe9Vzlr42VPwCuIO+a6Sg8ZVfl9z4WuLJItwg="), []byte(orderPaidLive), now)
	order, ok := event.(*OrderWebhookEvent)
	if err != nil || !ok || order.Environment != "live" || order.Message().Environment != "live" || order.ShowcaseID != "shw_1" || order.Message().ShowcaseID != "shw_1" || order.Data.ShowcaseID != "shw_1" || order.Data.ID != "ord_1" {
		t.Fatalf("event %#v, %v", event, err)
	}
	event, err = verifyWebhookAt(newSecret, webhookHeader("msg_6", signedAt, "v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM="), []byte(payoutSentTest), now)
	unknown, ok := event.(*UnknownWebhookEvent)
	if err != nil || !ok || unknown.Environment != "test" || unknown.ShowcaseID != "" {
		t.Fatalf("event %#v, %v", event, err)
	}
}

func TestAnErrorWithoutAMessageSaysItsFields(t *testing.T) {
	err := &Error{StatusCode: 422, Code: "invalid_request", Fields: map[string][]string{
		"customer_email": {"Envie um cliente já cadastrado ou o e-mail e o nome dele, não os dois."},
		"amount_cents":   {"O valor mínimo deste preço é R$ 1,00 (100 centavos)."},
		"empty":          {},
	}}
	want := "perata: 422 invalid_request: amount_cents: O valor mínimo deste preço é R$ 1,00 (100 centavos).; customer_email: Envie um cliente já cadastrado ou o e-mail e o nome dele, não os dois."
	if got := err.Error(); got != want {
		t.Fatalf("Error() = %q, want %q", got, want)
	}
	withMessage := &Error{StatusCode: 422, Code: "invalid_request", Message: "customer_email: Envie um cliente.", Fields: map[string][]string{"customer_email": {"Envie um cliente."}}}
	if got := withMessage.Error(); got != "perata: 422 invalid_request: customer_email: Envie um cliente." {
		t.Fatalf("a message was not used as it came: %q", got)
	}
	if got := (&Error{StatusCode: 404, Code: "not_found"}).Error(); got != "perata: 404 not_found" {
		t.Fatalf("Error() = %q", got)
	}
}
