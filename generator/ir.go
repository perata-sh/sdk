// Package generator builds Peráta's SDKs from the public API's contract, the
// way Polar builds its own: the OpenAPI document is read into an
// intermediate representation that no language knows about -- services,
// methods, models, pagination -- and one emitter per language renders it.
// The SDKs under sdk/<language> are output and are never edited by hand;
// what is hand-written lives in this package's templates.
package generator

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// IR is the API as every SDK sees it.
type IR struct {
	// Version is the SDK's version, the same in every language.
	Version string
	// APIVersion is the contract's info.version.
	APIVersion string
	BaseURL    string
	Models     []*Model
	Services   []*Service
}

// Model is a named object: a resource the API answers, or the body of a
// request.
type Model struct {
	Name        string
	Description string
	Fields      []*Field
	// Input says the model is sent, not read.
	Input bool
}

// Field is one property of a model.
type Field struct {
	// Wire is the JSON name.
	Wire        string
	Description string
	Type        *TypeRef
	Required    bool
	Nullable    bool
}

// TypeRef is a field's type.
type TypeRef struct {
	// Kind is string, integer, number, boolean, model, array or map.
	Kind  string
	Model string
	Items *TypeRef
	// Enum are a string's allowed values.
	Enum   []string
	Format string
}

// Service groups the methods of one resource: products, payments.
type Service struct {
	Name    string
	Methods []*Method
}

// Method is one operation.
type Method struct {
	// Name is the part of the operationId after the service: list, get.
	Name        string
	OperationID string
	Summary     string
	HTTPMethod  string
	Path        string
	PathParams  []string
	// Query are the optional filters, without page and limit.
	Query []*Param
	// Body is the request model, or nil.
	Body *Model
	// Response is the model answered in the data envelope.
	Response string
	// Paginated says the answer is a page of Item.
	Paginated bool
	Item      string
	// Write says it takes an Idempotency-Key.
	Write bool
}

// Param is a query filter.
type Param struct {
	Name, Description string
}

type spec struct {
	Info struct {
		Version string `json:"version"`
	} `json:"info"`
	Servers []struct {
		URL string `json:"url"`
	} `json:"servers"`
	Paths      map[string]map[string]*operation `json:"paths"`
	Components struct {
		Schemas map[string]*schema `json:"schemas"`
	} `json:"components"`
}

type operation struct {
	OperationID string                `json:"operationId"`
	Summary     string                `json:"summary"`
	Security    []map[string][]string `json:"security"`
	Parameters  []struct {
		Name        string  `json:"name"`
		In          string  `json:"in"`
		Description string  `json:"description"`
		Schema      *schema `json:"schema"`
	} `json:"parameters"`
	RequestBody *struct {
		Content map[string]struct {
			Schema *schema `json:"schema"`
		} `json:"content"`
	} `json:"requestBody"`
	Responses map[string]struct {
		Content map[string]struct {
			Schema *schema `json:"schema"`
		} `json:"content"`
	} `json:"responses"`
	Pagination map[string]string `json:"x-perata-pagination"`
}

type schema struct {
	Ref         string             `json:"$ref"`
	Type        any                `json:"type"`
	Format      string             `json:"format"`
	Description string             `json:"description"`
	Enum        []string           `json:"enum"`
	Required    []string           `json:"required"`
	Properties  map[string]*schema `json:"properties"`
	Items       *schema            `json:"items"`
	// AdditionalProperties is a schema, or false for a closed object.
	AdditionalProperties json.RawMessage `json:"additionalProperties"`
}

// additional is the schema of a map's values, or nil.
func (s *schema) additional() *schema {
	raw := strings.TrimSpace(string(s.AdditionalProperties))
	if raw == "" || !strings.HasPrefix(raw, "{") {
		return nil
	}
	var values schema
	if json.Unmarshal(s.AdditionalProperties, &values) != nil {
		return nil
	}
	return &values
}

// Load reads the contract at path into the IR.
func Load(path, version string) (*IR, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc spec
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("generator: read %s: %w", path, err)
	}
	return build(&doc, version)
}

// wrappers are the generated envelopes and pages, which the SDKs unwrap
// rather than expose, and the error body, which each SDK's hand-written
// runtime turns into its own error type.
func wrapper(name string) bool {
	return strings.HasSuffix(name, "Envelope") || strings.HasSuffix(name, "List") || name == "Error"
}

func build(doc *spec, version string) (*IR, error) {
	ir := &IR{Version: version, APIVersion: doc.Info.Version}
	if len(doc.Servers) > 0 {
		ir.BaseURL = doc.Servers[0].URL
	}
	names := make([]string, 0, len(doc.Components.Schemas))
	for name := range doc.Components.Schemas {
		if !wrapper(name) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		model, err := modelOf(name, doc.Components.Schemas[name], false)
		if err != nil {
			return nil, err
		}
		ir.Models = append(ir.Models, model)
	}
	services := map[string]*Service{}
	paths := make([]string, 0, len(doc.Paths))
	for path := range doc.Paths {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		methods := make([]string, 0, len(doc.Paths[path]))
		for method := range doc.Paths[path] {
			methods = append(methods, method)
		}
		sort.Strings(methods)
		for _, httpMethod := range methods {
			op := doc.Paths[path][httpMethod]
			if !apiKeyOperation(op) {
				continue
			}
			serviceName, methodName, ok := strings.Cut(op.OperationID, ":")
			if !ok {
				return nil, fmt.Errorf("generator: %s %s has no service:method operationId", httpMethod, path)
			}
			method, err := methodOf(op, strings.ToUpper(httpMethod), path, serviceName, methodName, doc)
			if err != nil {
				return nil, err
			}
			service := services[serviceName]
			if service == nil {
				service = &Service{Name: serviceName}
				services[serviceName] = service
			}
			service.Methods = append(service.Methods, method)
			if method.Body != nil {
				ir.Models = append(ir.Models, method.Body)
			}
		}
	}
	serviceNames := make([]string, 0, len(services))
	for name := range services {
		serviceNames = append(serviceNames, name)
	}
	sort.Strings(serviceNames)
	for _, name := range serviceNames {
		service := services[name]
		sort.Slice(service.Methods, func(i, j int) bool { return service.Methods[i].Name < service.Methods[j].Name })
		ir.Services = append(ir.Services, service)
	}
	return ir, nil
}

