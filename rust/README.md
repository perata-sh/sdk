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
| `client.benefits()` | `create`, `delete`, `get`, `list`, `list_iter`, `list_grants`, `list_grants_iter`, `update` |
| `client.checkout_links()` | `create`, `delete`, `get`, `list`, `list_iter`, `update` |
| `client.checkouts()` | `create`, `get`, `update` |
| `client.customer_sessions()` | `create` |
| `client.customers()` | `create`, `delete`, `get`, `get_external`, `get_state`, `list`, `list_iter`, `update`, `update_external` |
| `client.discounts()` | `create`, `delete`, `get`, `list`, `list_iter`, `update` |
| `client.disputes()` | `get`, `list`, `list_iter` |
| `client.events()` | `list`, `list_iter` |
| `client.meters()` | `get`, `list`, `list_iter` |
| `client.orders()` | `get`, `get_invoice`, `get_receipt`, `list`, `list_iter` |
| `client.payment_methods()` | `detach`, `list`, `list_iter` |
| `client.payments()` | `get`, `list`, `list_iter` |
| `client.prices()` | `create`, `list`, `list_iter` |
| `client.products()` | `archive`, `create`, `get`, `list`, `list_iter`, `update` |
| `client.refunds()` | `create`, `list`, `list_iter` |
| `client.subscriptions()` | `cancel`, `get`, `list`, `list_iter`, `update` |
| `client.usage()` | `ingest` |
| `client.webhooks()` | `create_endpoint`, `delete_endpoint`, `get_endpoint`, `list_deliveries`, `list_deliveries_iter`, `list_endpoints`, `list_endpoints_iter`, `update_endpoint` |

Os corpos das escritas são structs com `new(obrigatórios…)` e um método por campo opcional; os campos opcionais não definidos não são enviados. Os campos enumerados são enums (`ProductStatus::Active`) que guardam em `Unrecognized` um valor que esta versão ainda não conhece. Antes da chamada, `.idempotency_key(…)` torna uma escrita segura para repetir, e `.api_key(…)` usa a chave de outra organização. `Client::builder(chave)` aceita `base_url`, `timeout` (30 s por padrão) e `transport`, para usar outro cliente HTTP ou testar sem rede. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```rust
// No seu servidor, num handler como POST /checkout/sessao
let checkout = client
    .checkouts()
    .create(&CheckoutsCreateParams::new(price_id, product_id))?;

// Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
let answer = serde_json::json!({
    "clientSecret": checkout.client_secret,
    "statusKey": checkout.status_key,
});
```

A resposta traz o `url` (o checkout hospedado, para redirecionar o comprador ou abrir em modal), o `session_id`, o `client_secret` com o `client_secret_expires_at` (a sessão vale 30 minutos, ou os segundos do `expires_in` que você pedir) e o `status_key`, com que o navegador acompanha um Pix ou um boleto depois que o `client_secret` é gasto. Os campos opcionais são `success_url`, `cancel_url`, `customer_email`, `customer_name`, `customer_id`, `metadata`, `allow_discount_codes`, `require_billing_address` e `expires_in`. O `client_secret` vem na criação, e só nela: na repetição de uma criação idempotente (a mesma `Idempotency-Key`) ele vem vazio, então entregue-o ao navegador na primeira resposta. Para a Peráta avisar o servidor de que o pedido foi pago, use o webhook `order.paid` (veja Webhooks).

No navegador, com o `client_secret` que o seu servidor devolveu (o site precisa estar em **Configurações › Checkout incorporado › Sites permitidos**):

```html
<div id="pagamento"></div>
<script src="https://perata.sh/v1/perata.js"></script>
<script>
  // clientSecret: o que o seu servidor devolveu acima
  Perata().components.payment({ clientSecret, onSuccess: (result) => console.log(result.status) }).mount("#pagamento");
</script>
```

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```rust
use perata::{Client, UsageIngestEvent, UsageIngestParams};

let usage = Client::new(std::env::var("PERATA_USAGE_KEY")?); // pus_test_… ou pus_live_…

let receipt = usage.usage().ingest(&UsageIngestParams::new(vec![UsageIngestEvent::new(
    "0",                      // cached_tokens
    customer_id,
    "requisicao-001",         // a mesma fonte repetindo o id com o mesmo conteúdo é replay
    "1200",                   // input_tokens
    "2026-11-13T12:00:00Z",   // occurred_at: segundos inteiros, até 90 dias atrás
    "300",                    // output_tokens
)]))?;
// receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `external_event_id` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API é `Error::Api(ApiError)`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retry_after`. Falhas de rede são `Error::Transport`, e respostas ilegíveis, `Error::Json`.

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

Versão do SDK: 0.5.0 · contrato da API: 0.1.0
