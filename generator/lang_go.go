package generator

import (
	"go/format"
	"strings"
	"text/template"
)

// goKeywords are names a Go parameter cannot take.
var goKeywords = map[string]bool{"type": true, "func": true, "range": true, "map": true, "default": true, "interface": true, "select": true, "package": true}

func init() {
	register(Language{Name: "go", Funcs: template.FuncMap{
		"goType": goType,
		"goBase": goBase,
		"goParam": func(name string) string {
			camel := Camel(name)
			if goKeywords[camel] {
				return camel + "ID"
			}
			return camel
		},
		"goTag": func(f *Field, input bool) string {
			if input && !f.Required || !input && !f.Required {
				return f.Wire + ",omitempty"
			}
			return f.Wire
		},
		"goComment": goComment,
	}})
}

// goType is a field's Go type: a pointer when the API may answer null, or
// when a request may leave the field out.
func goType(t *TypeRef, f *Field, input bool) string {
	base := goBase(t)
	if f == nil {
		return base
	}
	pointer := f.Nullable || input && !f.Required
	if pointer && t.Kind != "array" && t.Kind != "map" {
		return "*" + base
	}
	return base
}

func goBase(t *TypeRef) string {
	switch t.Kind {
	case "string":
		return "string"
	case "integer":
		return "int64"
	case "number":
		return "float64"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "array":
		return "[]" + goBase(t.Items)
	case "map":
		return "map[string]" + goBase(t.Items)
	}
	return "any"
}

// goComment writes a description as a Go comment, or nothing.
func goComment(prefix, text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	return prefix + "// " + strings.ReplaceAll(text, "\n", "\n"+prefix+"// ") + "\n"
}

// FormatGo gofmt's a generated Go file.
func FormatGo(source []byte) ([]byte, error) { return format.Source(source) }
