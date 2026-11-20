# Peráta SDK para Ruby

SDK oficial da API da Peráta para Ruby 3.1+, sem dependências: só `net/http`, `json` e `openssl`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
gem install perata-sdk
```

```ruby
require "perata"

perata = Perata::Client.new(ENV.fetch("PERATA_API_KEY")) # prk_test_… ou prk_live_…

product = perata.products.create({ name: "Curso" }, idempotency_key: "produto-curso")

perata.products.list_iter.each do |product|
  puts product.name
end
```

## Recursos

| Serviço | Métodos |
|---|---|
| `perata.benefits` | `create`, `delete`, `get`, `list`, `list_iter`, `list_grants`, `list_grants_iter`, `update` |
| `perata.checkout_links` | `create`, `delete`, `get`, `list`, `list_iter`, `update` |
| `perata.checkouts` | `create`, `expire`, `get`, `list`, `list_iter`, `update` |
| `perata.customer_sessions` | `create` |
| `perata.customers` | `create`, `delete`, `get`, `get_external`, `get_state`, `list`, `list_iter`, `update`, `update_external` |
| `perata.discounts` | `create`, `delete`, `get`, `list`, `list_iter`, `update` |
| `perata.disputes` | `get`, `list`, `list_iter` |
| `perata.events` | `list`, `list_iter` |
| `perata.meters` | `get`, `list`, `list_iter` |
| `perata.orders` | `get`, `get_invoice`, `get_receipt`, `list`, `list_iter` |
| `perata.payment_methods` | `detach`, `list`, `list_iter` |
| `perata.payments` | `get`, `list`, `list_iter` |
| `perata.prices` | `create`, `list`, `list_iter` |
| `perata.products` | `archive`, `create`, `get`, `list`, `list_iter`, `update` |
| `perata.refunds` | `create`, `get`, `list`, `list_iter` |
| `perata.showcase` | `get` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `list_iter`, `resume`, `update` |
| `perata.usage` | `ingest` |
| `perata.webhooks` | `create_endpoint`, `delete_endpoint`, `get_endpoint`, `list_deliveries`, `list_deliveries_iter`, `list_endpoints`, `list_endpoints_iter`, `update_endpoint` |

Os modelos são objetos imutáveis com leitores em snake_case (`payment.amount_cents`). O corpo de uma escrita é a classe de parâmetros do método (`Perata::ProductsCreateParams.new(name: "Curso")`) ou um `Hash` com os mesmos nomes; um campo opcional não informado fica fora do JSON. Os métodos `_iter` devolvem um `Enumerator` que percorre todas as páginas a partir de `page:` (ou recebem um bloco).

As escritas aceitam `idempotency_key:`, e todas aceitam `api_key:` para usar a chave de outra organização numa chamada. `Perata::Client.new` aceita `base_url:`, `timeout:` (30 segundos) e `transport:`. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança. Uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e você pode repetir a escrita com a mesma chave, com o corpo corrigido ou como estava.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```ruby
# No seu servidor, numa rota como POST /checkout/sessao
checkout = perata.checkouts.create({ product_id: product_id, price_id: price_id })

# Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
{ clientSecret: checkout.client_secret, statusKey: checkout.status_key }.to_json
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

```ruby
closed = perata.checkouts.expire(checkout_id)
# closed.status == "expired"
```

Listar com filtros: `client_reference_id` acha o pedido que você registrou ao criar o checkout, e `metadata` casa os pares que você guardou (até 10 pares; a linha precisa ter todos). Os dois valem nas listas de checkouts, pedidos, pagamentos e assinaturas, e o filtro segue nas páginas de `list_iter`.

```ruby
filters = { client_reference_id: "pedido-123", metadata: { "pedido" => "123", "camera id" => "a/b" } }
page = perata.orders.list(**filters)

perata.orders.list_iter(**filters).each do |order|
  puts order.id
end
```

Reativar uma assinatura suspensa, que volta a ser cobrada, ou retomar uma pausada; qualquer outra assinatura responde 409:

```ruby
subscription = perata.subscriptions.resume(subscription_id)
```

## Reembolso, assinatura com data e showcase

Reembolsar o pedido, sem o `payment_id`: envie o `order_id` (o id que `orders.get` recebe). Sem `amount_cents` devolve tudo o que ainda pode ser devolvido; com ele, só essa parte, em centavos (de 1 até o que resta). O `metadata` do pedido de reembolso guarda pares seus, que voltam como `refund_metadata` no reembolso e nos eventos `refund.created` e `refund.updated`; `reason` e `note` dizem o motivo. O reembolso traz `order_id`, `client_reference_id` e o `metadata` do pedido, e `refunds.get` lê um pelo id. Um reembolso que falha emite `refund.failed`, com `failure_reason` (em português) e `failure_code` (o código da Cielo, para o suporte).

```ruby
refund = perata.refunds.create({ order_id: order_id })
# refund.order_id, refund.status, refund.amount_cents

part = perata.refunds.create({ order_id: order_id, amount_cents: 2500 })
found = perata.refunds.get(refund.id)
```

Assinatura que começa numa data: `subscription_start_at` em `checkouts.create` é o dia da primeira cobrança, como o `trial_end` do Stripe. O cartão é guardado e conferido com o emissor, nada é cobrado hoje, e a cobrança acontece nesse dia (vale a meia-noite dele em São Paulo, qualquer que seja o fuso enviado). Só vale em um preço recorrente com valor, e só no cartão de crédito; tem de ser de amanhã a um ano, senão a resposta é 422. `items` e `discount_id` também valem num checkout de assinatura, e um pedido ou pagamento de assinatura traz `subscription_id`, `cycle_sequence`, `period_start` e `period_end`; as listas de pedidos e pagamentos aceitam o filtro `subscription_id`.

