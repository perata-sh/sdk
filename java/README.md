# Peráta SDK para Java

SDK oficial da API da Peráta para Java 11+, sem dependências: só `java.net.http` e um leitor de JSON próprio. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```xml
<dependency>
    <groupId>sh.perata</groupId>
    <artifactId>sdk</artifactId>
    <version>0.3.0</version>
</dependency>
```

```kotlin
implementation("sh.perata:sdk:0.3.0") // Gradle
```

```java
import sh.perata.Perata;
import sh.perata.Product;
import sh.perata.ProductsService;
import sh.perata.RequestOptions;

Perata perata = new Perata(System.getenv("PERATA_API_KEY")); // prk_test_… ou prk_live_…

Product product = perata.products().create(
        ProductsService.CreateParams.builder().name("Curso").build(),
        RequestOptions.builder().idempotencyKey("produto-curso").build());

for (Product each : perata.products().listIter()) {
    System.out.println(each.getName());
}
```

`Perata.builder(apiKey).baseUrl(…).timeout(…).transport(…).build()` troca o endereço, o tempo de espera (30 s por padrão) ou o HTTP (`HttpTransport` recebe um `HttpClient` seu). O cliente pode ser compartilhado entre threads.

## Recursos

| Serviço | Métodos |
|---|---|
| `perata.benefits()` | `create`, `delete`, `get`, `list`, `listIter`, `listGrants`, `listGrantsIter`, `update` |
| `perata.checkoutLinks()` | `create`, `delete`, `get`, `list`, `listIter`, `update` |
| `perata.checkouts()` | `create`, `get`, `update` |
| `perata.customerSessions()` | `create` |
| `perata.customers()` | `create`, `delete`, `get`, `getExternal`, `getState`, `list`, `listIter`, `update`, `updateExternal` |
| `perata.discounts()` | `create`, `delete`, `get`, `list`, `listIter`, `update` |
| `perata.disputes()` | `get`, `list`, `listIter` |
| `perata.events()` | `list`, `listIter` |
| `perata.meters()` | `get`, `list`, `listIter` |
| `perata.orders()` | `get`, `getInvoice`, `getReceipt`, `list`, `listIter` |
| `perata.paymentMethods()` | `detach`, `list`, `listIter` |
| `perata.payments()` | `get`, `list`, `listIter` |
| `perata.prices()` | `create`, `list`, `listIter` |
| `perata.products()` | `archive`, `create`, `get`, `list`, `listIter`, `update` |
| `perata.refunds()` | `create`, `list`, `listIter` |
| `perata.subscriptions()` | `cancel`, `get`, `list`, `listIter`, `update` |
| `perata.usage()` | `ingest` |
| `perata.webhooks()` | `createEndpoint`, `deleteEndpoint`, `getEndpoint`, `listDeliveries`, `listDeliveriesIter`, `listEndpoints`, `listEndpointsIter`, `updateEndpoint` |

Os modelos são imutáveis, com getters em camelCase (`payment.getAmountCents()`) e os valores enumerados como constantes (`Product.STATUS_ACTIVE`). O corpo de cada escrita é um builder aninhado no serviço (`ProductsService.CreateParams`); um campo opcional não definido fica fora da requisição. As listas aceitam `ListParams` (`page`, `limit` e os filtros) e o `…Iter` devolve um `Iterable` que percorre todas as páginas. As escritas aceitam `RequestOptions` com `idempotencyKey`, e todas aceitam `apiKey` para usar a chave de outra organização numa chamada. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```java
Perata usage = new Perata(System.getenv("PERATA_USAGE_KEY")); // pus_test_… ou pus_live_…

UsageIngestReceipt receipt = usage.usage().ingest(UsageService.IngestParams.builder()
        .events(List.of(UsageService.UsageIngestEvent.builder()
                .customerId(customerId)
                .externalEventId("requisicao-001") // a mesma fonte repetindo o id com o mesmo conteúdo é replay
                .inputTokens("1200")
                .outputTokens("300")
                .cachedTokens("0")
                .occurredAt(Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()) // segundos inteiros, até 90 dias atrás
                .build()))
        .build());
// receipt.getCreated(), receipt.getReplayed()
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `externalEventId` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`event_conflict`), e um evento inválido, 422 (`invalid_events`) com `getRecord()` dizendo qual, a partir de 1.

## Erros

Uma recusa da API lança `PerataException` (não verificada), com `getStatus()`, `getCode()` (`invalid_request`, `not_found`…), `getApiMessage()`, `getFields()` (o problema de cada campo), `getRecord()` (na ingestão, o evento recusado) e, num 429, `getRetryAfter()` em segundos. Uma falha de rede lança `UncheckedIOException`.

## Webhooks

```java
WebhookEvent event = Webhook.verify(System.getenv("PERATA_WEBHOOK_SECRET"), headers, body);
if (event instanceof OrderWebhookEvent) {
    Order order = ((OrderWebhookEvent) event).getData(); // order.created, order.paid…
} else if (event instanceof UnknownWebhookEvent) {
    // um tipo que esta versão do SDK ainda não conhece: getData() é o JSON
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru (`byte[]`), antes de interpretar, e os cabeçalhos num `Map` (valores `String` ou listas). Uma assinatura inválida lança `WebhookVerificationException`.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `Order`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `Webhook.verifySignature` só confere a assinatura.

Versão do SDK: 0.3.0 · contrato da API: 0.1.0
