# Peráta SDK para Dart

SDK oficial da API da Peráta para Dart 3.8+ e Flutter (Android, iOS, desktop e web), só com `http` e `crypto`, os pacotes da equipe do Dart. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
dart pub add perata     # ou: flutter pub add perata
```

```dart
import 'dart:io';

import 'package:perata/perata.dart';

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
| `perata.checkouts` | `create` |
| `perata.customers` | `create`, `get`, `list`, `listIter` |
| `perata.orders` | `list`, `listIter` |
| `perata.paymentMethods` | `detach`, `list`, `listIter` |
| `perata.payments` | `get`, `list`, `listIter` |
| `perata.prices` | `create`, `list`, `listIter` |
| `perata.products` | `create`, `get`, `list`, `listIter` |
| `perata.refunds` | `create` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `listIter` |

Os modelos são classes imutáveis com campos em camelCase (`payment.amountCents`) e `fromJson`/`toJson` com os nomes da API; os corpos das escritas são classes `…Params`, e um campo opcional deixado nulo não é enviado. As listas devolvem uma `Page` (`items`, `pagination.totalCount`, `pagination.maxPage`), e o `…Iter` devolve um `Stream` que percorre todas as páginas. As escritas aceitam `idempotencyKey:`, e todas aceitam `apiKey:` para usar a chave de outra organização numa chamada. `Perata(…, baseUrl:, httpClient:, timeout:)` troca o endereço, o `http.Client` (por exemplo, um `MockClient` nos testes) e o limite de 30 segundos.

## Erros

Uma recusa da API lança `PerataException`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo) e, num 429, `retryAfter` em segundos.

## Webhooks

```dart
import 'package:perata/perata.dart';

final event = verifyWebhook(
  Platform.environment['PERATA_WEBHOOK_SECRET']!,
  request.headers, // Map<String, String>
  await request.readAsString(),
);
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos; uma assinatura que não confere lança `WebhookVerificationException`. Passe o corpo cru, `String` ou bytes, antes de interpretar.

Versão do SDK: 0.1.0 · contrato da API: 0.1.0
