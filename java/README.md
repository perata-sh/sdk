# Peráta SDK para Java

SDK oficial da API da Peráta para Java 11+, sem dependências: só `java.net.http` e um leitor de JSON próprio. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```xml
<dependency>
    <groupId>sh.perata</groupId>
    <artifactId>sdk</artifactId>
    <version>0.5.7</version>
</dependency>
```

```kotlin
implementation("sh.perata:sdk:0.5.7") // Gradle
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
| `perata.checkouts()` | `create`, `expire`, `get`, `list`, `listIter`, `update` |
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
| `perata.refunds()` | `create`, `get`, `list`, `listIter` |
| `perata.showcase()` | `get` |
| `perata.subscriptions()` | `cancel`, `get`, `list`, `listIter`, `resume`, `update` |
| `perata.usage()` | `ingest` |
| `perata.webhooks()` | `createEndpoint`, `deleteEndpoint`, `getEndpoint`, `listDeliveries`, `listDeliveriesIter`, `listEndpoints`, `listEndpointsIter`, `updateEndpoint` |

Os modelos são imutáveis, com getters em camelCase (`payment.getAmountCents()`) e os valores enumerados como constantes (`Product.STATUS_ACTIVE`). O corpo de cada escrita é um builder aninhado no serviço (`ProductsService.CreateParams`); um campo opcional não definido fica fora da requisição. As listas aceitam `ListParams` (`page`, `limit` e os filtros) e o `…Iter` devolve um `Iterable` que percorre todas as páginas. As escritas aceitam `RequestOptions` com `idempotencyKey`, e todas aceitam `apiKey` para usar a chave de outra organização numa chamada. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança. Uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e você pode repetir a escrita com a mesma chave, com o corpo corrigido ou como estava.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```java
// No seu servidor, numa rota como POST /checkout/sessao
CheckoutCreated checkout = perata.checkouts().create(
        CheckoutsService.CreateParams.builder().productId(productId).priceId(priceId).build());

// Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
Map<String, String> answer = Map.of("clientSecret", checkout.getClientSecret(), "statusKey", checkout.getStatusKey());
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

## Encerrar, listar e reativar

Encerrar um checkout que não deve mais ser pago: a página, o `client_secret` e o QR do Pix deixam de valer (o Pix já gerado é cancelado), e o evento `checkout.expired` é enviado. Repetir a chamada é seguro; um checkout já pago, ou com boleto emitido, responde 409.

```java
CheckoutExpired closed = perata.checkouts().expire(checkoutId);
// closed.getStatus().equals("expired")
```

Listar com filtros: `client_reference_id` acha o pedido que você registrou ao criar o checkout, e `metadata` casa os pares que você guardou (até 10 pares; a linha precisa ter todos). Os dois valem nas listas de checkouts, pedidos, pagamentos e assinaturas, e o filtro segue nas páginas de `listIter`.

```java
OrdersService.ListParams filters = OrdersService.ListParams.builder()
        .clientReferenceId("pedido-123")
        .metadata(Map.of("pedido", "123", "camera id", "a/b"))
        .build();
Page<Order> page = perata.orders().list(filters);

for (Order order : perata.orders().listIter(filters)) {
    System.out.println(order.getId());
}
```

Reativar uma assinatura suspensa, que volta a ser cobrada, ou retomar uma pausada; qualquer outra assinatura responde 409:

```java
Subscription subscription = perata.subscriptions().resume(subscriptionId);
```

## Reembolso, assinatura com data e showcase

Reembolsar o pedido, sem o `payment_id`: envie o `order_id` (o id que `orders.get` recebe). Sem `amount_cents` devolve tudo o que ainda pode ser devolvido; com ele, só essa parte, em centavos (de 1 até o que resta). O `metadata` do pedido de reembolso guarda pares seus, que voltam como `refund_metadata` no reembolso e nos eventos `refund.created` e `refund.updated`; `reason` e `note` dizem o motivo. O reembolso traz `order_id`, `client_reference_id` e o `metadata` do pedido, e `refunds.get` lê um pelo id. Um reembolso que falha emite `refund.failed`, com `failure_reason` (em português) e `failure_code` (o código da Cielo, para o suporte).

```java
Refund refund = perata.refunds().create(RefundsService.CreateParams.builder().orderId(orderId).build());
// refund.getOrderId(), refund.getStatus(), refund.getAmountCents()

Refund part = perata.refunds().create(
        RefundsService.CreateParams.builder().orderId(orderId).amountCents(2500L).build());
Refund found = perata.refunds().get(refund.getId());
```

Assinatura que começa numa data: `subscription_start_at` em `checkouts.create` é o dia da primeira cobrança, como o `trial_end` do Stripe. O cartão é guardado e conferido com o emissor, nada é cobrado hoje, e a cobrança acontece nesse dia (vale a meia-noite dele em São Paulo, qualquer que seja o fuso enviado). Só vale em um preço recorrente com valor, e só no cartão de crédito; tem de ser de amanhã a um ano, senão a resposta é 422. `items` e `discount_id` também valem num checkout de assinatura, e um pedido ou pagamento de assinatura traz `subscription_id`, `cycle_sequence`, `period_start` e `period_end`; as listas de pedidos e pagamentos aceitam o filtro `subscription_id`.

```java
CheckoutCreated checkout = perata.checkouts().create(
        CheckoutsService.CreateParams.builder()
                .productId(productId)
                .priceId(priceId)
                .subscriptionStartAt("2026-12-15T00:00:00-03:00")
                .build());
// checkout.getSubscriptionStartAt(): o instante da primeira cobrança
```

