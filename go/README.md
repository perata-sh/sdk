# Peráta SDK para Go

SDK oficial da API da Peráta, gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
go get github.com/perata-sh/sdk/go
```

```go
client := perata.New(os.Getenv("PERATA_API_KEY")) // prk_test_… ou prk_live_…

product, err := client.Products.Create(ctx, perata.ProductsCreateParams{Name: "Curso"},
	perata.WithIdempotencyKey("produto-curso"))

for product, err := range client.Products.ListIter(ctx, nil) {
	if err != nil {
		return err
	}
	fmt.Println(product.Name)
}
```

Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança. Uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e você pode repetir a escrita com a mesma chave, com o corpo corrigido ou como estava.

## Recursos

| Serviço | Métodos |
|---|---|
| `client.Benefits` | `Create`, `Delete`, `Get`, `List`, `ListIter`, `ListGrants`, `ListGrantsIter`, `Update` |
| `client.CheckoutLinks` | `Create`, `Delete`, `Get`, `List`, `ListIter`, `Update` |
| `client.Checkouts` | `Create`, `Expire`, `Get`, `List`, `ListIter`, `Update` |
| `client.CustomerSessions` | `Create` |
| `client.Customers` | `Create`, `Delete`, `Get`, `GetExternal`, `GetState`, `List`, `ListIter`, `Update`, `UpdateExternal` |
| `client.Discounts` | `Create`, `Delete`, `Get`, `List`, `ListIter`, `Update` |
| `client.Disputes` | `Get`, `List`, `ListIter` |
| `client.Events` | `List`, `ListIter` |
| `client.Meters` | `Get`, `List`, `ListIter` |
| `client.Orders` | `Get`, `GetInvoice`, `GetReceipt`, `List`, `ListIter` |
| `client.PaymentMethods` | `Detach`, `List`, `ListIter` |
| `client.Payments` | `Get`, `List`, `ListIter` |
| `client.Prices` | `Create`, `Get`, `List`, `ListIter` |
| `client.Products` | `Archive`, `Create`, `Get`, `List`, `ListIter`, `Update` |
| `client.Refunds` | `Create`, `Get`, `List`, `ListIter` |
| `client.Showcase` | `Get` |
| `client.Subscriptions` | `Cancel`, `Get`, `List`, `ListIter`, `Resume`, `Update` |
| `client.Usage` | `Ingest` |
| `client.Webhooks` | `CreateEndpoint`, `DeleteEndpoint`, `GetEndpoint`, `ListDeliveries`, `ListDeliveriesIter`, `ListEndpoints`, `ListEndpointsIter`, `UpdateEndpoint` |

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```go
// No seu servidor, num handler como POST /checkout/sessao
checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{
	ProductID: productID,
	PriceID:   priceID,
})
if err != nil {
	return err
}
// Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
json.NewEncoder(w).Encode(map[string]string{
	"clientSecret": checkout.ClientSecret,
	"statusKey":    checkout.StatusKey,
})
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

```go
closed, err := client.Checkouts.Expire(ctx, checkoutID)
// closed.Status == "expired"
```

Listar com filtros: `client_reference_id` acha o pedido que você registrou ao criar o checkout, e `metadata` casa os pares que você guardou (até 10 pares; a linha precisa ter todos). Os dois valem nas listas de checkouts, pedidos, pagamentos e assinaturas, e o filtro segue nas páginas de `ListIter`.

```go
filters := &perata.OrdersListParams{
	ClientReferenceID: "pedido-123",
	Metadata:          map[string]string{"pedido": "123", "camera id": "a/b"},
}
page, err := client.Orders.List(ctx, filters)

for order, err := range client.Orders.ListIter(ctx, filters) {
	if err != nil {
		return err
	}
	fmt.Println(order.ID)
}
```

Reativar uma assinatura suspensa, que volta a ser cobrada, ou retomar uma pausada; qualquer outra assinatura responde 409:

```go
subscription, err := client.Subscriptions.Resume(ctx, subscriptionID)
```

## Reembolso, assinatura com data e showcase

Reembolsar o pedido, sem o `payment_id`: envie o `order_id` (o id que `orders.get` recebe). Sem `amount_cents` devolve tudo o que ainda pode ser devolvido; com ele, só essa parte, em centavos (de 1 até o que resta). O `metadata` do pedido de reembolso guarda pares seus, que voltam como `refund_metadata` no reembolso e nos eventos `refund.created` e `refund.updated`; `reason` e `note` dizem o motivo. O reembolso traz `order_id`, `client_reference_id` e o `metadata` do pedido, e `refunds.get` lê um pelo id. Um reembolso que falha emite `refund.failed`, com `failure_reason` (em português) e `failure_code` (o código da Cielo, para o suporte).

