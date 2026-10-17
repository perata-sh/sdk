# Peráta SDK para Elixir

SDK oficial da API da Peráta para Elixir 1.18+, sem dependências: só `:httpc`, `:crypto` e o módulo `JSON`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```elixir
# mix.exs
{:perata, "~> 0.1.0"}
```

```elixir
client = Perata.new(System.fetch_env!("PERATA_API_KEY")) # prk_test_… ou prk_live_…

{:ok, product} = Perata.Products.create(client, %{name: "Curso"}, idempotency_key: "produto-curso")

client
|> Perata.Products.list_stream()
|> Enum.each(&IO.puts(&1.name))
```

## Recursos

| Módulo | Funções |
|---|---|
| `Perata.Checkouts` | `create` |
| `Perata.Customers` | `create`, `get`, `list`, `list_stream` |
| `Perata.Orders` | `list`, `list_stream` |
| `Perata.PaymentMethods` | `detach`, `list`, `list_stream` |
| `Perata.Payments` | `get`, `list`, `list_stream` |
| `Perata.Prices` | `create`, `list`, `list_stream` |
| `Perata.Products` | `create`, `get`, `list`, `list_stream` |
| `Perata.Refunds` | `create` |
| `Perata.Subscriptions` | `cancel`, `get`, `list`, `list_stream` |

Cada função recebe o cliente primeiro e devolve `{:ok, valor}` ou `{:error, %Perata.Error{}}`. Os modelos são structs com os nomes da API (`payment.amount_cents`). O corpo de uma escrita é a struct de parâmetros do método (`%Perata.ProductsCreateParams{name: "Curso"}`), uma keyword list ou um mapa com chaves atom; um campo opcional não informado fica fora do JSON. As funções `_stream` devolvem um `Stream` preguiçoso que percorre todas as páginas a partir de `page:` e levantam `Perata.Error` numa recusa.

As escritas aceitam `idempotency_key:`, e todas aceitam `api_key:` para usar a chave de outra organização numa chamada. `Perata.new/2` aceita `base_url:`, `timeout:` (30 segundos, em milissegundos) e `transport:`.

## Erros

Uma recusa da API é um `{:error, %Perata.Error{}}`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo) e, num 429, `retry_after` em segundos.

## Webhooks

```elixir
{:ok, event} = Perata.verify_webhook(System.fetch_env!("PERATA_WEBHOOK_SECRET"), conn.req_headers, raw_body)
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar. Uma assinatura que não confere devolve `{:error, %Perata.WebhookVerificationError{}}`.

Versão do SDK: 0.1.0 · contrato da API: 0.1.0
