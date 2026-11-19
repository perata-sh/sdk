package generator

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func method(ir *IR, service, name string) *Method {
	for _, each := range ir.Services {
		if each.Name == service {
			for _, m := range each.Methods {
				if m.Name == name {
					return m
				}
			}
		}
	}
	return nil
}

// The lists of checkouts, orders, payments and subscriptions share the
// metadata filter through a reference to components.parameters; a deepObject
// of strings is a map filter, and the other filters stay one string.
func TestAReferencedDeepObjectIsAMapFilter(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	for _, service := range []string{"checkouts", "orders", "payments", "subscriptions"} {
		list := method(ir, service, "list")
		var metadata, other *Param
		for _, param := range list.Query {
			if param.Name == "metadata" {
				metadata = param
			} else if param.Map {
				other = param
			}
		}
		if metadata == nil || !metadata.Map || metadata.Description == "" || other != nil {
			t.Errorf("%s:list metadata = %+v (another map: %+v)", service, metadata, other)
		}
	}
	if list := method(ir, "checkouts", "list"); len(list.Query) < 2 || list.Query[0].Map {
		t.Errorf("checkouts:list query = %+v", list.Query)
	}
	customers := method(ir, "customers", "list")
	if len(customers.Query) != 1 || customers.Query[0].Name != "email" || customers.Query[0].Map {
		t.Errorf("customers:list query = %+v", customers.Query)
	}
	if list := method(ir, "checkouts", "list"); list.Summary == "" || list.Description == "" || strings.HasPrefix(list.Description, list.Summary+":") {
		t.Errorf("checkouts:list summary %q, description %q", list.Summary, list.Description)
	}
}

// A parameter that points nowhere, that points at another reference, or is a
// deepObject of anything but strings stops generation: the SDKs would send it
// wrong.
func TestAParameterTheSDKsCannotSendStopsGeneration(t *testing.T) {
	for name, parameter := range map[string]map[string]any{
		"a reference to nothing":      {"$ref": "#/components/parameters/Nothing"},
		"a reference outside":         {"$ref": "#/components/schemas/Product"},
		"a deepObject of integers":    {"name": "filter", "in": "query", "style": "deepObject", "explode": true, "schema": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "integer"}}},
		"a deepObject that is joined": {"name": "filter", "in": "query", "style": "deepObject", "explode": false, "schema": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "string"}}},
		"an array":                    {"name": "filter", "in": "query", "schema": map[string]any{"type": "array", "items": map[string]any{"type": "string"}}},
		"a form object":               {"name": "filter", "in": "query", "schema": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "string"}}},
	} {
		_, err := load(t, func(doc map[string]any) {
			list := dig(doc, "paths", "/api/v1/products")["get"].(map[string]any)
			list["parameters"] = append(list["parameters"].([]any), parameter)
		})
		if err == nil {
			t.Errorf("%s: generation went on", name)
		}
	}
	// And the reference to a reference.
	_, err := load(t, func(doc map[string]any) {
		dig(doc, "components")["parameters"].(map[string]any)["Alias"] = map[string]any{"$ref": "#/components/parameters/MetadataFilter"}
		list := dig(doc, "paths", "/api/v1/products")["get"].(map[string]any)
		list["parameters"] = append(list["parameters"].([]any), map[string]any{"$ref": "#/components/parameters/Alias"})
	})
	if err == nil {
		t.Error("a reference to a reference: generation went on")
	}
}

// Each language types a map filter its own way and sends it as name[key]=value.
func TestEveryLanguageTypesAMapFilter(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]struct{ file, text string }{
		"go":         {"services.go", "Metadata map[string]string"},
		"typescript": {"src/services.ts", "metadata?: Record<string, string>;"},
		"python":     {"src/perata/_services.py", "metadata: dict[str, str] | None = None"},
		"php":        {"src/Services/CheckoutsService.php", "metadata?: array<string, string>"},
		"ruby":       {"lib/perata/client.rb", `"#{name}[#{key}]"`},
		"java":       {"src/main/java/sh/perata/CheckoutsService.java", "private final Map<String, String> metadata;"},
		"csharp":     {"src/Perata/Services/CheckoutsService.cs", "public IReadOnlyDictionary<string, string>? Metadata { get; init; }"},
		"elixir":     {"lib/perata/client.ex", `"#{name}[#{key}]"`},
		"dart":       {"lib/src/services.dart", "Map<String, String>? metadata,"},
		"rust":       {"src/services.rs", "pub metadata: BTreeMap<String, String>,"},
		"swift":      {"Sources/Perata/Services.swift", "metadata: [String: String]? = nil"},
	}
	if len(want) != len(Languages) {
		t.Fatalf("checked %d languages of %d", len(want), len(Languages))
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
}

// An operation's description is written over its method, after the summary,
// wrapped, and cannot leave its comment.
func TestAnOperationsDescriptionIsWrappedOverItsMethod(t *testing.T) {
	var words []string
	for i := 1; i <= 60; i++ {
		words = append(words, fmt.Sprintf("palavra%02d", i))
	}
	long := strings.Join(words[:30], " ") + "\n\nSegundo parágrafo com </summary> e */ e @param e <b>.\n\n" + strings.Join(words[30:], " ")
	ir, err := load(t, func(doc map[string]any) {
		get := dig(doc, "paths", "/api/v1/products/{product}")["get"].(map[string]any)
		get["description"] = long
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := method(ir, "products", "get").Description; !strings.Contains(got, "palavra01") || !strings.Contains(got, "\n\nSegundo") {
		t.Fatalf("description = %q", got)
	}
	for language := range Languages {
		out := t.TempDir()
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		var found bool
		_ = filepath.WalkDir(out, func(path string, entry os.DirEntry, err error) error {
			if err != nil || entry.IsDir() || !strings.Contains(filepath.Base(path), "ervice") && filepath.Base(path) != "services.go" && filepath.Base(path) != "services.ts" && filepath.Base(path) != "services.rs" && filepath.Base(path) != "services.ex" && filepath.Base(path) != "Services.swift" {
				return nil
			}
			raw, _ := os.ReadFile(path)
			if !strings.Contains(string(raw), "palavra01") {
				return nil
			}
			found = true
			for _, line := range strings.Split(string(raw), "\n") {
				if strings.Contains(line, "palavra") && len([]rune(line)) > 100 {
					t.Errorf("%s: %s has a description line of %d columns: %s", language, path, len([]rune(line)), line)
				}
				markup := (language == "csharp" || language == "java" || language == "dart") && strings.Contains(line, "</summary> e")
				if markup || strings.Contains(line, "*/ e") {
					t.Errorf("%s: %s lets the description end its comment: %s", language, path, line)
				}
			}
			if !strings.Contains(string(raw), "palavra60") {
				t.Errorf("%s: %s lost the end of the description", language, path)
			}
			return nil
		})
		if !found {
			t.Errorf("%s: no service file carries the description", language)
		}
	}
}