```go
refund, err := client.Refunds.Create(ctx, perata.RefundsCreateParams{OrderID: &orderID})
// refund.OrderID, refund.Status, refund.AmountCents

cents := int64(2500)
part, err := client.Refunds.Create(ctx, perata.RefundsCreateParams{OrderID: &orderID, AmountCents: &cents})
found, err := client.Refunds.Get(ctx, refund.ID)
```

Assinatura que começa numa data: `subscription_start_at` em `checkouts.create` é o dia da primeira cobrança, como o `trial_end` do Stripe. O cartão é guardado e conferido com o emissor, nada é cobrado hoje, e a cobrança acontece nesse dia (vale a meia-noite dele em São Paulo, qualquer que seja o fuso enviado). Só vale em um preço recorrente com valor, e só no cartão de crédito; tem de ser de amanhã a um ano, senão a resposta é 422. `items` e `discount_id` também valem num checkout de assinatura, e um pedido ou pagamento de assinatura traz `subscription_id`, `cycle_sequence`, `period_start` e `period_end`; as listas de pedidos e pagamentos aceitam o filtro `subscription_id`.

```go
start := "2026-12-15T00:00:00-03:00"
checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{
	ProductID:           productID,
	PriceID:             priceID,
	SubscriptionStartAt: &start,
})
// checkout.SubscriptionStartAt: o instante da primeira cobrança
```

Showcase: toda chave de API é de um showcase, e todo objeto da API traz o `showcase_id` dele. `showcase.get` lê o showcase da chave: o `id`, o `name`, se é o principal da organização (`is_principal`), se tem logo (`has_logo`) e o `environment` (`test` ou `live`). Uma chave só alcança o que é do seu showcase, e um 403 diz qual escopo faltou.

```go
showcase, err := client.Showcase.Get(ctx)
// showcase.ID, showcase.Name, showcase.IsPrincipal, showcase.HasLogo, showcase.Environment
```

## Preço por quantidade e assinatura com quantidade

`pricing_model` em `prices.create` diz como o valor é calculado: `fixed` (o padrão, com `amount_cents`), `per_unit` e `seat` (`unit_amount_cents` por unidade ou por assento), `volume` (a quantidade inteira pelo valor da faixa em que ela cai) e `graduated` (cada faixa pelo seu valor). `volume` e `graduated` pedem `tiers`, de 1 a 50, em ordem: `up_to` é até quantas unidades a faixa vai, inclusive, e a última faixa não leva `up_to` (sem limite). Com a 1ª unidade a R$ 250,00 e as seguintes a R$ 150,00, três unidades custam 250 + 150 + 150 = R$ 550,00. `unit_label` e `unit_label_plural` dão nome à unidade (câmera, câmeras), `minimum_units` e `maximum_units` limitam a compra, e `interval` aceita também `day` e `week`. Fora do preço fixo não se envia `amount_cents`: a API recusa com 422. **Mudança de tipo nas linguagens tipadas: `amount_cents` deixa de ser obrigatório em `PricesCreateParams`.** O preço devolvido traz `pricing_model`, `tiers`, `unit_amount_cents` e `amount_cents` 0 nos modelos por quantidade.

O checkout recebe a `quantity` e cobra pelo modelo do preço. A assinatura que nasce dele traz `quantity` e `client_reference_id` (a `Subscription` e o `subscription.*` do webhook), e o `amount_cents` dela é o **total do ciclo para essa quantity**, não o preço de uma unidade. Cada pedido de renovação volta com o mesmo `client_reference_id` e o mesmo `metadata`. O recibo do pedido traz `charged_by`, a frase "Cobrança feita por <empresa>". Um 401 e as rotas `/checkouts/client/...` respondem no mesmo formato `{error, message, fields}` dos demais erros.

```go
interval, model := perata.PriceIntervalMonth, perata.PricePricingModelGraduated
one := int64(1)
price, err := client.Prices.Create(ctx, perata.PricesCreateParams{
	ProductID:    productID,
	Type:         perata.PriceTypeRecurring,
	Interval:     &interval,
	PricingModel: &model,
	Tiers: []perata.PricesCreateTier{
		{UpTo: &one, UnitAmountCents: 25000}, // a 1ª unidade a R$ 250,00
		{UnitAmountCents: 15000},             // as seguintes a R$ 150,00
	},
})

three := int64(3)
checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{ProductID: productID, PriceID: price.ID, Quantity: &three})

subscription, err := client.Subscriptions.Get(ctx, subscriptionID)
// subscription.Quantity (3), subscription.AmountCents (55000: o total do ciclo), subscription.ClientReferenceID
```

## Dias extras no primeiro período, descontos e leitura de um preço

