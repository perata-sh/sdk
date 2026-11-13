package generator

import "testing"

// The contract the API serves reads into services and models, every list
// paginated over the model it lists, and the usage ingestion, which takes a
// source's credential and no Idempotency-Key, read with its nested events.
func TestTheContractReadsIntoTheIR(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	services := map[string]map[string]*Method{}
	for _, service := range ir.Services {
		services[service.Name] = map[string]*Method{}
		for _, method := range service.Methods {
			services[service.Name][method.Name] = method
		}
	}
	ingest := services["usage"]["ingest"]
	if ingest == nil || !ingest.UsageSource || ingest.Write || ingest.HTTPMethod != "POST" || ingest.Path != "/api/v1/usage/token-events" ||
		ingest.Response != "UsageIngestReceipt" || ingest.Body == nil || ingest.Body.Name != "UsageIngestParams" || len(ingest.Nested) != 3 {
		t.Fatalf("usage.ingest = %+v", ingest)
	}
	for name, method := range services["products"] {
		if method.UsageSource {
			t.Fatalf("products.%s takes a usage source's credential", name)
		}
	}
	nested := map[string]*Model{}
	for _, model := range ir.Models {
		nested[model.Name] = model
	}
	event, cost, receipt := nested["UsageIngestEvent"], nested["UsageIngestEventCost"], nested["UsageIngestReceipt"]
	if event == nil || cost == nil || receipt == nil || !event.Input || !cost.Input || receipt.Input {
		t.Fatalf("the ingestion's models: event %+v, cost %+v, receipt %+v", event, cost, receipt)
	}
	fields := map[string]*Field{}
	for _, field := range event.Fields {
		fields[field.Wire] = field
	}
	if fields["_cost"] == nil || fields["_cost"].Required || fields["_cost"].Type.Kind != "model" || fields["_cost"].Type.Nested != cost ||
		fields["customer_id"] == nil || !fields["customer_id"].Required || fields["parent_id"] == nil || fields["parent_id"].Required {
		t.Fatalf("the event's fields = %+v", fields)
	}
	if events := ingest.Body.Fields[0]; events.Wire != "events" || events.Type.Kind != "array" || events.Type.Items.Nested != event {
		t.Fatalf("the body's events = %+v", events)
	}
	if len(receipt.Fields) != 2 || !receipt.Fields[0].Required || !receipt.Fields[1].Required || receipt.Fields[0].Type.Kind != "integer" {
		t.Fatalf("the receipt's fields = %+v", receipt.Fields)
	}
	list := services["products"]["list"]
	if list == nil || !list.Paginated || list.Item != "Product" || list.HTTPMethod != "GET" || list.Path != "/api/v1/products" {
		t.Fatalf("products.list = %+v", list)
	}
	create := services["products"]["create"]
	if create == nil || create.Body == nil || create.Body.Name != "ProductsCreateParams" || !create.Write || create.Response != "Product" {
		t.Fatalf("products.create = %+v", create)
	}
	if prices := services["prices"]["list"]; len(prices.Query) != 1 || prices.Query[0].Name != "product_id" {
		t.Fatalf("prices.list filters = %+v", prices.Query)
	}
	if get := services["payments"]["get"]; len(get.PathParams) != 1 || get.PathParams[0] != "payment" {
		t.Fatalf("payments.get path params = %+v", get.PathParams)
	}
	models := map[string]*Model{}
	for _, model := range ir.Models {
		models[model.Name] = model
	}
	for _, name := range []string{"Product", "Payment", "Subscription", "Card", "Pagination"} {
		if models[name] == nil {
			t.Fatalf("model %s missing", name)
		}
	}
	if models["ProductEnvelope"] != nil || models["ProductList"] != nil {
		t.Fatal("an envelope became a model")
	}
	if sessions := services["customer-sessions"]["create"]; sessions == nil || sessions.Response != "CustomerSession" || !sessions.Write {
		t.Fatalf("customer-sessions.create = %+v", sessions)
	}
	installments := map[string]bool{}
	for _, field := range models["Payment"].Fields {
		installments[field.Wire] = field.Required && field.Type.Kind == "integer"
	}
	if !installments["installments"] || !installments["installment_amount_cents"] || !installments["installment_interest_cents"] {
		t.Fatalf("Payment's installment fields = %v", installments)
	}
	if Pascal("payment_methods") != "PaymentMethods" || Camel("payment_methods") != "paymentMethods" || Pascal("customer_id") != "CustomerID" {
		t.Fatal("naming")
	}
}

// The webhooks section reads into one group a kind of data, every event in
// exactly one, and a schema that is only a map of strings is that map, not a
// model.
func TestTheWebhooksReadIntoGroups(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	groups := map[string]*WebhookGroup{}
	seen := map[string]bool{}
	for _, group := range ir.Webhooks {
		groups[group.Name] = group
		for _, kind := range group.Types {
			if seen[kind] {
				t.Fatalf("%s is in two groups", kind)
			}
			seen[kind] = true
		}
	}
	if len(seen) < 70 {
		t.Fatalf("%d webhook events", len(seen))
	}
	order := groups["Order"]
	if order == nil || order.Data.Kind != "model" || order.Data.Model != "Order" || !contains(order.Types, "order.paid") {
		t.Fatalf("Order group = %+v", order)
	}
	if dispute := groups["Dispute"]; dispute == nil || dispute.Data.Model != "WebhookDispute" || !contains(dispute.Types, "dispute.opened") {
		t.Fatalf("Dispute group = %+v", dispute)
	}
	identifiers := groups["Identifiers"]
	if identifiers == nil || identifiers.Data.Kind != "map" || identifiers.Data.Items.Kind != "string" || !contains(identifiers.Types, "usage_event.recorded") {
		t.Fatalf("Identifiers group = %+v", identifiers)
	}
	for _, model := range ir.Models {
		if model.Name == "WebhookIdentifiers" {
			t.Fatal("a map of strings became a model")
		}
	}
}

func contains(values []string, value string) bool {
	for _, each := range values {
		if each == value {
			return true
		}
	}
	return false
}
