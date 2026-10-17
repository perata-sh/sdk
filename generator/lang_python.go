package generator

import (
	"strings"
	"text/template"
)

// pyKeywords are names a Python parameter cannot take.
var pyKeywords = map[string]bool{"from": true, "class": true, "def": true, "global": true, "import": true, "in": true, "is": true, "lambda": true, "pass": true, "return": true, "with": true, "yield": true}

func init() {
	register(Language{Name: "python", Funcs: template.FuncMap{
		"pyType": pyType,
		"pyRead": pyRead,
		"pyName": func(name string) string {
			name = strings.ReplaceAll(name, "-", "_")
			if pyKeywords[name] {
				return name + "_"
			}
			return name
		},
		// pyDoc writes a description as the docstring line under a field, or
		// nothing.
		"pyDoc": func(indent, text string) string {
			text = strings.TrimSpace(text)
			if text == "" {
				return ""
			}
			return "\n" + indent + `"""` + strings.ReplaceAll(text, `"""`, `\"\"\"`) + `"""`
		},
	}})
}

// pyType is a field's Python annotation; a string with allowed values is
// their Literal.
func pyType(t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			values := make([]string, len(t.Enum))
			for i, value := range t.Enum {
				values[i] = `"` + value + `"`
			}
			return "Literal[" + strings.Join(values, ", ") + "]"
		}
		return "str"
	case "integer":
		return "int"
	case "number":
		return "float"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "array":
		return "list[" + pyType(t.Items) + "]"
	case "map":
		return "dict[str, " + pyType(t.Items) + "]"
	}
	return "Any"
}

// pyRead is the expression that reads a field out of the API's dict into
// its type: a nested model is built, anything else is taken as it is. A field
// the API always sends is indexed, so a missing one fails loudly.
func pyRead(f *Field) string {
	if f.Required && !f.Nullable {
		if convert := pyConvert(f.Type, `data["`+f.Wire+`"]`); convert != "" {
			return convert
		}
		return `data["` + f.Wire + `"]`
	}
	if convert := pyConvert(f.Type, `data["`+f.Wire+`"]`); convert != "" {
		return `None if data.get("` + f.Wire + `") is None else ` + convert
	}
	return `data.get("` + f.Wire + `")`
}

// pyConvert builds expr into t, or is empty when nothing is to be built.
func pyConvert(t *TypeRef, expr string) string {
	switch t.Kind {
	case "model":
		return t.Model + ".from_dict(" + expr + ")"
	case "array":
		if inner := pyConvert(t.Items, "item"); inner != "" {
			return "[" + inner + " for item in " + expr + "]"
		}
	case "map":
		if inner := pyConvert(t.Items, "value"); inner != "" {
			return "{key: " + inner + " for key, value in " + expr + ".items()}"
		}
	}
	return ""
}
