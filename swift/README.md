# Peráta SDK para Swift

SDK oficial da API da Peráta para Swift 6 (macOS 12+, iOS 15+, tvOS 15+, watchOS 8+, visionOS 1+), com async/await, `URLSession` e CryptoKit, sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```swift
// Package.swift
.package(url: "https://github.com/perata-sh/sdk", from: "0.1.0"),
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
| `perata.checkouts` | `create` |
| `perata.customers` | `create`, `get`, `list`, `listIter` |
| `perata.orders` | `list`, `listIter` |
| `perata.paymentMethods` | `detach`, `list`, `listIter` |
| `perata.payments` | `get`, `list`, `listIter` |
| `perata.prices` | `create`, `list`, `listIter` |
| `perata.products` | `create`, `get`, `list`, `listIter` |
| `perata.refunds` | `create` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `listIter` |

Os modelos são structs `Codable` com propriedades em camelCase (`payment.amountCents`); os corpos das escritas são structs cujo inicializador pede primeiro os campos obrigatórios, e um campo opcional `nil` não é enviado. Os campos enumerados (`ProductStatus.active`) guardam em `rawValue` um valor que esta versão ainda não conhece. As escritas aceitam `idempotencyKey:`, e todas aceitam `apiKey:` para usar a chave de outra organização numa chamada. `PerataClient` aceita `baseURL`, `timeout` (30 s por padrão) e `transport`, para usar outro cliente HTTP ou testar sem rede.

## Erros

Uma recusa da API lança `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo) e, num 429, `retryAfter` em segundos.

## Webhooks

```swift
let event = try verifyWebhook(secret: ProcessInfo.processInfo.environment["PERATA_WEBHOOK_SECRET"]!, headers: headers, body: body)
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar; uma assinatura inválida ou antiga lança `WebhookVerificationError.invalidSignature`. A verificação usa o CryptoKit e por isso existe nas plataformas da Apple; no Linux, o cliente compila, mas a verificação dos webhooks não está disponível.

Versão do SDK: 0.1.0 · contrato da API: 0.1.0
