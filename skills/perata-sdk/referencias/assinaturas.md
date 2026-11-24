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
| `first_period_extra_days` | de 1 a 365; o comprador paga hoje o valor cheio e esses dias se somam ao primeiro período |
| `renewal_mode` | `manual`, `automatic` ou `buyer_choice`: como a assinatura renova (seção "Como a assinatura renova") |
| `notify_customer_email` | `false` deixa o aviso da cobrança de cada renovação com o seu sistema |

`subscription_start_at`: vale o **dia no horário de São Paulo** (a hora não conta), de amanhã a um ano (senão 422). O cartão é guardado e conferido com o emissor **sem cobrar nada hoje**; a assinatura fica `trialing` e a primeira cobrança acontece no dia, no cartão guardado; as seguintes seguem a periodicidade do preço a partir dele. Só vale em preço recorrente com valor e só no cartão de crédito (a página não oferece Pix nem boleto). A página mostra "Primeira cobrança em DD/MM/AAAA". Quem abre o checkout depois da data recebe 410. (SDK 0.5.6+.)

`first_period_extra_days` serve ao cliente que **já tem dias pagos em outro plano** (por exemplo, pago até 11/12, hoje 20/11, 21 dias) e quer assinar já: ele paga hoje o valor cheio do preço, com as faixas, a quantidade e o desconto, em Pix, cartão de crédito ou débito, e o primeiro período vai do dia do pagamento até esse dia mais um intervalo do preço **mais os dias extras** (hoje 20/11, preço mensal, 21 dias: até 10/01), no horário de São Paulo. A renovação e os ciclos seguintes contam a partir desse fim. A próxima cobrança, no cartão guardado ou pelo link ou Pix de renovação, só acontece nele. A página diz: "Pague hoje R$ X. Próxima cobrança em DD/MM/AAAA (inclui N dias do seu plano anterior)". Só vale em preço recorrente com valor, vendido sozinho e sem teste grátis; não vale junto com `subscription_start_at` (esse não cobra hoje) nem em preço avulso (422 no campo `first_period_extra_days`). A assinatura, o `order.paid` do 1º ciclo e `subscription.created` e `subscription.active` já trazem o período estendido em `current_period_end` (o pedido, em `period_start` e `period_end`), e `first_period_extra_days` na assinatura, em `subscription.*` e no checkout guarda o número para conferência (nulo quando o primeiro período é o comum). Ainda não está nos SDKs publicados: use a API REST até o SDK trazer o campo.

```sh
curl https://perata.sh/api/v1/checkouts \
  -H "Authorization: Bearer $PERATA_API_KEY" -H "Idempotency-Key: camera-cam-77-assinatura-2" \
  -H "Content-Type: application/json" \
  -d '{"product_id":"...","price_id":"...","first_period_extra_days":21,"customer_email":"ana@exemplo.com.br","client_reference_id":"camera-cam-77"}'
```

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

Campos úteis: `renewal_mode`, `label`, `notify_customer_email`, `amount_cents`, `quantity`, `current_period_start`, `current_period_end`, `cancel_at_period_end`, `pending_update`, `suspended_at`, `suspension_reason`, `trial_start`, `trial_end`, `metadata`, `client_reference_id`, `discount_id`, `discount_ends_at`, `first_period_extra_days`.

`discount_id` é o desconto em vigor na assinatura, aplicado aos próximos ciclos até acabar: nulo sem desconto e depois que ele acabou (num desconto de uma vez, depois do primeiro ciclo pago). `discount_ends_at` é quando ele deixa de valer, o fim do último ciclo que ele ainda abate (num desconto de uma vez, o fim do primeiro ciclo pago), e é nulo quando não há desconto e quando ele vale para sempre. O pedido de cada ciclo diz o que foi descontado nele (`discount_id`, `subtotal_cents`, `discount_cents`: veja `pos-venda.md`). Estes campos também chegam em `subscription.*`.

(`quantity` e `client_reference_id` na `Subscription` e em `subscription.*`: SDK 0.5.7+.) `quantity` é quantas unidades ou assentos a assinatura cobre (1 num preço sem quantidade), e `amount_cents` é o **total do ciclo para essa quantidade**, em centavos, com o preço por unidade, por assento ou por faixas já aplicado: não é o preço de uma unidade. Troque a quantidade com `PATCH /api/v1/subscriptions/{id}` (`quantity`).

## Como a assinatura renova (`renewal_mode`)

Mande `renewal_mode` em todo checkout de assinatura. A `Subscription` e todo `subscription.*` trazem o modo a que ele se resolveu, em `renewal_mode`: `manual`, `card` ou `pix_automatic`. `card` e `pix_automatic` são os **automáticos**.

