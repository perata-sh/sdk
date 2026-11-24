# Peráta SDK para .NET

SDK oficial da API da Peráta para C# e .NET 8+ (LTS), sem dependências: `HttpClient`, `System.Text.Json` com serialização gerada em compilação (compatível com trimming e Native AOT) e `HMACSHA256`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
dotnet add package PerataSh.Sdk
```

```csharp
using Perata;

var perata = new PerataClient(Environment.GetEnvironmentVariable("PERATA_API_KEY")!); // prk_test_… ou prk_live_…

var product = await perata.Products.CreateAsync(
    new ProductsCreateParams { Name = "Curso" },
    new RequestOptions { IdempotencyKey = "produto-curso" });

await foreach (var each in perata.Products.ListIterAsync())
{
    Console.WriteLine(each.Name);
}
```

`new PerataClient(apiKey, new PerataClientOptions { BaseUrl = …, Timeout = …, HttpClient = … })` troca o endereço, o tempo de espera (30 s por padrão) ou o HTTP (um `HttpClient` do `IHttpClientFactory`, ou um `Handler`). O cliente pode ser compartilhado entre threads.

## Recursos

| Serviço | Métodos |
|---|---|
| `perata.Balance` | `GetAsync` |
| `perata.Benefits` | `CreateAsync`, `DeleteAsync`, `GetAsync`, `ListAsync`, `ListIterAsync`, `ListGrantsAsync`, `ListGrantsIterAsync`, `UpdateAsync` |
| `perata.CheckoutLinks` | `CreateAsync`, `DeleteAsync`, `GetAsync`, `ListAsync`, `ListIterAsync`, `UpdateAsync` |
| `perata.Checkouts` | `CreateAsync`, `ExpireAsync`, `GetAsync`, `ListAsync`, `ListIterAsync`, `UpdateAsync` |
| `perata.CustomerSessions` | `CreateAsync` |
| `perata.Customers` | `CreateAsync`, `DeleteAsync`, `GetAsync`, `GetExternalAsync`, `GetStateAsync`, `ListAsync`, `ListIterAsync`, `UpdateAsync`, `UpdateExternalAsync` |
| `perata.Discounts` | `CreateAsync`, `DeleteAsync`, `GetAsync`, `ListAsync`, `ListIterAsync`, `UpdateAsync` |
| `perata.Disputes` | `GetAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Events` | `ListAsync`, `ListIterAsync` |
| `perata.Meters` | `GetAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Orders` | `GetAsync`, `GetInvoiceAsync`, `GetReceiptAsync`, `ListAsync`, `ListIterAsync` |
| `perata.PaymentMethods` | `DetachAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Payments` | `GetAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Payouts` | `GetAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Prices` | `CreateAsync`, `GetAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Products` | `ArchiveAsync`, `CreateAsync`, `GetAsync`, `ListAsync`, `ListIterAsync`, `UpdateAsync` |
| `perata.Refunds` | `CreateAsync`, `GetAsync`, `ListAsync`, `ListIterAsync` |
| `perata.Showcase` | `GetAsync` |
| `perata.Subscriptions` | `CancelAsync`, `GetAsync`, `GetOpenChargeAsync`, `ListAsync`, `ListIterAsync`, `ResumeAsync`, `UpdateAsync` |
| `perata.Usage` | `IngestAsync` |
| `perata.Webhooks` | `CreateEndpointAsync`, `DeleteEndpointAsync`, `GetEndpointAsync`, `ListDeliveriesAsync`, `ListDeliveriesIterAsync`, `ListEndpointsAsync`, `ListEndpointsIterAsync`, `UpdateEndpointAsync` |

Os modelos são `record`s imutáveis em PascalCase (`payment.AmountCents`), com os valores enumerados como constantes (`Product.StatusActive`). O corpo de cada escrita é um `record` com membros `required` (`ProductsCreateParams`); um campo opcional nulo fica fora da requisição. As listas aceitam `…ListParams` (`Page`, `Limit` e os filtros) e o `…IterAsync` devolve um `IAsyncEnumerable` que percorre todas as páginas. Todo método aceita, por último, `RequestOptions` (`IdempotencyKey` nas escritas, `ApiKey` para usar a chave de outra organização numa chamada) e um `CancellationToken`. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança. Uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e você pode repetir a escrita com a mesma chave, com o corpo corrigido ou como estava.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```csharp
// No seu servidor, num endpoint como POST /checkout/sessao
var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams { ProductId = productId, PriceId = priceId });

// Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
return Results.Json(new { clientSecret = checkout.ClientSecret, statusKey = checkout.StatusKey });
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

```csharp
var closed = await perata.Checkouts.ExpireAsync(checkoutId);
// closed.Status == "expired"
```

Listar com filtros: `client_reference_id` acha o pedido que você registrou ao criar o checkout, e `metadata` casa os pares que você guardou (até 10 pares; a linha precisa ter todos). Os dois valem nas listas de checkouts, pedidos, pagamentos e assinaturas, e o filtro segue nas páginas de `ListIterAsync`.

```csharp
var filters = new OrdersListParams
{
    ClientReferenceId = "pedido-123",
    Metadata = new Dictionary<string, string> { ["pedido"] = "123", ["camera id"] = "a/b" },
};
var page = await perata.Orders.ListAsync(filters);

await foreach (var order in perata.Orders.ListIterAsync(filters))
{
    Console.WriteLine(order.Id);
}
```

Reativar uma assinatura suspensa, que volta a ser cobrada, ou retomar uma pausada; qualquer outra assinatura responde 409:

```csharp
var subscription = await perata.Subscriptions.ResumeAsync(subscriptionId);
```

## Reembolso, assinatura com data e showcase

Reembolsar o pedido, sem o `payment_id`: envie o `order_id` (o id que `orders.get` recebe). Sem `amount_cents` devolve tudo o que ainda pode ser devolvido; com ele, só essa parte, em centavos (de 1 até o que resta). O `metadata` do pedido de reembolso guarda pares seus, que voltam como `refund_metadata` no reembolso e nos eventos `refund.created` e `refund.updated`; `reason` e `note` dizem o motivo. O reembolso traz `order_id`, `client_reference_id` e o `metadata` do pedido, e `refunds.get` lê um pelo id. Um reembolso que falha emite `refund.failed`, com `failure_reason` (em português) e `failure_code` (o código do processador de pagamentos, para o suporte).

```csharp
var refund = await perata.Refunds.CreateAsync(new RefundsCreateParams { OrderId = orderId });
// refund.OrderId, refund.Status, refund.AmountCents

var part = await perata.Refunds.CreateAsync(new RefundsCreateParams { OrderId = orderId, AmountCents = 2500 });
var found = await perata.Refunds.GetAsync(refund.Id);
```

Assinatura que começa numa data: `subscription_start_at` em `checkouts.create` é o dia da primeira cobrança, como o `trial_end` do Stripe. O cartão é guardado e conferido com o emissor, nada é cobrado hoje, e a cobrança acontece nesse dia (vale a meia-noite dele em São Paulo, qualquer que seja o fuso enviado). Só vale em um preço recorrente com valor, e só no cartão de crédito; tem de ser de amanhã a um ano, senão a resposta é 422. `items` e `discount_id` também valem num checkout de assinatura, e um pedido ou pagamento de assinatura traz `subscription_id`, `cycle_sequence`, `period_start` e `period_end`; as listas de pedidos e pagamentos aceitam o filtro `subscription_id`.

```csharp
var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams
{
    ProductId = productId,
    PriceId = priceId,
    SubscriptionStartAt = "2026-12-15T00:00:00-03:00",
});
// checkout.SubscriptionStartAt: o instante da primeira cobrança
```

Showcase: toda chave de API é de um showcase, e todo objeto da API traz o `showcase_id` dele. `showcase.get` lê o showcase da chave: o `id`, o `name`, se é o principal da organização (`is_principal`), se tem logo (`has_logo`) e o `environment` (`test` ou `live`). Uma chave só alcança o que é do seu showcase, e um 403 diz qual escopo faltou.

```csharp
var showcase = await perata.Showcase.GetAsync();
// showcase.Id, showcase.Name, showcase.IsPrincipal, showcase.HasLogo, showcase.Environment
```

