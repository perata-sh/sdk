# Changelog

Todos os SDKs da Peráta saem com a mesma versão; as mudanças de cada uma estão também nas [releases de perata-sh/sdk](https://github.com/perata-sh/sdk/releases).

## 0.4.0 (14/11/2026)

Gerado a partir do contrato da API 0.1.0.

- Ingestão de consumo: `usage.ingest` (`POST /api/v1/usage/token-events`) em todas as linguagens, com os modelos `UsageIngestEvent` (e seus `_cost` e `_llm`), `UsageIngestParams` e `UsageIngestReceipt`. Ela usa a credencial de uma fonte de consumo (`pus_test_…` ou `pus_live_…`), e não a chave da API da organização, então o cliente é criado com ela; não leva `Idempotency-Key`, porque o evento se identifica pelo `externalEventId` da fonte e repetir uma chamada é seguro. O erro do SDK traz `record`, a posição, a partir de 1, do evento do lote que a API recusou (0 em qualquer outro erro).
- Todo erro da API é agora o documento plano `{error, message, fields}` (com `record` na ingestão), o mesmo em toda a `/api/v1`, descrito pelo modelo novo `UsageError`. O cliente continua lendo o formato antigo, com o erro dentro de `data`, quando fala com um servidor mais velho. **Mudança incompatível: os códigos de erro da ingestão mudaram.** `invalid_events`, `invalid_json` e `invalid_body` agora são `invalid_request`; `event_conflict` é `conflict`; `json_required` é `unsupported_media_type`; `ingestion_unavailable` é `unavailable`. Quem comparava o código de um erro da ingestão com os nomes antigos precisa trocar.
- Contrato: as escritas com corpo respondem 415 `unsupported_media_type` quando o corpo não é JSON, e um 401 traz `WWW-Authenticate: Bearer`. Os campos documentados ficaram mais estritos: o `name` de um cliente não pode ser vazio, a `quantity` de um checkout ou link de checkout é no mínimo 1, e `interval` (obrigatório no preço recorrente) e `external_id` (até 120 caracteres, sem barra) ganharam descrição.

## 0.3.0 (01/11/2026)

Gerado a partir do contrato da API 0.1.0.

- Os clientes recusam redirecionamentos, para que a chave da API nunca siga um; recusam um endereço base que não seja `https` (`http` só para `localhost`, `127.0.0.0/8` e `::1`), e todo POST sem `Idempotency-Key` sai com uma UUID v4 aleatória, uma por chamada. A verificação de webhooks só aceita um `webhook-timestamp` de dígitos ASCII. **Quem apontava o `baseUrl` para um endereço `http` que não seja local precisa passar a usar `https`.**
- Contrato novo da API: `customers.getState` (assinaturas ativas e benefícios vigentes de um cliente, inclusive os feature flags), os modelos `CustomerState` e `CustomerStateBenefitGrant`, `benefitMetadata` e `properties` em `BenefitGrant`, `metadata`, `trialStart` e `trialEnd` em `Subscription`, e os modelos `WebhookBenefit` e `WebhookDiscount`. Os valores livres (`Map<String, Object?>`) são qualquer JSON. Os eventos `benefit.created`, `benefit.updated`, `discount.created`, `discount.updated`, `discount.deleted`, `product.created` e `product.updated` agora chegam como `BenefitWebhookEvent`, `DiscountWebhookEvent` e `ProductWebhookEvent`, com o objeto completo, e não mais como `IdentifiersWebhookEvent`. **Mudança incompatível para quem tratava esses tipos como `IdentifiersWebhookEvent`.**
- A API pública passou de 21 para 61 operações. Recursos novos: `discounts`, `checkoutLinks` (links de checkout), `benefits` (com `listGrants`), `webhooks` (endpoints e entregas), `meters`, `events` e `disputes`. Operações novas em recursos antigos: `products.update` e `archive`, `customers.update`, `delete`, `getExternal` e `updateExternal` (por `external_id`), `checkouts.get` e `update`, `orders.get`, `getInvoice` e `getReceipt`, `refunds.list` e `subscriptions.update`. Toda lista nova tem o seu `…Iter`. As remoções (`DELETE`) respondem 204 e não devolvem nada: `Future<void>`.
- **Mudanças incompatíveis:** `BenefitGrant.benefitType` passa a ser um valor enumerado (em Dart continua `String`, com as constantes de `BenefitGrant`; em Rust e Swift é um tipo próprio); `Checkout` e `BenefitGrant` ganham campos obrigatórios (`status`, `label`, `quantity`, `successUrl`, `cancelUrl`, `expiresAt` e `createdAt` no `Checkout`), o que só afeta quem constrói esses objetos à mão.

## 0.2.0

Gerado a partir do contrato da API 0.1.0.

- Webhooks tipados: `verifyWebhook` responde um `WebhookEvent` selado, uma classe para cada dado que o evento carrega (`OrderWebhookEvent`, `SubscriptionWebhookEvent`, `CheckoutWebhookEvent`, `DisputeWebhookEvent`, `BenefitGrantWebhookEvent`, `IdentifiersWebhookEvent`…), e `UnknownWebhookEvent` para um tipo que esta versão ainda não conhece. Antes, `data` era um mapa de textos. **Mudança incompatível.**
- `verifyWebhookSignature`, que só confere a assinatura; os testes conferem o vetor do próprio Standard Webhooks e a rotação do segredo (duas assinaturas no cabeçalho).
- `customerSessions.create`: abre o portal do cliente já autenticado.
- `Order` e `Payment` trazem o parcelamento: `installments`, `installmentInterestCents` e, no pagamento, `installmentAmountCents`.

## 0.1.1

- Primeira versão publicada: produtos, preços, clientes, checkouts, pedidos, pagamentos, cartões salvos, assinaturas e reembolsos, com paginação, `Idempotency-Key`, erros tipados e verificação dos webhooks.
