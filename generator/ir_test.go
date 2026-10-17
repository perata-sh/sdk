package generator

import "testing"

// The contract the API serves reads into services and models, every list
// paginated over the model it lists, and the usage ingestion left out.
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
	if _, ok := services["usage"]; ok {
		t.Fatal("the usage ingestion, which takes no API key, is in the SDK")
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
	if Pascal("payment_methods") != "PaymentMethods" || Camel("payment_methods") != "paymentMethods" || Pascal("customer_id") != "CustomerID" {
		t.Fatal("naming")
	}
}
