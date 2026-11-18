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

Cada método aceita, por último, `{ idempotencyKey, apiKey, signal }`. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```ts
// No seu servidor, numa rota como POST /checkout/sessao
const checkout = await perata.checkouts.create({ product_id: productId, price_id: priceId });

// Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
return Response.json({ clientSecret: checkout.client_secret, statusKey: checkout.status_key });
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

```ts
const usage = new Perata({ apiKey: process.env.PERATA_USAGE_KEY! }); // pus_test_… ou pus_live_…

const receipt = await usage.usage.ingest({
  events: [{
    customer_id: customerId,
    external_event_id: "requisicao-001", // a mesma fonte repetindo o id com o mesmo conteúdo é replay
    input_tokens: "1200",
    output_tokens: "300",
    cached_tokens: "0",
    occurred_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), // segundos inteiros, até 90 dias atrás
  }],
});
// receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `external_event_id` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API lança `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retryAfter` em segundos.

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

Versão do SDK: 0.5.2 · contrato da API: 0.1.0
