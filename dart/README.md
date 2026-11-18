# Peráta SDK para Dart

SDK oficial da API da Peráta para Dart 3.8+ e Flutter (Android, iOS, desktop e web), só com `http` e `crypto`, os pacotes da equipe do Dart. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
dart pub add perata_sdk     # ou: flutter pub add perata_sdk
```

```dart
import 'dart:io';

import 'package:perata_sdk/perata_sdk.dart';

final perata = Perata(Platform.environment['PERATA_API_KEY']!); // prk_test_… ou prk_live_…

final product = await perata.products.create(
  const ProductsCreateParams(name: 'Curso'),
  idempotencyKey: 'produto-curso',
);

await for (final product in perata.products.listIter()) {
  print(product.name);
}

perata.close();
```

A chave da API é da organização e dá acesso a ela inteira: use o SDK no servidor. Num app Flutter, chame o seu backend em vez de embutir a chave.

## Recursos

| Serviço | Métodos |
|---|---|
| `perata.benefits` | `create`, `delete`, `get`, `list`, `listIter`, `listGrants`, `listGrantsIter`, `update` |
| `perata.checkoutLinks` | `create`, `delete`, `get`, `list`, `listIter`, `update` |
| `perata.checkouts` | `create`, `expire`, `get`, `list`, `listIter`, `update` |
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

Os modelos são classes imutáveis com campos em camelCase (`payment.amountCents`) e `fromJson`/`toJson` com os nomes da API; os corpos das escritas são classes `…Params`, e um campo opcional deixado nulo não é enviado. As listas devolvem uma `Page` (`items`, `pagination.totalCount`, `pagination.maxPage`), e o `…Iter` devolve um `Stream` que percorre todas as páginas. As escritas aceitam `idempotencyKey:`, e todas aceitam `apiKey:` para usar a chave de outra organização numa chamada. `Perata(…, baseUrl:, httpClient:, timeout:)` troca o endereço, o `http.Client` (por exemplo, um `MockClient` nos testes) e o limite de 30 segundos. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```dart
// No seu servidor (Dart no servidor, nunca num app Flutter), numa rota como POST /checkout/sessao
final checkout = await perata.checkouts.create(
  CheckoutsCreateParams(productId: productId, priceId: priceId),
);

// Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
final answer = jsonEncode({
  'clientSecret': checkout.clientSecret,
  'statusKey': checkout.statusKey,
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

```dart
final usage = Perata(Platform.environment['PERATA_USAGE_KEY']!); // pus_test_… ou pus_live_…

final receipt = await usage.usage.ingest(
  UsageIngestParams(
    events: [
      UsageIngestEvent(
        customerId: customerId,
        externalEventId: 'requisicao-001', // a mesma fonte repetindo o id com o mesmo conteúdo é replay
        inputTokens: '1200',
        outputTokens: '300',
        cachedTokens: '0',
        occurredAt: DateTime.now().toUtc().toIso8601String(), // até 90 dias atrás
      ),
    ],
  ),
);
// receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `externalEventId` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `record` dizendo qual, a partir de 1. O horário (`occurredAt`) vai em segundos inteiros: corte as frações antes de enviar.

## Erros

Uma recusa da API lança `PerataException`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retryAfter` em segundos.

## Webhooks

```dart
import 'package:perata_sdk/perata_sdk.dart';

final event = verifyWebhook(
  Platform.environment['PERATA_WEBHOOK_SECRET']!,
  request.headers, // Map<String, String>
  await request.readAsString(),
);
switch (event) {
  case OrderWebhookEvent(type: 'order.paid', :final data):
    print('${data.id} ${data.installments}');
  case DisputeWebhookEvent(:final data):
    print(data.providerDisputeId);
  case _:
    break;
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos; uma assinatura que não confere lança `WebhookVerificationException`. Passe o corpo cru, `String` ou bytes, antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `verifyWebhookSignature` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `event.environment`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real.

Versão do SDK: 0.5.3 · contrato da API: 0.1.0
