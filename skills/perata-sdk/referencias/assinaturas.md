# Assinaturas

Uma assinatura é uma cobrança que se repete (mensal, trimestral, semestral, anual) no cartão guardado do cliente. Ela nasce de um checkout de um **preço recorrente**.

## Criar a assinatura pelo checkout

1. Crie o produto e um preço `recurring` (`catalogo.md`): `interval: "month"` com `interval_count` 1, 3 ou 6, ou `interval: "year"`.
2. Crie o checkout com esse `price_id`, **sem** `amount_cents` (o preço define o valor). O cliente paga o primeiro ciclo e a assinatura nasce.
3. Guarde o que identifica a assinatura. O `client_reference_id` e o `metadata` do checkout (o id da câmera, do plano, do usuário) passam a ser os da assinatura e voltam no pedido de cada renovação e nos eventos de cada ciclo.
4. Achar depois: `GET /api/v1/subscriptions?metadata[camera_id]=cam-77` (SDK 0.5.5+), ou por `external_customer_id`, `customer_id`, `status`.

Campos extras do checkout de assinatura:

| Campo | O que faz |
|---|---|
| `items` | mostram do que o valor é feito. A soma tem de igualar o valor do preço vezes a quantidade (senão 422) e nada mais; o preço continua mandando |
| `discount_id` | aplica um desconto do catálogo (uma vez, por alguns meses ou para sempre, como foi criado). Desconto limitado a outro produto é recusado (422). Desconto só numa parte do valor ainda não existe |
| `subscription_start_at` | RFC 3339; a primeira cobrança acontece nesse dia |

`subscription_start_at`: vale o **dia no horário de São Paulo** (a hora não conta), de amanhã a um ano (senão 422). O cartão é guardado e conferido com o emissor (Zero Auth) **sem cobrar nada hoje**; a assinatura fica `trialing` e a primeira cobrança acontece no dia, no cartão guardado; as seguintes seguem a periodicidade do preço a partir dele. Só vale em preço recorrente com valor e só no cartão de crédito (a página não oferece Pix nem boleto). A página mostra "Primeira cobrança em DD/MM/AAAA". Quem abre o checkout depois da data recebe 410. (SDK 0.5.6+.)

Go:

```go
checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{
	ProductID:          productID,
	PriceID:            recurringPriceID, // preço recorrente de R$ 49,90
	ExternalCustomerID: ptr("cliente-123"),
	Metadata:           map[string]any{"camera_id": "cam-77"},
	Items: []perata.CheckoutsCreateItem{
		{Name: "Câmera Portaria", UnitAmountCents: 3990},
		{Name: "Serviço de conexão", UnitAmountCents: 1000},
	}, // 3990 + 1000 = 4990, o valor do preço
	SubscriptionStartAt: ptr("2026-12-05T00:00:00-03:00"),
	SuccessURL:          ptr("https://loja.exemplo/obrigado"),
}, perata.WithIdempotencyKey("camera-cam-77-assinatura-1"))
```

TypeScript:

```ts
const checkout = await perata.checkouts.create(
  {
    product_id: productId, price_id: recurringPriceId,
    external_customer_id: "cliente-123",
    metadata: { camera_id: "cam-77" },
    items: [
      { name: "Câmera Portaria", unit_amount_cents: 3990 },
      { name: "Serviço de conexão", unit_amount_cents: 1000 },
    ],
    subscription_start_at: "2026-12-05T00:00:00-03:00",
    success_url: "https://loja.exemplo/obrigado",
  },
  { idempotencyKey: "camera-cam-77-assinatura-1" },
);
```

Python:

```python
checkout = perata.checkouts.create({
    "product_id": product_id, "price_id": recurring_price_id,
    "external_customer_id": "cliente-123",
    "metadata": {"camera_id": "cam-77"},
    "items": [
        {"name": "Câmera Portaria", "unit_amount_cents": 3990},
        {"name": "Serviço de conexão", "unit_amount_cents": 1000},
    ],
    "subscription_start_at": "2026-12-05T00:00:00-03:00",
    "success_url": "https://loja.exemplo/obrigado",
}, idempotency_key="camera-cam-77-assinatura-1")
```

A chave precisa de `checkouts:write`, `products:read`, `subscriptions:read` e `subscriptions:write` para vender e administrar assinaturas.

## Estados

| `status` | Significa |
|---|---|
| `trialing` | em teste ou esperando a data da primeira cobrança |
| `active` | em dia |
| `past_due` | a cobrança do vencimento foi recusada; novas tentativas em curso |
| `suspended` | as tentativas acabaram (ou houve disputa); não será cobrada sozinha nem cancelada |
| `paused` | pausada |
| `canceled` | encerrada |