## Preço por quantidade e assinatura com quantidade

`pricing_model` em `prices.create` diz como o valor é calculado: `fixed` (o padrão, com `amount_cents`), `per_unit` e `seat` (`unit_amount_cents` por unidade ou por assento), `volume` (a quantidade inteira pelo valor da faixa em que ela cai) e `graduated` (cada faixa pelo seu valor). `volume` e `graduated` pedem `tiers`, de 1 a 50, em ordem: `up_to` é até quantas unidades a faixa vai, inclusive, e a última faixa não leva `up_to` (sem limite). Com a 1ª unidade a R$ 250,00 e as seguintes a R$ 150,00, três unidades custam 250 + 150 + 150 = R$ 550,00. `unit_label` e `unit_label_plural` dão nome à unidade (câmera, câmeras), `minimum_units` e `maximum_units` limitam a compra, e `interval` aceita também `day` e `week`. Fora do preço fixo não se envia `amount_cents`: a API recusa com 422. **Mudança de tipo nas linguagens tipadas: `amount_cents` deixa de ser obrigatório em `PricesCreateParams`.** O preço devolvido traz `pricing_model`, `tiers`, `unit_amount_cents` e `amount_cents` 0 nos modelos por quantidade.

O checkout recebe a `quantity` e cobra pelo modelo do preço. A assinatura que nasce dele traz `quantity` e `client_reference_id` (a `Subscription` e o `subscription.*` do webhook), e o `amount_cents` dela é o **total do ciclo para essa quantity**, não o preço de uma unidade. Cada pedido de renovação volta com o mesmo `client_reference_id` e o mesmo `metadata`. O recibo do pedido traz `charged_by`, a frase "Cobrança feita por <empresa>". Um 401 e as rotas `/checkouts/client/...` respondem no mesmo formato `{error, message, fields}` dos demais erros.

```csharp
var price = await perata.Prices.CreateAsync(new PricesCreateParams
{
    ProductId = productId,
    Type = PricesCreateParams.TypeRecurring,
    Interval = PricesCreateParams.IntervalMonth,
    PricingModel = PricesCreateParams.PricingModelGraduated,
    Tiers =
    [
        new PricesCreateTier { UpTo = 1, UnitAmountCents = 25000 }, // a 1ª unidade a R$ 250,00
        new PricesCreateTier { UnitAmountCents = 15000 }, // as seguintes a R$ 150,00
    ],
});

var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams { ProductId = productId, PriceId = price.Id, Quantity = 3 });

var subscription = await perata.Subscriptions.GetAsync(subscriptionId);
// subscription.Quantity (3), subscription.AmountCents (55000: o total do ciclo), subscription.ClientReferenceId
```

## Dias extras no primeiro período, descontos e leitura de um preço

`first_period_extra_days` (1 a 365) em `checkouts.create` soma ao primeiro período de uma assinatura os dias que o comprador ainda tem pagos num plano anterior: ele paga hoje o valor cheio, e a próxima cobrança só acontece no fim do período mais longo. O número volta em `Checkout`, `CheckoutCreated`, `Subscription` e `WebhookSubscription` (os eventos `subscription.*`), e o estado do comprador (`CheckoutClient`) traz também `first_period_end_at`, a meia-noite, em São Paulo, do dia da próxima cobrança. `subscriptions.update` aceita `extend_current_period_days` (1 a 365) sozinho, para dar dias de crédito sem cobrar nada; por isso o `price_id` deixou de ser obrigatório. **Mudança de tipo nas linguagens tipadas: `price_id` é opcional em `SubscriptionsUpdateParams`** (não se envia junto com `extend_current_period_days`). A chamada não é repetível por si: envie uma `Idempotency-Key`, para que uma nova tentativa não some os dias duas vezes.

O pedido (`Order` e os eventos `order.*`) traz o desconto que aplicou: `discount_id`, `discount_code` (o código que o comprador digitou, nulo quando o desconto veio por `discount_id` ou da assinatura), `subtotal_cents` (antes do desconto) e `discount_cents`. A assinatura traz o desconto em vigor (`discount_id`) e quando ele acaba (`discount_ends_at`, nulo se vale para sempre), e `pending_update` (`price_id`, `quantity`, `amount_cents` do ciclo e `effective_at`) quando há uma troca de plano ou de quantidade agendada para o próximo período, nulo sem ela. `prices.get` lê um preço pelo id, também um preço arquivado. `CheckoutClientItem` ganha `bands`, as faixas de um preço graduado em que a quantidade passou da primeira.