| Você manda | O que acontece |
|---|---|
| `"manual"` | O comprador paga agora com qualquer meio (Pix, boleto, débito ou cartão). A cada ciclo a Peráta abre uma cobrança para ele pagar e avisa o seu sistema com `subscription.renewal_due`. O cartão não é guardado nem cobrado, mesmo que o primeiro pagamento tenha sido nele. A assinatura nasce com `renewal_mode: "manual"`. |
| `"automatic"` | Só meios que cobram sozinhos: cartão de crédito (guardado) ou Pix Automático, este só onde a organização o tem ligado (hoje desligado: só o cartão). A página mostra só esses meios. Pagar por Pix, boleto ou débito é 422 em `payment_method`. A assinatura nasce `card` ou `pix_automatic`. |
| `"buyer_choice"` | A página mostra a caixa "Cobrança recorrente", desmarcada. Desmarcada é `manual`; marcada é `automatic` (a página esconde os meios que não cobram sozinhos). |
| nada | Como sempre foi: sem caixa; o cartão de crédito que o pagamento guardou renova sozinho (`card`) e qualquer outro meio vira uma cobrança a cada ciclo (`manual`). |

Funciona junto com `first_period_extra_days` e com `discount_id`, inclusive no Pix Automático: a primeira cobrança do banco cai no fim do período estendido. Só vale em preço recorrente com valor (senão 422 em `renewal_mode`); `manual` não vale com teste grátis nem com `subscription_start_at`, que guardam o cartão para cobrar no fim (422). Repetir a criação com a mesma `Idempotency-Key` e outro `renewal_mode` dá 409.

Para mudar depois: `PATCH /api/v1/subscriptions/{id}` com `{"renewal_mode":"manual"}` (a Peráta solta o cartão e passa a abrir cobrança a cada ciclo) ou `{"renewal_mode":"card"}` (exige um cartão já guardado na assinatura; senão 422). `pix_automatic` só o comprador ativa, no banco. O comprador também troca no portal do cliente: "Pagar todo mês" para sair do cartão, ou escolher um cartão para voltar a ele.

## A cobrança de renovação: `subscription.renewal_due`, `open-charge` e os lembretes

Numa assinatura `manual` (ou num pagamento que não guardou cartão), o ciclo novo abre com uma cobrança para o comprador pagar, no dia em que ele começa. Nesse dia sai o evento `subscription.renewal_due`; se o cartão de uma assinatura `card` for recusado, sobra o link e o evento sai também. Uma renovação que o cartão paga sem recusa não gera o evento.

`data` do evento (e a resposta de `GET /api/v1/subscriptions/{id}/open-charge`, que tem os mesmos campos):

| Campo | O que é |
|---|---|
| `id` | o id da cobrança, que é o do ciclo. O pedido só existe depois do pagamento: o `order.paid` traz o mesmo `subscription_id` e `cycle_sequence` |
| `subscription_id`, `cycle_sequence` | a assinatura e o ciclo (2 é a primeira renovação) |
| `amount_cents`, `currency` | o que o comprador paga: o ciclo com desconto e rateio |
| `due_at` | até quando pagar sem atraso: o fim do período que a cobrança paga |
| `expires_at` | quando o `payment_url` deixa de abrir (sempre depois da tolerância de 72 h) |
| `period_start`, `period_end` | o período que a cobrança paga |
| `payment_url` | a página da Peráta onde o comprador paga, por cartão, Pix ou boleto. **Entregue este endereço ao comprador** |
| `client_reference_id`, `metadata`, `label`, `renewal_mode`, `notify_customer_email` | os da assinatura |
| `reminder`, `days_until_due` | nulos aqui; veja o lembrete |

**O Pix não vem no evento.** A Peráta gera o Pix na página do `payment_url`, quando o comprador o escolhe: o código vale 24 horas e a cobrança vale dias, e um Pix aberto impediria o comprador de pagar de outro jeito até vencer. O seu sistema entrega o `payment_url`; o QR e o copia e cola aparecem lá.

`GET /api/v1/subscriptions/{id}/open-charge` (escopo `subscriptions:read`) devolve a cobrança aberta; sem cobrança (ciclo pago, cartão ou Pix Automático, ou o próximo ciclo ainda fechado) responde 404 `no_open_charge` com a mensagem dizendo isso.

`subscription.renewal_reminder` lembra de uma cobrança ainda não paga: 3 dias antes de `due_at` (`reminder: "before_due"`, `days_until_due: 3`) e no vencimento (`"on_due"`, `0`), uma vez cada. A cobrança aberta há menos de 3 dias do vencimento só tem o lembrete do vencimento.

Quem não paga: no vencimento a assinatura vira `past_due`, o mesmo `payment_url` continua valendo por mais 72 horas de tolerância e, depois, a assinatura é suspensa, como sempre foi.

