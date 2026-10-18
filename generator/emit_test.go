package generator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every language writes its SDK, a file a model or a service written once
// for each, and nothing it did not write is left behind.
func TestEveryLanguageWritesItsSDK(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string][]string{
		"go":         {"go.mod", "client.go", "services.go", "models.go"},
		"typescript": {"package.json", "src/client.ts", "src/services.ts", "test/perata.test.ts"},
		"python":     {"pyproject.toml", "src/perata/__init__.py", "src/perata/py.typed", "tests/test_perata.py"},
		"php":        {"composer.json", "src/Perata.php", "src/Models/Product.php", "src/Services/ProductsService.php"},
		"ruby":       {"perata-sh-sdk.gemspec", "lib/perata.rb", "lib/perata/services.rb", "test/perata_test.rb"},
		"elixir":     {"mix.exs", "lib/perata.ex", "lib/perata/services.ex", "test/perata_test.exs"},
		"java":       {"pom.xml", "src/main/java/sh/perata/Perata.java", "src/main/java/sh/perata/Product.java", "src/main/java/sh/perata/ProductsService.java"},
		"csharp":     {"Perata.slnx", "src/Perata/PerataClient.cs", "src/Perata/Models/Product.cs", "src/Perata/Services/ProductsService.cs"},
		"dart":       {"pubspec.yaml", "lib/perata_sh_sdk.dart", "lib/src/models.dart", "test/perata_test.dart"},
		"rust":       {"Cargo.toml", "src/lib.rs", "src/models.rs", "tests/perata.rs"},
		"swift":      {"Package.swift", "Sources/Perata/PerataClient.swift", "Sources/Perata/Models.swift", "Tests/PerataTests/PerataTests.swift"},
	}
	if len(expected) != len(Languages) {
		t.Fatalf("languages %d, checked %d", len(Languages), len(expected))
	}
	for language, files := range expected {
		out := t.TempDir()
		stale := filepath.Join(out, "stale.txt")
		if err := os.WriteFile(stale, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		for _, file := range files {
			if _, err := os.Stat(filepath.Join(out, file)); err != nil {
				t.Errorf("%s did not write %s", language, file)
			}
		}
		if _, err := os.Stat(stale); err == nil {
			t.Errorf("%s left a file it does not write", language)
		}
		_ = filepath.WalkDir(out, func(path string, entry os.DirEntry, err error) error {
			if err == nil && (strings.Contains(path, "__") || strings.HasSuffix(path, ".tmpl")) && !strings.Contains(path, "__init__") {
				t.Errorf("%s wrote %s", language, path)
			}
			return err
		})
	}
}