// apiKeyOperation says the operation is the SDK's: authenticated by the
// organization's API key. The usage ingestion takes a source's credential
// and is not.
func apiKeyOperation(op *operation) bool {
	for _, requirement := range op.Security {
		if _, ok := requirement["apiKey"]; ok {
			return true
		}
	}
	return false
}

func methodOf(op *operation, httpMethod, path, serviceName, methodName string, doc *spec) (*Method, error) {
	method := &Method{Name: methodName, OperationID: op.OperationID, Summary: op.Summary, HTTPMethod: httpMethod, Path: path,
		Write: httpMethod != "GET"}
	for _, param := range op.Parameters {
		switch {
		case param.In == "path":
			method.PathParams = append(method.PathParams, param.Name)
		case param.In == "query" && param.Name != "page" && param.Name != "limit":
			method.Query = append(method.Query, &Param{Name: param.Name, Description: param.Description})
		}
	}
	for status, response := range op.Responses {
		if !strings.HasPrefix(status, "2") {
			continue
		}
		ref := strings.TrimPrefix(response.Content["application/json"].Schema.Ref, "#/components/schemas/")
		switch {
		case strings.HasSuffix(ref, "ListEnvelope"):
			method.Paginated, method.Item = true, strings.TrimSuffix(ref, "ListEnvelope")
			method.Response = method.Item
		case strings.HasSuffix(ref, "Envelope"):
			method.Response = strings.TrimSuffix(ref, "Envelope")
		}
	}
	if method.Response == "" {
		return nil, fmt.Errorf("generator: %s answers no model", op.OperationID)
	}
	if method.Paginated && op.Pagination["item_schema"] != method.Item {
		return nil, fmt.Errorf("generator: %s pages %q but declares %q", op.OperationID, method.Item, op.Pagination["item_schema"])
	}
	if op.RequestBody != nil {
		body := op.RequestBody.Content["application/json"].Schema
		if body != nil && len(body.Properties) > 0 {
			model, err := modelOf(Pascal(serviceName)+Pascal(methodName)+"Params", body, true)
			if err != nil {
				return nil, err
			}
			model.Description = "The body of " + op.OperationID + "."
			method.Body = model
		}
	}
	return method, nil
}

func modelOf(name string, s *schema, input bool) (*Model, error) {
	model := &Model{Name: name, Description: s.Description, Input: input}
	required := map[string]bool{}
	for _, field := range s.Required {
		required[field] = true
	}
	wires := make([]string, 0, len(s.Properties))
	for wire := range s.Properties {
		wires = append(wires, wire)
	}
	sort.Strings(wires)
	for _, wire := range wires {
		property := s.Properties[wire]
		typ, nullable, err := typeOf(property)
		if err != nil {
			return nil, fmt.Errorf("generator: %s.%s: %w", name, wire, err)
		}
		model.Fields = append(model.Fields, &Field{Wire: wire, Description: property.Description, Type: typ, Required: required[wire], Nullable: nullable})
	}
	return model, nil
}

func typeOf(s *schema) (*TypeRef, bool, error) {
	if s.Ref != "" {
		return &TypeRef{Kind: "model", Model: strings.TrimPrefix(s.Ref, "#/components/schemas/")}, false, nil
	}
	kind, nullable := "", false
	switch t := s.Type.(type) {
	case string:
		kind = t
	case []any:
		for _, each := range t {
			if each == "null" {
				nullable = true
			} else {
				kind, _ = each.(string)
			}
		}
	}
	switch kind {
	case "string", "integer", "number", "boolean":
		return &TypeRef{Kind: kind, Enum: s.Enum, Format: s.Format}, nullable, nil
	case "array":
		items, _, err := typeOf(s.Items)
		return &TypeRef{Kind: "array", Items: items}, nullable, err
	case "object":
		if values := s.additional(); values != nil {
			items, _, err := typeOf(values)
			return &TypeRef{Kind: "map", Items: items}, nullable, err
		}
	}
	return nil, false, fmt.Errorf("unsupported schema type %v", s.Type)
}

// Pascal writes payment_methods as PaymentMethods.
func Pascal(name string) string {
	parts := strings.FieldsFunc(name, func(r rune) bool { return r == '_' || r == '-' || r == '.' || r == ' ' })
	for i, part := range parts {
		switch strings.ToLower(part) {
		case "id", "url":
			parts[i] = strings.ToUpper(part)
		default:
			parts[i] = strings.ToUpper(part[:1]) + part[1:]
		}
	}
	return strings.Join(parts, "")
}

// Camel writes payment_methods as paymentMethods.
func Camel(name string) string {
	pascal := Pascal(name)
	if strings.HasPrefix(pascal, "ID") || strings.HasPrefix(pascal, "URL") {
		return strings.ToLower(pascal[:2]) + pascal[2:]
	}
	return strings.ToLower(pascal[:1]) + pascal[1:]
}