`first_period_extra_days` (1 a 365) em `checkouts.create` soma ao primeiro período de uma assinatura os dias que o comprador ainda tem pagos num plano anterior: ele paga hoje o valor cheio, e a próxima cobrança só acontece no fim do período mais longo. O número volta em `Checkout`, `CheckoutCreated`, `Subscription` e `WebhookSubscription` (os eventos `subscription.*`), e o estado do comprador (`CheckoutClient`) traz também `first_period_end_at`, a meia-noite, em São Paulo, do dia da próxima cobrança. `subscriptions.update` aceita `extend_current_period_days` (1 a 365) sozinho, para dar dias de crédito sem cobrar nada; por isso o `price_id` deixou de ser obrigatório. **Mudança de tipo nas linguagens tipadas: `price_id` é opcional em `SubscriptionsUpdateParams`** (não se envia junto com `extend_current_period_days`). A chamada não é repetível por si: envie uma `Idempotency-Key`, para que uma nova tentativa não some os dias duas vezes.

O pedido (`Order` e os eventos `order.*`) traz o desconto que aplicou: `discount_id`, `discount_code` (o código que o comprador digitou, nulo quando o desconto veio por `discount_id` ou da assinatura), `subtotal_cents` (antes do desconto) e `discount_cents`. A assinatura traz o desconto em vigor (`discount_id`) e quando ele acaba (`discount_ends_at`, nulo se vale para sempre), e `pending_update` (`price_id`, `quantity`, `amount_cents` do ciclo e `effective_at`) quando há uma troca de plano ou de quantidade agendada para o próximo período, nulo sem ela. `prices.get` lê um preço pelo id, também um preço arquivado. `CheckoutClientItem` ganha `bands`, as faixas de um preço graduado em que a quantidade passou da primeira.

```go
extra := int64(30)
checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{ProductID: productID, PriceID: priceID, FirstPeriodExtraDays: &extra})
// checkout.FirstPeriodExtraDays (30)

days := int64(15)
subscription, err := client.Subscriptions.Update(ctx, subscriptionID, perata.SubscriptionsUpdateParams{ExtendCurrentPeriodDays: &days}, perata.WithIdempotencyKey("credito-dias-1"))
// subscription.DiscountID, subscription.DiscountEndsAt, subscription.PendingUpdate (nil sem troca agendada)

order, err := client.Orders.Get(ctx, orderID)
// order.SubtotalCents, order.DiscountCents, order.DiscountID, order.DiscountCode

price, err := client.Prices.Get(ctx, priceID)
```

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```go
usage := perata.New(os.Getenv("PERATA_USAGE_KEY")) // pus_test_… ou pus_live_…

event := perata.UsageIngestEvent{
	CustomerID:      customerID,
	ExternalEventID: "requisicao-001", // a mesma fonte repetindo o id com o mesmo conteúdo é replay
	InputTokens:     "1200",
	OutputTokens:    "300",
	CachedTokens:    "0",
	OccurredAt:      time.Now().UTC().Format(time.RFC3339), // segundos inteiros, até 90 dias atrás
}
receipt, err := usage.Usage.Ingest(ctx, perata.UsageIngestParams{Events: []perata.UsageIngestEvent{event}})
// receipt.Created, receipt.Replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `ExternalEventID` da fonte, e repetir uma chamada é seguro (`Replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `Record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API é um `*perata.Error` com `StatusCode`, `Code` (`invalid_request`, `not_found`…), `Message`, `Fields` (o problema de cada campo), `Record` (na ingestão, o evento recusado) e, num 429, `RetryAfter`.

## Webhooks

```go
event, err := perata.VerifyWebhook(os.Getenv("PERATA_WEBHOOK_SECRET"), r.Header, body)
if err != nil {
	http.Error(w, "assinatura inválida", http.StatusBadRequest)
	return
}
switch event := event.(type) {
case *perata.OrderWebhookEvent:
	fmt.Println(event.Type, event.Data.ID, event.Data.Installments) // order.paid…
case *perata.DisputeWebhookEvent:
	fmt.Println(event.Type, event.Data.ProviderDisputeID)
case *perata.SubscriptionWebhookEvent:
	switch event.Type {
	case "subscription.past_due": // uma cobrança de cartão foi recusada
		fmt.Println(event.Data.ID, event.Data.PaymentFailure)
	case "subscription.suspended": // as tentativas acabaram
		fmt.Println(event.Data.ID, event.Data.SuspensionReason)
	}
case *perata.UnknownWebhookEvent:
	// um tipo que esta versão do SDK ainda não conhece: event.Data é o JSON
}
```

O `subscription.past_due` sai a cada cobrança de cartão recusada (`payment_failure` traz o número da tentativa e quando o cartão será cobrado de novo): mantenha o acesso do cliente até o `subscription.suspended`. Esse diz que as tentativas acabaram (`suspension_reason`): cancele a assinatura ou reative-a com `Subscriptions.Resume`.

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Leia o corpo cru e verifique antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `VerifyWebhookSignature` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `Message().Environment`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real. O showcase da venda vem em `Message().ShowcaseID` (vazio se um servidor antigo não mandou): um endpoint é de um showcase só, e o mesmo `showcase_id` está nos objetos do evento.

Versão do SDK: 0.5.8 · contrato da API: 0.1.0
