package generator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A schema with no type is a free-form JSON value: the IR says so, and every
// language gives it the type that holds any JSON.
func TestAFreeFormValueIsAnyJSON(t *testing.T) {
	ir, err := load(t, func(doc map[string]any) {
		properties := dig(doc, "components", "schemas", "Product", "properties")
		properties["extra"] = map[string]any{"type": "object", "description": "Anything.", "additionalProperties": map[string]any{}}
		properties["raw"] = map[string]any{"description": "Any value."}
	})
	if err != nil {
		t.Fatal(err)
	}
	var product *Model
	for _, model := range ir.Models {
		if model.Name == "Product" {
			product = model
		}
	}
	kinds := map[string]*TypeRef{}
	for _, field := range product.Fields {
		kinds[field.Wire] = field.Type
	}
	if kinds["extra"].Kind != "map" || kinds["extra"].Items.Kind != "any" || kinds["raw"].Kind != "any" {
		t.Fatalf("extra %+v, raw %+v", kinds["extra"], kinds["raw"])
	}
	want := map[string]struct{ file, text string }{
		"go":         {"models.go", "map[string]any"},
		"typescript": {"src/models.ts", "Record<string, unknown>"},
		"python":     {"src/perata/models.py", "dict[str, Any]"},
		"php":        {"src/Models/Product.php", "array<string, mixed>"},
		"ruby":       {"lib/perata/models.rb", "Hash{String => Object}"},
		"java":       {"src/main/java/sh/perata/Product.java", "Map<String, Object>"},
		"csharp":     {"src/Perata/Models/Product.cs", "IReadOnlyDictionary<string, JsonElement>"},
		"elixir":     {"lib/perata/models.ex", "%{optional(String.t()) => term()}"},
		"dart":       {"lib/src/models.dart", "Map<String, Object?>"},
		"rust":       {"src/models.rs", "HashMap<String, serde_json::Value>"},
		"swift":      {"Sources/Perata/Models.swift", "[String: JSONValue]"},
	}
	for language, expected := range want {
		out := t.TempDir()
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		raw, err := os.ReadFile(filepath.Join(out, expected.file))
		if err != nil || !strings.Contains(string(raw), expected.text) {
			t.Errorf("%s: %s has no %q (%v)", language, expected.file, expected.text, err)
		}
	}
	if len(want) != len(Languages) {
		t.Errorf("checked %d languages of %d", len(want), len(Languages))
	}
}

