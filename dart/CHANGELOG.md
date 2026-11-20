# Changelog

Todos os SDKs da Peráta saem com a mesma versão; as mudanças de cada uma estão também nas [releases de perata-sh/sdk](https://github.com/perata-sh/sdk/releases).

## 0.5.8 (20/11/2026)

Gerado a partir do contrato da API 0.1.0 (perata.sh e1e917df).

- Dias extras no primeiro período: `checkouts.create` aceita `firstPeriodExtraDays` (1 a 365), e `Checkout`, `CheckoutCreated`, `Subscription` e `WebhookSubscription` o devolvem; o estado do comprador (`CheckoutClient`) traz também `firstPeriodEndAt`.
- `subscriptions.update` aceita `extendCurrentPeriodDays` (1 a 365), sozinho, para dar dias sem cobrar. `priceId` deixa de ser obrigatório em `SubscriptionsUpdateParams`.
- `Order` e `WebhookOrder` trazem `discountId`, `discountCode`, `subtotalCents` e `discountCents`; `Subscription` e `WebhookSubscription` trazem `discountId`, `discountEndsAt` e `pendingUpdate` (`SubscriptionPendingUpdate`, nulo sem troca agendada).
- `prices.get` lê um preço pelo id. `CheckoutClientItem` traz `bands` (`CheckoutClientItemBand`).

## 0.5.7 (20/11/2026)

Gerado a partir do contrato da API 0.1.0 (perata.sh 9ae556b4).

- Preço por quantidade: `prices.create` aceita `pricingModel` (`fixed`, o padrão, `per_unit`, `seat`, `volume` e `graduated`), `tiers` (`PricesCreateTier`: `unitAmountCents` e `upTo`; a última faixa não leva `upTo`), `unitAmountCents`, `unitLabel`, `unitLabelPlural`, `minimumUnits` e `maximumUnits`. `amountCents` deixa de ser obrigatório em `PricesCreateParams` (fora do preço fixo a API o recusa com 422). O `Price` devolvido traz `pricingModel`, `tiers` (`PriceTier`), `unitAmountCents`, `unitLabel`, `unitLabelPlural`, `minimumUnits` e `maximumUnits`; `interval` aceita também `day` e `week`.
- Assinatura com quantidade: `Subscription` e `WebhookSubscription` trazem `quantity` e `clientReferenceId`, e o `amountCents` da assinatura é o total do ciclo para essa quantidade. A renovação herda o `clientReferenceId` e o `metadata` do checkout que vendeu a assinatura.
- `OrderReceipt` traz `chargedBy`.
- Um 401 traz `message`, e as rotas `/checkouts/client/...` respondem no formato `{error, message, fields}`.
- README: preço graduated, checkout com `quantity` e leitura de uma assinatura com `quantity`.

## 0.5.6 (19/11/2026)

Gerado a partir do contrato da API 0.1.0 (perata.sh 6950e1fe). É a primeira versão publicada depois da 0.5.4: a 0.5.5 nunca saiu, e tudo o que ela trazia está aqui, junto com o que vem abaixo.

- Showcase: todo objeto traz `showcaseId` (`Checkout`, `CheckoutCreated`, `Customer`, `CustomerState`, `Order`, `Payment`, `Product`, `Refund`, `Subscription` e os modelos de webhook), e o envelope de todo webhook também (`event.showcaseId`, vazio quando um servidor antigo não o mandou). Novo `perata.showcase.get()` lê o showcase da chave: `id`, `name`, `isPrincipal`, `hasLogo` e `environment`.
- Reembolso: `refunds.create` aceita `orderId` no lugar de `paymentId` e `amountCents` opcional (sem ele devolve tudo o que ainda pode ser devolvido); `paymentId` deixa de ser obrigatório em `RefundsCreateParams`. `metadata` do pedido de reembolso volta como `refundMetadata`; `reason` e `note` são opcionais. Novo `refunds.get`. O `Refund` ganha `orderId`, `clientReferenceId`, `metadata`, `refundMetadata`, `reason` e `createdAt`, e `refunds.list` aceita `metadata`. `WebhookRefund` ganha `orderId`, `reason` e `refundMetadata`, e os eventos de um reembolso que falhou trazem `failureReason` e `failureCode`.
- Assinatura numa data: `checkouts.create` aceita `subscriptionStartAt` (o dia da primeira cobrança; nada é cobrado hoje) e `discountId`; `Checkout` e `CheckoutCreated` devolvem os dois, e `CheckoutClient` traz `firstChargeAt`.
- `Order` e `Payment` trazem `subscriptionId`, `cycleSequence`, `periodStart` e `periodEnd` (nulos fora de assinatura), e `orders.list` e `payments.list` aceitam `subscriptionId`.
- O 403 diz, no texto do erro, o escopo que falta.
- README: reembolso pelo pedido, assinatura com data e leitura do showcase.
- Da 0.5.5 (não publicada):
  - Filtro por metadata nas listas: `checkouts.list`, `orders.list`, `payments.list` e `subscriptions.list` aceitam `metadata` (`Map<String, String>`), enviado como um par por chave, `metadata[chave]=valor` (até 10 pares; a linha precisa ter todos), com as chaves em ordem e escapadas. `listIter` leva o filtro em todas as páginas.
  - `customers.list` aceita `email`.
  - `customers.create` responde 200, e não 201, quando liga ao `externalId` um cliente que já existia (um e-mail criado por um checkout); o corpo é o mesmo `Customer`.
  - Regra da `Idempotency-Key`: uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e a mesma chave pode ser enviada de novo.
  - Documentação: o resumo de cada método é curto, e a descrição da operação vem logo abaixo, em parágrafos.
  - `metadata` dos corpos declarado no contrato como objeto livre: até 50 pares, chave de 1 a 40 caracteres, valor texto, número ou booleano. O tipo continua `Map<String, Object?>`.
  - README: exemplos de `checkouts.expire`, de listas com `clientReferenceId` e `metadata`, de `subscriptions.resume` e dos eventos `subscription.past_due` e `subscription.suspended`.

## 0.5.5 (18/11/2026)

Não foi publicada: tudo o que ela trazia está na 0.5.6, acima.

Gerado a partir do contrato da API 0.1.0.

- Filtro por metadata nas listas: `checkouts.list`, `orders.list`, `payments.list` e `subscriptions.list` aceitam `metadata` (`Map<String, String>`), enviado como um par por chave, `metadata[chave]=valor` (até 10 pares; a linha precisa ter todos), com as chaves em ordem e escapadas. `listIter` leva o filtro em todas as páginas.
- `customers.list` aceita `email`.
- `customers.create` responde 200, e não 201, quando liga ao `externalId` um cliente que já existia (um e-mail criado por um checkout); o corpo é o mesmo `Customer`.
- Regra da `Idempotency-Key`: uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e a mesma chave pode ser enviada de novo.
- Documentação: o resumo de cada método é curto, e a descrição da operação vem logo abaixo, em parágrafos.
- `metadata` dos corpos declarado no contrato como objeto livre: até 50 pares, chave de 1 a 40 caracteres, valor texto, número ou booleano. O tipo continua `Map<String, Object?>`.
- README: exemplos de `checkouts.expire`, de listas com `clientReferenceId` e `metadata`, de `subscriptions.resume` e dos eventos `subscription.past_due` e `subscription.suspended`.

## 0.5.4 (18/11/2026)

Gerado a partir do contrato da API 0.1.0.

- Preços: `intervalCount` na criação e na leitura (planos de 3 e 6 meses com `interval: "month"`).
- Assinaturas: status `suspended`, com `suspendedAt` e `suspensionReason` (`retries_exhausted`, `declined_not_retryable` ou `dispute`); `subscriptions.resume` reativa uma suspensa ou retoma uma pausada. Os eventos `subscription.past_due` e `subscription.suspended` trazem `paymentFailure` (tentativa, código e motivo da recusa, próxima tentativa).
- Eventos de venda: `subscriptionId`, `cycleSequence`, `periodStart` e `periodEnd` (nulos fora de assinatura); a renovação leva o `metadata` da assinatura.
- Disputas: `paymentMethod`, `kind` (`chargeback` ou `med`), `checkoutId`, `clientReferenceId`, `metadata`, `externalCustomerId` e `subscriptionId`.
- A API libera a `Idempotency-Key` depois de uma recusa (4xx): a mesma chave com o corpo corrigido passa.

## 0.5.3 (18/11/2026)

Gerado a partir do contrato da API 0.1.0.

- O texto do erro traz os campos recusados. Quando a API não manda `message`, o texto do erro diz quais campos foram recusados e por quê (`perata: 422 invalid_request: amount_cents: …; customer_email: …`), em vez de só o código. A API passa a mandar a `message`; o SDK a usa como veio quando existe.
- `environment` em todo webhook. O envelope de toda mensagem (ao lado de `id`, `type`, `timestamp` e dos dados) traz o ambiente em que o evento aconteceu, `test` ou `live`, e `WebhookEvent.environment` o lê, inclusive em `UnknownWebhookEvent`. Um corpo sem o campo (um servidor mais antigo) continua valendo, com o ambiente vazio. Quem tem um endpoint por ambiente deve recusar o evento do ambiente errado.
- Reembolso no pedido. `Order` ganha `orderStatus` (`pending`, `paid`, `partially_refunded` ou `refunded`; nulo antes de haver pagamento) e `refundedAmountCents` (quanto já foi devolvido, em centavos); `status` continua sendo o do checkout, `succeeded`, depois de um reembolso. O evento `order.refunded` (e o `order.updated` que o acompanha) passa a trazer o novo modelo `WebhookOrder`: o `Order` mais `refundId` e `refundAmountCents`, o reembolso que causou o evento (nulos nos eventos que nenhum reembolso causou). **Mudança de tipo: `OrderWebhookEvent.data` passa de `Order` a `WebhookOrder`.**
- Reembolso no pagamento. Os eventos `checkout_payment.*` trazem `refundedAmountCents` (quanto do pagamento já foi devolvido), `checkout_payment.refunded` e `checkout_payment.partially_refunded` trazem também `refundId` e `refundAmountCents`, e os eventos `refund.*` trazem `refundId`.

## 0.5.2 (17/11/2026)

Gerado a partir do contrato da API 0.1.0.

- Encerrar um checkout: `checkouts.expire` (`POST /api/v1/checkouts/{id}/expire`) fecha um checkout que não deve mais ser pago; responde `CheckoutExpired`, com uma `CheckoutExpiredSession` por sessão. Repetir a chamada é seguro.
- Filtros nas listas: `orders.list`, `payments.list`, `checkouts.list`, `refunds.list` e `subscriptions.list` aceitam, conforme a lista, `clientReferenceId`, `status`, `customerId`, `externalCustomerId`, `createdAfter`, `createdBefore` e `sorting`. Um filtro que a lista não responde é recusado (422), em vez de ignorado.
- Identidade do cliente: `Customer` e os parâmetros de criação e alteração ganham `taxId` e `taxIdKind` (CPF ou CNPJ), `phone`, `billingName` e `billingAddress`.
- Validação mais estrita na API: caracteres de controle e marcas invisíveis de direção do texto são recusados em `clientReferenceId`, `label`, nas linhas e no metadata; `createdAfter` e `createdBefore` fora de 1970 a 9999 são recusados.

## 0.5.0 (16/11/2026)

Gerado a partir do contrato da API 0.1.0.

- Checkout transparente e embutido: `checkouts.create` (`POST /api/v1/checkouts`) abre também a sessão de compra e devolve o novo `CheckoutCreated`, que traz tudo o que `Checkout` trazia mais `sessionId`, `clientSecret`, `clientSecretExpiresAt` e `statusKey`. O servidor entrega o `clientSecret` ao navegador, que monta os campos de pagamento com o Peráta.js sem chave de API; o `statusKey` acompanha um Pix ou boleto depois que o `clientSecret` é gasto. O `clientSecret` vem na criação e só nela: na repetição de uma criação idempotente ele vem vazio. A sessão vale 30 minutos, ou o `expiresIn` pedido. **Mudança incompatível de tipo: quem declarava o retorno como `Checkout` passa a usar `CheckoutCreated`.**
- `CheckoutsCreateParams` ganha `returnUrl`, `customerId`, `externalCustomerId`, `customerEmail`, `customerName`, `metadata`, `allowDiscountCodes`, `requireBillingAddress` e `expiresIn`.
- Modelos novos do contrato: `CheckoutClient` (a sessão como o navegador a lê), com `CheckoutClientItem`, `CheckoutClientCustomer`, `CheckoutClientDiscount`, `CheckoutClientPayment`, `CheckoutClientPix` e `CheckoutClientBoleto`, além de `CheckoutInstallment`, `CheckoutNextAction`, `CheckoutSavedData`, `CheckoutSavedDataSent`, `CheckoutSavedCard`, `CheckoutSavedProfile`, `CardAuthentication` e `CardTokenization`. As rotas `/api/v1/checkouts/client/*` são chamadas pelo navegador com o `clientSecret` (pelo Peráta.js), não com a chave da API, e por isso não são métodos deste SDK.
- Um campo que pode ser nulo e aponta para um modelo (`customer`, `discount` e `payment` de `CheckoutClient`; `pix` e `boleto` de `CheckoutClientPayment`) é agora tipado como o modelo ou nulo, e não mais um valor livre.
- O README ganhou o fluxo do checkout transparente e embutido.

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
