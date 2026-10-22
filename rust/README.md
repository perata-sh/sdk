# Peráta SDK para Rust

SDK oficial da API da Peráta para Rust 1.88+ (edição 2021), síncrono, com HTTP por [ureq](https://docs.rs/ureq) e rustls, JSON por serde e HMAC por RustCrypto. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
cargo add perata-sdk
```

```rust
use perata::{Client, ProductsCreateParams, ProductsListParams};

let client = Client::new(std::env::var("PERATA_API_KEY")?); // prk_test_… ou prk_live_…

let product = client
    .products()
    .idempotency_key("produto-curso")
    .create(&ProductsCreateParams::new("Curso").description("Curso online"))?;

for product in client.products().list_iter(ProductsListParams::new()) {
    println!("{}", product?.name);
}
```

## Recursos

| Serviço | Métodos |
|---|---|
| `client.checkouts()` | `create` |
| `client.customer_sessions()` | `create` |
| `client.customers()` | `create`, `get`, `list`, `list_iter` |
| `client.orders()` | `list`, `list_iter` |
| `client.payment_methods()` | `detach`, `list`, `list_iter` |
| `client.payments()` | `get`, `list`, `list_iter` |
| `client.prices()` | `create`, `list`, `list_iter` |
| `client.products()` | `create`, `get`, `list`, `list_iter` |
| `client.refunds()` | `create` |
| `client.subscriptions()` | `cancel`, `get`, `list`, `list_iter` |

Os corpos das escritas são structs com `new(obrigatórios…)` e um método por campo opcional; os campos opcionais não definidos não são enviados. Os campos enumerados são enums (`ProductStatus::Active`) que guardam em `Unrecognized` um valor que esta versão ainda não conhece. Antes da chamada, `.idempotency_key(…)` torna uma escrita segura para repetir, e `.api_key(…)` usa a chave de outra organização. `Client::builder(chave)` aceita `base_url`, `timeout` (30 s por padrão) e `transport`, para usar outro cliente HTTP ou testar sem rede.

## Erros

Uma recusa da API é `Error::Api(ApiError)`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo) e, num 429, `retry_after`. Falhas de rede são `Error::Transport`, e respostas ilegíveis, `Error::Json`.

## Webhooks

```rust
let event = perata::verify_webhook(&std::env::var("PERATA_WEBHOOK_SECRET")?, &headers, &body)?;
match event {
    perata::WebhookEvent::Order(order) if order.type_ == "order.paid" => {
        println!("{} {}", order.data.id, order.data.installments);
    }
    perata::WebhookEvent::Dispute(dispute) => println!("{}", dispute.data.provider_dispute_id),
    _ => {}
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. `headers` pode ser um `http::HeaderMap`, um `HashMap` ou uma lista de pares. Passe o corpo cru, antes de interpretar; uma assinatura inválida ou antiga é `WebhookError::InvalidSignature`.

O evento é tipado: uma variante para cada dado que o webhook carrega (`WebhookEvent::Order` traz um `Order`, `WebhookEvent::Dispute` a disputa, `WebhookEvent::Identifiers` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `WebhookEvent::Unknown`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `verify_webhook_signature` só confere a assinatura.

Versão do SDK: 0.2.0 · contrato da API: 0.1.0
