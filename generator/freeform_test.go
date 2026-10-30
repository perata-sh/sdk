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
