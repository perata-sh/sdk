# Peráta SDK para TypeScript

SDK oficial da API da Peráta para TypeScript e JavaScript (Node 20.3+, Deno, Bun e navegadores com `fetch`), sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
npm install @perata-sh/sdk
```

```ts
import { Perata } from "@perata-sh/sdk";

const perata = new Perata({ apiKey: process.env.PERATA_API_KEY! }); // prk_test_… ou prk_live_…

const product = await perata.products.create({ name: "Curso" }, { idempotencyKey: "produto-curso" });

for await (const product of perata.products.listIter()) {
  console.log(product.name);
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
| `perata.webhooks` | `createEndpoint`, `deleteEndpoint`, `getEndpoint`, `listDeliveries`, `listDeliveriesIter`, `listEndpoints`, `listEndpointsIter`, `updateEndpoint` |

Cada método aceita, por último, `{ idempotencyKey, apiKey, signal }`. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Erros

Uma recusa da API lança `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `fields` (o problema de cada campo) e, num 429, `retryAfter` em segundos.

## Webhooks

```ts
import { verifyWebhook } from "@perata-sh/sdk";

const event = await verifyWebhook(process.env.PERATA_WEBHOOK_SECRET!, request.headers, await request.text());
switch (event.type) {
  case "order.paid":
    console.log(event.data.id, event.data.installments); // event.data é um Order
    break;
  case "dispute.opened":
    console.log(event.data.provider_dispute_id); // event.data é um WebhookDispute
    break;
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `Order`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como veio, fora da união. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `verifyWebhookSignature` só confere a assinatura.

Versão do SDK: 0.3.0 · contrato da API: 0.1.0
