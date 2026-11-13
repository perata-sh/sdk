# Peráta SDK para Ruby

SDK oficial da API da Peráta para Ruby 3.1+, sem dependências: só `net/http`, `json` e `openssl`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
gem install perata-sdk
```

```ruby
require "perata"

perata = Perata::Client.new(ENV.fetch("PERATA_API_KEY")) # prk_test_… ou prk_live_…

product = perata.products.create({ name: "Curso" }, idempotency_key: "produto-curso")

perata.products.list_iter.each do |product|
  puts product.name
end
```

## Recursos

| Serviço | Métodos |
|---|---|
| `perata.benefits` | `create`, `delete`, `get`, `list`, `list_iter`, `list_grants`, `list_grants_iter`, `update` |
| `perata.checkout_links` | `create`, `delete`, `get`, `list`, `list_iter`, `update` |
| `perata.checkouts` | `create`, `get`, `update` |
| `perata.customer_sessions` | `create` |
| `perata.customers` | `create`, `delete`, `get`, `get_external`, `get_state`, `list`, `list_iter`, `update`, `update_external` |
| `perata.discounts` | `create`, `delete`, `get`, `list`, `list_iter`, `update` |
| `perata.disputes` | `get`, `list`, `list_iter` |
| `perata.events` | `list`, `list_iter` |
| `perata.meters` | `get`, `list`, `list_iter` |
| `perata.orders` | `get`, `get_invoice`, `get_receipt`, `list`, `list_iter` |
| `perata.payment_methods` | `detach`, `list`, `list_iter` |
| `perata.payments` | `get`, `list`, `list_iter` |
| `perata.prices` | `create`, `list`, `list_iter` |
| `perata.products` | `archive`, `create`, `get`, `list`, `list_iter`, `update` |
| `perata.refunds` | `create`, `list`, `list_iter` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `list_iter`, `update` |
| `perata.usage` | `ingest` |
| `perata.webhooks` | `create_endpoint`, `delete_endpoint`, `get_endpoint`, `list_deliveries`, `list_deliveries_iter`, `list_endpoints`, `list_endpoints_iter`, `update_endpoint` |

Os modelos são objetos imutáveis com leitores em snake_case (`payment.amount_cents`). O corpo de uma escrita é a classe de parâmetros do método (`Perata::ProductsCreateParams.new(name: "Curso")`) ou um `Hash` com os mesmos nomes; um campo opcional não informado fica fora do JSON. Os métodos `_iter` devolvem um `Enumerator` que percorre todas as páginas a partir de `page:` (ou recebem um bloco).

As escritas aceitam `idempotency_key:`, e todas aceitam `api_key:` para usar a chave de outra organização numa chamada. `Perata::Client.new` aceita `base_url:`, `timeout:` (30 segundos) e `transport:`. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```ruby
usage = Perata::Client.new(ENV.fetch("PERATA_USAGE_KEY")) # pus_test_… ou pus_live_…

receipt = usage.usage.ingest({ events: [{
  customer_id: customer_id,
  external_event_id: "requisicao-001", # a mesma fonte repetindo o id com o mesmo conteúdo é replay
  input_tokens: "1200",
  output_tokens: "300",
  cached_tokens: "0",
  occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") # segundos inteiros, até 90 dias atrás
}] })
# receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `external_event_id` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`event_conflict`), e um evento inválido, 422 (`invalid_events`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API levanta `Perata::Error`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retry_after` em segundos.

## Webhooks

```ruby
event = Perata.verify_webhook(ENV.fetch("PERATA_WEBHOOK_SECRET"), request.headers, request.raw_post)
case event
when Perata::OrderWebhookEvent then puts event.type, event.data.id, event.data.installments
when Perata::DisputeWebhookEvent then puts event.data.provider_dispute_id
when Perata::UnknownWebhookEvent then nil # um tipo que esta versão ainda não conhece: event.data é o JSON
end
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar; os cabeçalhos podem vir num `Hash` ou no env do Rack. Uma assinatura que não confere levanta `Perata::WebhookVerificationError`.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `Order`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `Perata.verify_webhook_signature` só confere a assinatura.

Versão do SDK: 0.3.0 · contrato da API: 0.1.0