Showcase: toda chave de API é de um showcase, e todo objeto da API traz o `showcase_id` dele. `showcase.get` lê o showcase da chave: o `id`, o `name`, se é o principal da organização (`is_principal`), se tem logo (`has_logo`) e o `environment` (`test` ou `live`). Uma chave só alcança o que é do seu showcase, e um 403 diz qual escopo faltou.

```java
Showcase showcase = perata.showcase().get();
// showcase.getId(), getName(), getIsPrincipal(), getHasLogo(), getEnvironment()
```

## Preço por quantidade e assinatura com quantidade

`pricing_model` em `prices.create` diz como o valor é calculado: `fixed` (o padrão, com `amount_cents`), `per_unit` e `seat` (`unit_amount_cents` por unidade ou por assento), `volume` (a quantidade inteira pelo valor da faixa em que ela cai) e `graduated` (cada faixa pelo seu valor). `volume` e `graduated` pedem `tiers`, de 1 a 50, em ordem: `up_to` é até quantas unidades a faixa vai, inclusive, e a última faixa não leva `up_to` (sem limite). Com a 1ª unidade a R$ 250,00 e as seguintes a R$ 150,00, três unidades custam 250 + 150 + 150 = R$ 550,00. `unit_label` e `unit_label_plural` dão nome à unidade (câmera, câmeras), `minimum_units` e `maximum_units` limitam a compra, e `interval` aceita também `day` e `week`. Fora do preço fixo não se envia `amount_cents`: a API recusa com 422. **Mudança de tipo nas linguagens tipadas: `amount_cents` deixa de ser obrigatório em `PricesCreateParams`.** O preço devolvido traz `pricing_model`, `tiers`, `unit_amount_cents` e `amount_cents` 0 nos modelos por quantidade.

O checkout recebe a `quantity` e cobra pelo modelo do preço. A assinatura que nasce dele traz `quantity` e `client_reference_id` (a `Subscription` e o `subscription.*` do webhook), e o `amount_cents` dela é o **total do ciclo para essa quantity**, não o preço de uma unidade. Cada pedido de renovação volta com o mesmo `client_reference_id` e o mesmo `metadata`. O recibo do pedido traz `charged_by`, a frase "Cobrança feita por <empresa>". Um 401 e as rotas `/checkouts/client/...` respondem no mesmo formato `{error, message, fields}` dos demais erros.

```java
Price price = perata.prices().create(
        PricesService.CreateParams.builder()
                .productId(productId)
                .type("recurring")
                .interval("month")
                .pricingModel("graduated")
                .tiers(List.of(
                        PricesService.PricesCreateTier.builder().upTo(1L).unitAmountCents(25000L).build(), // a 1ª unidade a R$ 250,00
                        PricesService.PricesCreateTier.builder().unitAmountCents(15000L).build())) // as seguintes a R$ 150,00
                .build());

CheckoutCreated checkout = perata.checkouts().create(
        CheckoutsService.CreateParams.builder().productId(productId).priceId(price.getId()).quantity(3L).build());

Subscription subscription = perata.subscriptions().get(subscriptionId);
// subscription.getQuantity() (3), subscription.getAmountCents() (55000: o total do ciclo), subscription.getClientReferenceId()
```

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

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `externalEventId` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `getRecord()` dizendo qual, a partir de 1.

## Erros

Uma recusa da API lança `PerataException` (não verificada), com `getStatus()`, `getCode()` (`invalid_request`, `not_found`…), `getApiMessage()`, `getFields()` (o problema de cada campo), `getRecord()` (na ingestão, o evento recusado) e, num 429, `getRetryAfter()` em segundos. Uma falha de rede lança `UncheckedIOException`.

## Webhooks

```java
WebhookEvent event = Webhook.verify(System.getenv("PERATA_WEBHOOK_SECRET"), headers, body);
if (event instanceof OrderWebhookEvent) {
    WebhookOrder order = ((OrderWebhookEvent) event).getData(); // order.created, order.paid…
} else if (event instanceof SubscriptionWebhookEvent) {
    SubscriptionWebhookEvent subscription = (SubscriptionWebhookEvent) event;
    if (subscription.getType().equals("subscription.past_due")) { // uma cobrança de cartão foi recusada
        System.out.println(subscription.getData().getPaymentFailure());
    } else if (subscription.getType().equals("subscription.suspended")) { // as tentativas acabaram
        System.out.println(subscription.getData().getSuspensionReason());
    }
} else if (event instanceof UnknownWebhookEvent) {
    // um tipo que esta versão do SDK ainda não conhece: getData() é o JSON
}
```

O `subscription.past_due` sai a cada cobrança de cartão recusada (`payment_failure` traz o número da tentativa e quando o cartão será cobrado de novo): mantenha o acesso do cliente até o `subscription.suspended`. Esse diz que as tentativas acabaram (`suspension_reason`): cancele a assinatura ou reative-a com `subscriptions().resume`.

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru (`byte[]`), antes de interpretar, e os cabeçalhos num `Map` (valores `String` ou listas). Uma assinatura inválida lança `WebhookVerificationException`.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `Webhook.verifySignature` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `getEnvironment()`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real. O showcase da venda vem em `getShowcaseId()` (vazio se um servidor antigo não mandou): um endpoint é de um showcase só, e o mesmo `showcase_id` está nos objetos do evento.

Versão do SDK: 0.5.7 · contrato da API: 0.1.0
