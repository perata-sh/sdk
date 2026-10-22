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
| `perata.checkouts` | `create` |
| `perata.customerSessions` | `create` |
| `perata.customers` | `create`, `get`, `list`, `listIter` |
| `perata.orders` | `list`, `listIter` |
| `perata.paymentMethods` | `detach`, `list`, `listIter` |
| `perata.payments` | `get`, `list`, `listIter` |
| `perata.prices` | `create`, `list`, `listIter` |
| `perata.products` | `create`, `get`, `list`, `listIter` |
| `perata.refunds` | `create` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `listIter` |

Cada método aceita, por último, `{ idempotencyKey, apiKey, signal }`.

## Erros

Uma recusa da API lança `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `fields` (o problema de cada campo) e, num 429, `retryAfter` em segundos.

## Webhooks

```ts
import { verifyWebhook } from "@perata-sh/sdk";

const event = await verifyWebhook(process.env.PERATA_WEBHOOK_SECRET!, request.headers, await request.text());
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar.

Versão do SDK: 0.1.1 · contrato da API: 0.1.0