```csharp
var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams { ProductId = productId, PriceId = priceId, FirstPeriodExtraDays = 30 });

var subscription = await perata.Subscriptions.UpdateAsync(
    subscriptionId,
    new SubscriptionsUpdateParams { ExtendCurrentPeriodDays = 15 },
    new RequestOptions { IdempotencyKey = "credito-dias-1" });
// subscription.DiscountId, subscription.DiscountEndsAt, subscription.PendingUpdate (null sem troca agendada)

var order = await perata.Orders.GetAsync(orderId);
// order.SubtotalCents, order.DiscountCents, order.DiscountId, order.DiscountCode

var price = await perata.Prices.GetAsync(priceId);
```

## Repasses, saldo e renovação

**Saldo e repasses** (escopo `payouts:read`). `balance.get` devolve o que a organização tem a receber: `total_to_receive_cents`, que é sempre `released_cents` (liberado, o depósito está em processamento) mais `held_cents` (retido enquanto a conta está em análise) mais `scheduled_cents` (previsto, com data nos próximos 31 dias) mais `later_cents` (ainda sem data, como as parcelas mais distantes). `deposited_cents` é o que foi depositado no período de `period_from` a `period_to` (`date_from` e `date_to`, AAAA-MM-DD; sem eles, os 30 dias até hoje) e não entra no total. `payouts.list` lista os repasses, um por dia, com os filtros `status` (`scheduled`, `released`, `held` ou `deposited`), `date_from`, `date_to` e `sorting` (`date` ou `-date`, o padrão), e a iteração percorre todas as páginas; `payouts.get` lê um repasse (o id é como `po_20261120`) com os lançamentos em `items`: `kind`, `payment_id` (nulo numa tarifa), `installment`, `amount_cents`, `fee_cents` e `net_cents`. O `net_cents` de um repasse é `amount_cents` menos `fee_cents`. O `Payment` passa a trazer `fee_cents`, `net_cents`, `split` (cada destinatário, com `recipient_id`, `amount_cents`, `fee_cents` e `net_cents`), `expected_payout_on`, `payout_deposited_on` e `payout_id`. Os eventos `payout.scheduled`, `payout.released`, `payout.held` e `payout.deposited` trazem só os identificadores: leia o repasse com o `aggregate_id`.

**Renovação.** `renewal_mode` em `checkouts.create` diz como a assinatura renova: `manual` (a cada ciclo a Peráta abre uma cobrança para o comprador pagar, em `payment_url`, e o evento `subscription.renewal_due` avisa o seu sistema), `automatic` (só os meios que cobram sozinhos: o cartão de crédito guardado ou o Pix Automático) ou `buyer_choice` (o comprador decide numa caixa da página). `label` dá nome à assinatura e `notify_customer_email` em `false` mantém a Peráta sem escrever ao comprador a cada cobrança (o aviso passa a ser o seu). A `Subscription` e o `subscription.*` do webhook trazem o modo a que isso se resolveu em `renewal_mode` (`manual`, `card` ou `pix_automatic`), o `label` e o `notify_customer_email`. `subscriptions.update` troca `label`, `renewal_mode` (`manual`, ou `card` quando já há cartão guardado) e `notify_customer_email`, sozinhos, sem `price_id`. `subscriptions.get_open_charge` lê a cobrança de renovação que espera o comprador pagar (`amount_cents`, `due_at`, `expires_at`, `payment_url`); sem cobrança em aberto a API responde 404 `no_open_charge`. Os eventos `subscription.renewal_due` e `subscription.renewal_reminder` trazem a mesma cobrança, e o lembrete sai 3 dias antes do vencimento (`reminder` `before_due`, `days_until_due` 3) e no vencimento (`on_due`, 0): cada SDK os lê como `RenewalChargeWebhookEvent`, com o `WebhookRenewalCharge` em `data`.