Campos úteis: `amount_cents`, `quantity`, `current_period_start`, `current_period_end`, `cancel_at_period_end`, `pending_update`, `suspended_at`, `suspension_reason`, `trial_start`, `trial_end`, `metadata`, `client_reference_id`, `discount_id`, `discount_ends_at`.

`discount_id` é o desconto em vigor na assinatura, aplicado aos próximos ciclos até acabar: nulo sem desconto e depois que ele acabou (num desconto de uma vez, depois do primeiro ciclo pago). `discount_ends_at` é quando ele deixa de valer, o fim do último ciclo que ele ainda abate (num desconto de uma vez, o fim do primeiro ciclo pago), e é nulo quando não há desconto e quando ele vale para sempre. O pedido de cada ciclo diz o que foi descontado nele (`discount_id`, `subtotal_cents`, `discount_cents`: veja `pos-venda.md`). Estes campos também chegam em `subscription.*`.

(`quantity` e `client_reference_id` na `Subscription` e em `subscription.*`: SDK 0.5.7+.) `quantity` é quantas unidades ou assentos a assinatura cobre (1 num preço sem quantidade), e `amount_cents` é o **total do ciclo para essa quantidade**, em centavos, com o preço por unidade, por assento ou por faixas já aplicado: não é o preço de uma unidade. Troque a quantidade com `PATCH /api/v1/subscriptions/{id}` (`quantity`).

## Renovação

Cada ciclo é cobrado no cartão guardado, no dia do vencimento. Numa assinatura paga com cartão de crédito o cartão é sempre guardado, sem caixa para o comprador marcar; nos campos seguros, mande `card_token`, não `payment_token`. Cada ciclo gera `subscription.cycled` (com o período e o `metadata`) e, pela cobrança, `checkout_payment.captured` e `order.paid`; não conte com uma ordem entre eles. Do 2º ciclo em diante, os eventos de pagamento (`order.*`, `checkout.*`, `checkout_payment.*`, `refund.*`) trazem o `client_reference_id` e o `metadata` do checkout que vendeu a assinatura (o id do pedido e o da câmera) e `subscription_id`, `cycle_sequence` (1 é o primeiro ciclo, 2 a primeira renovação), `period_start` e `period_end`; esses quatro vêm nulos fora de assinatura. Libere ou estenda o acesso do cliente por ciclo a partir de `order.paid`, usando `period_end`, e deixe a leitura certa do que ele pode usar em `GET /customers/{id}/state`.

Atenção: em 18/11/2026 a renovação automática no cartão ainda estava **desligada em Produção**. Antes de prometer a renovação ao cliente final, confirme com a Peráta (ajuda@perata.sh) que ela está ligada.

## Cartão recusado: tentativas e suspensão

A regra:

1. A cobrança do vencimento é recusada: a assinatura vira `past_due` e sai `subscription.past_due` (tentativa 1).
2. Novas tentativas nos dias **1, 3 e 5 depois do vencimento**, até 4 cobranças ao todo. Os dias são configuráveis por organização em Configurações › Preferências › Assinaturas. Cada nova recusa emite `subscription.past_due` de novo.
3. Depois da última recusa, ou de uma recusa que o banco proíbe repetir, a assinatura fica `suspended` e sai `subscription.suspended`, com `suspended_at` e `suspension_reason`: `retries_exhausted` (todas as tentativas recusadas), `declined_not_retryable` (o emissor recusou sem permitir nova tentativa) ou `dispute` (o comprador contestou o pagamento).
4. **A Peráta nunca cancela sozinha** uma assinatura cobrada no cartão. Quem decide é o seu sistema: cancelar ou reativar.
5. Se o cliente pagar o link ou trocar o cartão no portal (a troca cobra a pendência na hora) e a cobrança passar, a assinatura volta a `active` e sai `subscription.active`.

`payment_failure` (em `subscription.past_due` e `subscription.suspended`):

| Campo | Significa |
|---|---|
| `attempt` | o número da cobrança recusada no ciclo: 1 é a do vencimento, 2 a primeira nova tentativa |
| `max_attempts` | quantas cobranças o cartão recebe no ciclo |
| `decline_code`, `reason` | o código e o motivo, nas palavras do emissor |
| `retryable` | `true` se o emissor permite tentar de novo; `false` é recusa definitiva |
| `next_attempt_at` | quando o cartão será cobrado de novo; nulo se não haverá nova tentativa |
| `amount_cents`, `cycle_sequence`, `period_start`, `period_end` | a cobrança e o ciclo |

