# Peráta SDK para Swift

SDK oficial da API da Peráta para Swift 6 (macOS 12+, iOS 15+, tvOS 15+, watchOS 8+, visionOS 1+), com async/await, `URLSession` e CryptoKit, sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```swift
// Package.swift
.package(url: "https://github.com/perata-sh/sdk", from: "0.3.0"),
// e, no target:
.product(name: "Perata", package: "sdk"),
```

```swift
import Perata

let perata = PerataClient(apiKey: ProcessInfo.processInfo.environment["PERATA_API_KEY"]!) // prk_test_… ou prk_live_…

let product = try await perata.products.create(ProductsCreateParams(name: "Curso"), idempotencyKey: "produto-curso")

for try await product in perata.products.listIter() {
    print(product.name)
}
```

## Recursos

| Serviço | Métodos |
|---|---|
| `perata.benefits` | `create`, `delete`, `get`, `list`, `listIter`, `listGrants`, `listGrantsIter`, `update` |
| `perata.checkoutLinks` | `create`, `delete`, `get`, `list`, `listIter`, `update` |
| `perata.checkouts` | `create`, `get`, `update` |
| `perata.customerSessions` | `create` |
| `perata.customers` | `create`, `delete`, `get`, `getExternal`, `getState`, `list`, `listIter`, `update`, `updateExternal` |
| `perata.discounts` | `create`, `delete`, `get`, `list`, `listIter`, `update` |
| `perata.disputes` | `get`, `list`, `listIter` |
| `perata.events` | `list`, `listIter` |
| `perata.meters` | `get`, `list`, `listIter` |
| `perata.orders` | `get`, `getInvoice`, `getReceipt`, `list`, `listIter` |
| `perata.paymentMethods` | `detach`, `list`, `listIter` |
| `perata.payments` | `get`, `list`, `listIter` |
| `perata.prices` | `create`, `list`, `listIter` |
| `perata.products` | `archive`, `create`, `get`, `list`, `listIter`, `update` |
| `perata.refunds` | `create`, `list`, `listIter` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `listIter`, `update` |
| `perata.usage` | `ingest` |
| `perata.webhooks` | `createEndpoint`, `deleteEndpoint`, `getEndpoint`, `listDeliveries`, `listDeliveriesIter`, `listEndpoints`, `listEndpointsIter`, `updateEndpoint` |

Os modelos são structs `Codable` com propriedades em camelCase (`payment.amountCents`); os corpos das escritas são structs cujo inicializador pede primeiro os campos obrigatórios, e um campo opcional `nil` não é enviado. Os campos enumerados (`ProductStatus.active`) guardam em `rawValue` um valor que esta versão ainda não conhece. As escritas aceitam `idempotencyKey:`, e todas aceitam `apiKey:` para usar a chave de outra organização numa chamada. `PerataClient` aceita `baseURL`, `timeout` (30 s por padrão) e `transport`, para usar outro cliente HTTP ou testar sem rede. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```swift
let usage = PerataClient(apiKey: ProcessInfo.processInfo.environment["PERATA_USAGE_KEY"]!) // pus_test_… ou pus_live_…

let receipt = try await usage.usage.ingest(UsageIngestParams(events: [
    UsageIngestEvent(
        cachedTokens: "0",
        customerID: customerID,
        externalEventID: "requisicao-001", // a mesma fonte repetindo o id com o mesmo conteúdo é replay
        inputTokens: "1200",
        occurredAt: ISO8601DateFormatter().string(from: Date()), // segundos inteiros, até 90 dias atrás
        outputTokens: "300"
    )
]))
// receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `externalEventID` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`event_conflict`), e um evento inválido, 422 (`invalid_events`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API lança `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retryAfter` em segundos.

## Webhooks

```swift
let event = try verifyWebhook(secret: ProcessInfo.processInfo.environment["PERATA_WEBHOOK_SECRET"]!, headers: headers, body: body)
switch event {
case let .order(order) where order.type == "order.paid":
    print(order.data.id, order.data.installments)
case let .dispute(dispute):
    print(dispute.data.providerDisputeID)
default:
    break
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar; uma assinatura inválida ou antiga lança `WebhookVerificationError.invalidSignature`. A verificação usa o CryptoKit e por isso existe nas plataformas da Apple; no Linux, o cliente compila, mas a verificação dos webhooks não está disponível.

O evento é tipado: um caso para cada dado que o webhook carrega (`.order` traz um `Order`, `.dispute` a disputa, `.identifiers` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `.unknown`, com o corpo como veio. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `verifyWebhookSignature` só confere a assinatura.

Versão do SDK: 0.3.0 · contrato da API: 0.1.0
