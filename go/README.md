# Peráta SDK para Go

SDK oficial da API da Peráta, gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
go get github.com/perata-sh/sdk/go
```

```go
client := perata.New(os.Getenv("PERATA_API_KEY")) // prk_test_… ou prk_live_…

product, err := client.Products.Create(ctx, perata.ProductsCreateParams{Name: "Curso"},
	perata.WithIdempotencyKey("produto-curso"))

for product, err := range client.Products.ListIter(ctx, nil) {
	if err != nil {
		return err
	}
	fmt.Println(product.Name)
}
```

## Recursos

| Serviço | Métodos |
|---|---|
| `client.Checkouts` | `Create` |
| `client.CustomerSessions` | `Create` |
| `client.Customers` | `Create`, `Get`, `List`, `ListIter` |
| `client.Orders` | `List`, `ListIter` |
| `client.PaymentMethods` | `Detach`, `List`, `ListIter` |
| `client.Payments` | `Get`, `List`, `ListIter` |
| `client.Prices` | `Create`, `List`, `ListIter` |
| `client.Products` | `Create`, `Get`, `List`, `ListIter` |
| `client.Refunds` | `Create` |
| `client.Subscriptions` | `Cancel`, `Get`, `List`, `ListIter` |

## Erros

Uma recusa da API é um `*perata.Error` com `StatusCode`, `Code` (`invalid_request`, `not_found`…), `Message`, `Fields` (o problema de cada campo) e, num 429, `RetryAfter`.

## Webhooks

```go
event, err := perata.VerifyWebhook(os.Getenv("PERATA_WEBHOOK_SECRET"), r.Header, body)
if err != nil {
	http.Error(w, "assinatura inválida", http.StatusBadRequest)
	return
}
switch event := event.(type) {
case *perata.OrderWebhookEvent:
	fmt.Println(event.Type, event.Data.ID, event.Data.Installments) // order.paid…
case *perata.DisputeWebhookEvent:
	fmt.Println(event.Type, event.Data.ProviderDisputeID)
case *perata.UnknownWebhookEvent:
	// um tipo que esta versão do SDK ainda não conhece: event.Data é o JSON
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Leia o corpo cru e verifique antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `Order`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `VerifyWebhookSignature` só confere a assinatura.

Versão do SDK: 0.2.0 · contrato da API: 0.1.0