```ruby
checkout = perata.checkouts.create({
  product_id: product_id,
  price_id: price_id,
  subscription_start_at: "2026-12-15T00:00:00-03:00",
})
# checkout.subscription_start_at: o instante da primeira cobrança
```

Showcase: toda chave de API é de um showcase, e todo objeto da API traz o `showcase_id` dele. `showcase.get` lê o showcase da chave: o `id`, o `name`, se é o principal da organização (`is_principal`), se tem logo (`has_logo`) e o `environment` (`test` ou `live`). Uma chave só alcança o que é do seu showcase, e um 403 diz qual escopo faltou.

```ruby
showcase = perata.showcase.get
# showcase.id, showcase.name, showcase.is_principal, showcase.has_logo, showcase.environment
```

## Preço por quantidade e assinatura com quantidade

`pricing_model` em `prices.create` diz como o valor é calculado: `fixed` (o padrão, com `amount_cents`), `per_unit` e `seat` (`unit_amount_cents` por unidade ou por assento), `volume` (a quantidade inteira pelo valor da faixa em que ela cai) e `graduated` (cada faixa pelo seu valor). `volume` e `graduated` pedem `tiers`, de 1 a 50, em ordem: `up_to` é até quantas unidades a faixa vai, inclusive, e a última faixa não leva `up_to` (sem limite). Com a 1ª unidade a R$ 250,00 e as seguintes a R$ 150,00, três unidades custam 250 + 150 + 150 = R$ 550,00. `unit_label` e `unit_label_plural` dão nome à unidade (câmera, câmeras), `minimum_units` e `maximum_units` limitam a compra, e `interval` aceita também `day` e `week`. Fora do preço fixo não se envia `amount_cents`: a API recusa com 422. **Mudança de tipo nas linguagens tipadas: `amount_cents` deixa de ser obrigatório em `PricesCreateParams`.** O preço devolvido traz `pricing_model`, `tiers`, `unit_amount_cents` e `amount_cents` 0 nos modelos por quantidade.

O checkout recebe a `quantity` e cobra pelo modelo do preço. A assinatura que nasce dele traz `quantity` e `client_reference_id` (a `Subscription` e o `subscription.*` do webhook), e o `amount_cents` dela é o **total do ciclo para essa quantity**, não o preço de uma unidade. Cada pedido de renovação volta com o mesmo `client_reference_id` e o mesmo `metadata`. O recibo do pedido traz `charged_by`, a frase "Cobrança feita por <empresa>". Um 401 e as rotas `/checkouts/client/...` respondem no mesmo formato `{error, message, fields}` dos demais erros.

```ruby
price = perata.prices.create({
  product_id: product_id,
  type: "recurring",
  interval: "month",
  pricing_model: "graduated",
  tiers: [
    { up_to: 1, unit_amount_cents: 25_000 }, # a 1ª unidade a R$ 250,00
    { up_to: nil, unit_amount_cents: 15_000 } # as seguintes a R$ 150,00
  ]
})

checkout = perata.checkouts.create({ product_id: product_id, price_id: price.id, quantity: 3 })

subscription = perata.subscriptions.get(subscription_id)
# subscription.quantity (3), subscription.amount_cents (55000: o total do ciclo), subscription.client_reference_id
```

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```ruby
usage = Perata::Client.new(ENV.fetch("PERATA_USAGE_KEY")) # pus_test_… ou pus_live_…

receipt = usage.usage.ingest({ events: [{
  customer_id: customer_id,
  external_event_id: "requisicao-001", # a mesma fonte repetindo o id com o mesmo conteúdo é replay
  input_tokens: "1200",
  output_tokens: "300",
  cached_tokens: "0",
  occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") # segundos inteiros, até 90 dias atrás
}] })
# receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `external_event_id` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API levanta `Perata::Error`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retry_after` em segundos.

## Webhooks

```ruby
event = Perata.verify_webhook(ENV.fetch("PERATA_WEBHOOK_SECRET"), request.headers, request.raw_post)
case event
when Perata::OrderWebhookEvent then puts event.type, event.data.id, event.data.installments
when Perata::DisputeWebhookEvent then puts event.data.provider_dispute_id
when Perata::SubscriptionWebhookEvent
  case event.type
  when "subscription.past_due" then puts event.data.id, event.data.payment_failure&.attempt # uma cobrança de cartão foi recusada
  when "subscription.suspended" then puts event.data.id, event.data.suspension_reason # as tentativas acabaram
  end
when Perata::UnknownWebhookEvent then nil # um tipo que esta versão ainda não conhece: event.data é o JSON
end
```

O `subscription.past_due` sai a cada cobrança de cartão recusada (`payment_failure` traz o número da tentativa e quando o cartão será cobrado de novo): mantenha o acesso do cliente até o `subscription.suspended`. Esse diz que as tentativas acabaram (`suspension_reason`): cancele a assinatura ou reative-a com `subscriptions.resume`.

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar; os cabeçalhos podem vir num `Hash` ou no env do Rack. Uma assinatura que não confere levanta `Perata::WebhookVerificationError`.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `Perata.verify_webhook_signature` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `event.environment`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real. O showcase da venda vem em `event.showcase_id` (vazio se um servidor antigo não mandou): um endpoint é de um showcase só, e o mesmo `showcase_id` está nos objetos do evento.

Versão do SDK: 0.5.7 · contrato da API: 0.1.0