O que o seu sistema faz: em `subscription.past_due`, **mantenha o acesso** e avise o cliente (mande o link do portal); em `subscription.suspended`, bloqueie o acesso e decida, **cancelar** (`POST /subscriptions/{id}/cancel`) ou **reativar** (`POST /subscriptions/{id}/resume`).

```go
switch event := event.(type) {
case *perata.SubscriptionWebhookEvent:
	switch event.Type {
	case "subscription.past_due":
		f := event.Data.PaymentFailure // preenchido só neste evento
		log.Printf("assinatura %s: recusa %d de %d (%s)", event.Data.ID, f.Attempt, f.MaxAttempts, f.Reason)
	case "subscription.suspended":
		reason := ""
		if r := event.Data.SuspensionReason; r != nil {
			reason = *r
		}
		log.Printf("assinatura %s suspensa: %s", event.Data.ID, reason)
	}
}
```

## Reativar, cancelar e trocar o plano

| Ação | Rota | Detalhe |
|---|---|---|
| Reativar | `POST /api/v1/subscriptions/{id}/resume` | reativa uma `suspended` (a cobrança do ciclo em aberto recomeça) ou retoma uma `paused`; qualquer outra recebe 409 |
| Cancelar | `POST /api/v1/subscriptions/{id}/cancel` com `at_period_end` e `reason` | por padrão o cancelamento vale no **fim do período já pago**; para cancelar já, envie `at_period_end: false` (confirme no Teste) |
| Trocar o plano | `PATCH /api/v1/subscriptions/{id}` com `price_id` (obrigatório), `quantity`, `proration_behavior` | veja abaixo |

`proration_behavior`: `prorate` (padrão: rateia o resto do período no próximo valor cobrado), `invoice` (cobra a diferença agora), `next_period` (troca no fim do período, **a troca de preço no ciclo seguinte**) e `reset` (cobra o período inteiro do novo plano agora e reinicia o ciclo).

- `invoice` cria na hora um pedido só da diferença dos dias que faltam (o novo total menos o antigo, proporcional aos dias inteiros entre a próxima meia-noite, no fuso da assinatura, e o fim do período; o dia da troca não é cobrado), cobrado no cartão guardado ou, sem cartão, por um link enviado ao comprador. O período e o pedido já pagos não mudam: `current_period_start` e `current_period_end` seguem os mesmos, e o pedido da diferença traz o mesmo `subscription_id`, `metadata` e `client_reference_id`. Não sai `subscription.cycled`, porque não é uma renovação: saem `subscription.updated` e, quando o pedido é pago, `order.created`, `order.updated` e `order.paid`. Reduzir a quantidade não cobra nada agora; o crédito entra no próximo ciclo.
- `prorate` troca o plano na hora e põe a diferença no próximo valor cobrado, sem mexer no período. `next_period` não troca nada agora: o que fica para o fim do período aparece em `pending_update` (`price_id`, `quantity`, `amount_cents`, `effective_at`), que é nulo quando não há nada agendado (agendar o mesmo `price_id` e a mesma `quantity` que a assinatura já tem apaga o agendamento, e uma troca ou um cancelamento imediato também); até `effective_at` a assinatura segue com a `quantity` e o `amount_cents` de hoje.

```go
_, err := client.Subscriptions.Update(ctx, subscriptionID, perata.SubscriptionsUpdateParams{
	PriceID:           newPriceID,
	ProrationBehavior: ptr("next_period"),
})
_, err = client.Subscriptions.Cancel(ctx, subscriptionID, perata.SubscriptionsCancelParams{Reason: ptr("camera excluída")})
_, err = client.Subscriptions.Resume(ctx, subscriptionID)
```

```ts
await perata.subscriptions.update(subscriptionId, { price_id: newPriceId, proration_behavior: "next_period" });
await perata.subscriptions.cancel(subscriptionId, { reason: "camera excluída" });
await perata.subscriptions.resume(subscriptionId);
```

```python
perata.subscriptions.update(subscription_id, {"price_id": new_price_id, "proration_behavior": "next_period"})
perata.subscriptions.cancel(subscription_id, {"reason": "camera excluída"})
perata.subscriptions.resume(subscription_id)
```

Excluir o cliente (`DELETE /customers/{id}`) encerra as assinaturas dele na hora.

## Eventos de assinatura que importam

`subscription.created`, `subscription.active`, `subscription.updated`, `subscription.cycled`, `subscription.past_due`, `subscription.suspended`, `subscription.paused`, `subscription.resumed`, `subscription.canceled`, `subscription.uncanceled` e `subscription.revoked`. Todos trazem a assinatura (`WebhookSubscription`); só `subscription.past_due`, `subscription.suspended` e o `subscription.updated` que os acompanha trazem `payment_failure`. Tratamento no seu servidor: `webhooks.md`.