**Quem avisa o comprador.** Por padrão a Peráta também escreve a ele (e-mail "Pagamento da sua assinatura", com o `label` e o botão para pagar). Mande `notify_customer_email: false` no checkout, ou no `PATCH` da assinatura, para a Peráta ficar quieta e o seu sistema avisar pelo `payment_url`; a cobrança é aberta e anunciada do mesmo jeito. A organização também liga e desliga esse e-mail para todos em Configurações › Preferências › "Cobrança da renovação".

## Rótulo da assinatura (`label`)

O `label` do checkout (até 200 caracteres, sem caracteres de controle) vira o `label` da assinatura, e `PATCH /api/v1/subscriptions/{id}` com `{"label":"..."}` o troca (vazio tira). Ele aparece na `Subscription`, em todo `subscription.*` e em `subscription.renewal_due`, como título da assinatura no portal do cliente (com o produto e o valor embaixo), no painel e no e-mail da cobrança. Sem `label`, a assinatura aparece pelo nome do produto. Vai sozinho no `PATCH`, com `renewal_mode` e `notify_customer_email`, nunca junto de `price_id`, `quantity`, `proration_behavior` ou `extend_current_period_days`.

## Renovação

Cada ciclo é cobrado no cartão guardado, no dia do vencimento, quando o `renewal_mode` é `card`; no `manual`, ele vira uma cobrança para o comprador pagar (seção anterior). Num pagamento com cartão de crédito sem `renewal_mode`, o cartão é guardado, sem caixa para o comprador marcar; nos campos seguros, mande `card_token`, não `payment_token`. Cada ciclo gera `subscription.cycled` (com o período e o `metadata`) e, pela cobrança, `checkout_payment.captured` e `order.paid`; não conte com uma ordem entre eles. Do 2º ciclo em diante, os eventos de pagamento (`order.*`, `checkout.*`, `checkout_payment.*`, `refund.*`) trazem o `client_reference_id` e o `metadata` do checkout que vendeu a assinatura (o id do pedido e o da câmera) e `subscription_id`, `cycle_sequence` (1 é o primeiro ciclo, 2 a primeira renovação), `period_start` e `period_end`; esses quatro vêm nulos fora de assinatura. Libere ou estenda o acesso do cliente por ciclo a partir de `order.paid`, usando `period_end`, e deixe a leitura certa do que ele pode usar em `GET /customers/{id}/state`.

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
| Trocar o plano | `PATCH /api/v1/subscriptions/{id}` com `price_id` (obrigatório para trocar), `quantity`, `proration_behavior` | veja abaixo |
| Estender o período | `PATCH /api/v1/subscriptions/{id}` com `extend_current_period_days` (1 a 365), sozinho | soma dias ao período atual **sem cobrar**: crédito manual de dias. Veja abaixo |

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

### Dar dias sem cobrar

`PATCH /api/v1/subscriptions/{id}` com `{"extend_current_period_days": 21}` (de 1 a 365, sem `price_id`, `quantity` nem `proration_behavior`: junto deles é 422) estende o período atual: `current_period_end` passa a ser 21 dias depois, a renovação e a próxima cobrança passam para lá e os períodos seguintes contam a partir dele. Não cobra nada, não cria pedido e não é uma renovação (não sai `subscription.cycled`); sai `subscription.updated` com o novo período, e a ação fica no log de atividades da conta (não é um webhook), com os dias e os dois fins. Só uma assinatura `active` aceita; em teste grátis, atrasada, pausada, suspensa ou cancelada é recusada. Envie uma `Idempotency-Key`: sem ela, uma nova tentativa soma os dias duas vezes. A chave precisa de `subscriptions:write`. Ainda não está nos SDKs publicados: use a API REST.

```sh
curl -X PATCH https://perata.sh/api/v1/subscriptions/$SUBSCRIPTION_ID \
  -H "Authorization: Bearer $PERATA_API_KEY" -H "Idempotency-Key: camera-cam-77-credito-nov" \
  -H "Content-Type: application/json" -d '{"extend_current_period_days": 21}'
```

Excluir o cliente (`DELETE /customers/{id}`) encerra as assinaturas dele na hora.

## Eventos de assinatura que importam

`subscription.created`, `subscription.active`, `subscription.updated`, `subscription.cycled`, `subscription.past_due`, `subscription.suspended`, `subscription.paused`, `subscription.resumed`, `subscription.canceled`, `subscription.uncanceled` e `subscription.revoked`. Todos trazem a assinatura (`WebhookSubscription`); só `subscription.past_due`, `subscription.suspended` e o `subscription.updated` que os acompanha trazem `payment_failure`. Tratamento no seu servidor: `webhooks.md`.
