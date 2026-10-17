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
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Leia o corpo cru e verifique antes de interpretar.

Versão do SDK: 0.1.0 · contrato da API: 0.1.0