```csharp
var balance = await perata.Balance.GetAsync(new BalanceGetParams { DateFrom = "2026-11-01", DateTo = "2026-11-20" });
// balance.TotalToReceiveCents, balance.ReleasedCents, balance.DepositedCents, balance.PeriodFrom

await foreach (var payout in perata.Payouts.ListIterAsync(new PayoutsListParams { Status = "deposited", DateFrom = "2026-11-01" }))
{
    // payout.Id, payout.Status, payout.ExpectedOn, payout.NetCents
}
var detail = await perata.Payouts.GetAsync("po_20261120");
// detail.Items[0].Kind, detail.Items[0].PaymentId

var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams
{
    ProductId = productId, PriceId = priceId, RenewalMode = CheckoutsCreateParams.RenewalModeAutomatic, NotifyCustomerEmail = false,
});

var charge = await perata.Subscriptions.GetOpenChargeAsync(subscriptionId);
// charge.PaymentUrl, charge.DueAt, charge.AmountCents; um 404 no_open_charge é uma PerataException com Code "no_open_charge"
```

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```csharp
var usage = new PerataClient(Environment.GetEnvironmentVariable("PERATA_USAGE_KEY")!); // pus_test_… ou pus_live_…

var receipt = await usage.Usage.IngestAsync(new UsageIngestParams
{
    Events =
    [
        new UsageIngestEvent
        {
            CustomerId = customerId,
            ExternalEventId = "requisicao-001", // a mesma fonte repetindo o id com o mesmo conteúdo é replay
            InputTokens = "1200",
            OutputTokens = "300",
            CachedTokens = "0",
            OccurredAt = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"), // segundos inteiros, até 90 dias atrás
        },
    ],
});
// receipt.Created, receipt.Replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `ExternalEventId` da fonte, e repetir uma chamada é seguro (`Replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `Record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API lança `PerataException`, com `Status`, `Code` (`invalid_request`, `not_found`…), `ApiMessage`, `Fields` (o problema de cada campo), `Record` (na ingestão, o evento recusado) e, num 429, `RetryAfter` em segundos. Uma falha de rede lança `HttpRequestException`; o tempo esgotado, `TimeoutException`.

## Webhooks

```csharp
var body = await new StreamReader(Request.Body).ReadToEndAsync();
var webhook = Webhook.Verify(Environment.GetEnvironmentVariable("PERATA_WEBHOOK_SECRET")!, Request.Headers, body);
switch (webhook)
{
    case OrderWebhookEvent { Type: "order.paid" } paid:
        Console.WriteLine($"{paid.Data.Id} {paid.Data.Installments}");
        break;
    case SubscriptionWebhookEvent { Type: "subscription.past_due" } pastDue: // uma cobrança de cartão foi recusada
        Console.WriteLine($"{pastDue.Data.Id} {pastDue.Data.PaymentFailure?.Attempt}");
        break;
    case SubscriptionWebhookEvent { Type: "subscription.suspended" } suspended: // as tentativas acabaram
        Console.WriteLine($"{suspended.Data.Id} {suspended.Data.SuspensionReason}");
        break;
    case UnknownWebhookEvent unknown:
        // um tipo que esta versão do SDK ainda não conhece: unknown.Data é o JSON
        break;
}
```

O `subscription.past_due` sai a cada cobrança de cartão recusada (`payment_failure` traz o número da tentativa e quando o cartão será cobrado de novo): mantenha o acesso do cliente até o `subscription.suspended`. Esse diz que as tentativas acabaram (`suspension_reason`): cancele a assinatura ou reative-a com `Subscriptions.ResumeAsync`.

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar; os cabeçalhos podem ser os do ASP.NET, de um `HttpHeaders` ou um dicionário. Uma assinatura inválida lança `WebhookVerificationException`.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `Webhook.VerifySignature` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `Environment`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real. O showcase da venda vem em `ShowcaseId` (vazio se um servidor antigo não mandou): um endpoint é de um showcase só, e o mesmo `showcase_id` está nos objetos do evento.

Versão do SDK: 0.5.9 · contrato da API: 0.1.0