// A nullable enum lists null among its values (it is the nullability, not a
// value); an object that names no property is a map of free-form values; and
// a 204 is a method that returns nothing.
func TestNullInAnEnumAnEmptyObjectAndANoContentAnswer(t *testing.T) {
	ir, err := load(t, func(doc map[string]any) {
		properties := dig(doc, "components", "schemas", "Product", "properties")
		properties["period"] = map[string]any{"type": []any{"string", "null"}, "enum": []any{"day", "month", nil}}
		properties["pairs"] = map[string]any{"type": "object"}
		properties["closed"] = map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false}
		item := dig(doc, "paths", "/api/v1/products/{product}")
		item["delete"] = map[string]any{
			"operationId": "products:delete",
			"summary":     "Delete a product",
			"security":    []any{map[string]any{"apiKey": []any{}}},
			"parameters":  []any{map[string]any{"name": "product", "in": "path", "required": true, "schema": map[string]any{"type": "string"}}},
			"responses":   map[string]any{"204": map[string]any{"description": "Nothing."}},
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	var product *Model
	for _, model := range ir.Models {
		if model.Name == "Product" {
			product = model
		}
	}
	for _, field := range product.Fields {
		switch field.Wire {
		case "period":
			if !field.Nullable || strings.Join(field.Type.Enum, ",") != "day,month" {
				t.Errorf("period %+v nullable %v", field.Type, field.Nullable)
			}
		case "pairs", "closed":
			if field.Type.Kind != "map" || field.Type.Items.Kind != "any" {
				t.Errorf("%s is %+v", field.Wire, field.Type)
			}
		}
	}
	var deleted *Method
	for _, service := range ir.Services {
		for _, method := range service.Methods {
			if method.OperationID == "products:delete" {
				deleted = method
			}
		}
	}
	if deleted == nil || !deleted.NoContent || deleted.Response != "" || deleted.HTTPMethod != "DELETE" {
		t.Fatalf("delete %+v", deleted)
	}
	// Every language writes it, and returns nothing.
	want := map[string]struct{ file, text string }{
		"go":         {"services.go", "opts ...RequestOption) error {"},
		"typescript": {"src/services.ts", "Promise<void>"},
		"python":     {"src/perata/_services.py", "-> None:"},
		"php":        {"src/Services/ProductsService.php", "?string $apiKey = null): void"},
		"ruby":       {"lib/perata/services.rb", "# @return [nil]"},
		"java":       {"src/main/java/sh/perata/ProductsService.java", "public void delete("},
		"csharp":     {"src/Perata/Services/ProductsService.cs", "public Task DeleteAsync("},
		"elixir":     {"lib/perata/services.ex", ":ok | {:error, Perata.Error.t()}"},
		"dart":       {"lib/src/services.dart", "Future<void> delete"},
		"rust":       {"src/services.rs", "-> Result<(), Error>"},
		"swift":      {"Sources/Perata/Services.swift", "async throws {"},
	}
	for language, expected := range want {
		out := t.TempDir()
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		raw, err := os.ReadFile(filepath.Join(out, expected.file))
		if err != nil || !strings.Contains(string(raw), expected.text) {
			t.Errorf("%s: %s has no %q (%v)", language, expected.file, expected.text, err)
		}
	}
	if len(want) != len(Languages) {
		t.Errorf("checked %d languages of %d", len(want), len(Languages))
	}
}

// A model or null, which OpenAPI 3.1 writes as an anyOf of the model and
// {"type": "null"}, is a nullable model in every language, not a free-form value.
func TestAModelOrNullIsANullableModel(t *testing.T) {
	ir, err := load(t, func(doc map[string]any) {
		properties := dig(doc, "components", "schemas", "Product", "properties")
		properties["featured_price"] = map[string]any{"anyOf": []any{
			map[string]any{"$ref": "#/components/schemas/Price"},
			map[string]any{"type": "null"},
		}}
	})
	if err != nil {
		t.Fatal(err)
	}
	var product *Model
	for _, model := range ir.Models {
		if model.Name == "Product" {
			product = model
		}
	}
	var featured *Field
	for _, field := range product.Fields {
		if field.Wire == "featured_price" {
			featured = field
		}
	}
	if featured == nil || !featured.Nullable || featured.Type.Kind != "model" || featured.Type.Model != "Price" {
		t.Fatalf("featured_price = %+v", featured)
	}
	want := map[string]struct{ file, text string }{
		"go":         {"models.go", "FeaturedPrice"},
		"typescript": {"src/models.ts", "featured_price?: Price | null"},
		"python":     {"src/perata/models.py", "featured_price: Price | None"},
		"php":        {"src/Models/Product.php", "?Price $featuredPrice"},
		"ruby":       {"lib/perata/models.rb", "# @return [Price, nil]"},
		"java":       {"src/main/java/sh/perata/Product.java", "private final Price featuredPrice;"},
		"csharp":     {"src/Perata/Models/Product.cs", "Price? FeaturedPrice"},
		"elixir":     {"lib/perata/models.ex", "featured_price: Perata.Price.t() | nil"},
		"dart":       {"lib/src/models.dart", "final Price? featuredPrice;"},
		"rust":       {"src/models.rs", "pub featured_price: Option<Price>"},
		"swift":      {"Sources/Perata/Models.swift", "public let featuredPrice: Price?"},
	}
	for language, expected := range want {
		out := t.TempDir()
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		raw, err := os.ReadFile(filepath.Join(out, expected.file))
		if err != nil || !strings.Contains(string(raw), expected.text) {
			t.Errorf("%s: %s has no %q (%v)", language, expected.file, expected.text, err)
		}
	}
	if len(want) != len(Languages) {
		t.Errorf("checked %d languages of %d", len(want), len(Languages))
	}
}
