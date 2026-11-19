# Peráta SDK para Elixir

SDK oficial da API da Peráta para Elixir 1.18+, sem dependências: só `:httpc`, `:crypto` e o módulo `JSON`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```elixir
# mix.exs
{:perata_sdk, "~> 0.5.6"}
```

```elixir
client = Perata.new(System.fetch_env!("PERATA_API_KEY")) # prk_test_… ou prk_live_…

{:ok, product} = Perata.Products.create(client, %{name: "Curso"}, idempotency_key: "produto-curso")

client
|> Perata.Products.list_stream()
|> Enum.each(&IO.puts(&1.name))
```

## Recursos

| Módulo | Funções |
|---|---|
| `Perata.Benefits` | `create`, `delete`, `get`, `list`, `list_stream`, `list_grants`, `list_grants_stream`, `update` |
| `Perata.CheckoutLinks` | `create`, `delete`, `get`, `list`, `list_stream`, `update` |
| `Perata.Checkouts` | `create`, `expire`, `get`, `list`, `list_stream`, `update` |
| `Perata.CustomerSessions` | `create` |
| `Perata.Customers` | `create`, `delete`, `get`, `get_external`, `get_state`, `list`, `list_stream`, `update`, `update_external` |
| `Perata.Discounts` | `create`, `delete`, `get`, `list`, `list_stream`, `update` |
| `Perata.Disputes` | `get`, `list`, `list_stream` |
| `Perata.Events` | `list`, `list_stream` |
| `Perata.Meters` | `get`, `list`, `list_stream` |
| `Perata.Orders` | `get`, `get_invoice`, `get_receipt`, `list`, `list_stream` |
| `Perata.PaymentMethods` | `detach`, `list`, `list_stream` |
| `Perata.Payments` | `get`, `list`, `list_stream` |
| `Perata.Prices` | `create`, `list`, `list_stream` |
| `Perata.Products` | `archive`, `create`, `get`, `list`, `list_stream`, `update` |
| `Perata.Refunds` | `create`, `get`, `list`, `list_stream` |
| `Perata.ShowcaseService` | `get` |
| `Perata.Subscriptions` | `cancel`, `get`, `list`, `list_stream`, `resume`, `update` |
| `Perata.Usage` | `ingest` |
| `Perata.Webhooks` | `create_endpoint`, `delete_endpoint`, `get_endpoint`, `list_deliveries`, `list_deliveries_stream`, `list_endpoints`, `list_endpoints_stream`, `update_endpoint` |

Cada função recebe o cliente primeiro e devolve `{:ok, valor}` ou `{:error, %Perata.Error{}}`. Os modelos são structs com os nomes da API (`payment.amount_cents`). O corpo de uma escrita é a struct de parâmetros do método (`%Perata.ProductsCreateParams{name: "Curso"}`), uma keyword list ou um mapa com chaves atom; um campo opcional não informado fica fora do JSON. As funções `_stream` devolvem um `Stream` preguiçoso que percorre todas as páginas a partir de `page:` e levantam `Perata.Error` numa recusa.

As escritas aceitam `idempotency_key:`, e todas aceitam `api_key:` para usar a chave de outra organização numa chamada. `Perata.new/2` aceita `base_url:`, `timeout:` (30 segundos, em milissegundos) e `transport:`. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança. Uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e você pode repetir a escrita com a mesma chave, com o corpo corrigido ou como estava.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```elixir
# No seu servidor, numa ação como POST /checkout/sessao
{:ok, checkout} = Perata.Checkouts.create(client, %{product_id: product_id, price_id: price_id})

# Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
json(conn, %{clientSecret: checkout.client_secret, statusKey: checkout.status_key})
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

```elixir
{:ok, closed} = Perata.Checkouts.expire(client, checkout_id)
# closed.status == "expired"
```

Listar com filtros: `client_reference_id` acha o pedido que você registrou ao criar o checkout, e `metadata` casa os pares que você guardou (até 10 pares; a linha precisa ter todos). Os dois valem nas listas de checkouts, pedidos, pagamentos e assinaturas, e o filtro segue nas páginas de `list_stream`.

```elixir
filters = [client_reference_id: "pedido-123", metadata: %{"pedido" => "123", "camera id" => "a/b"}]
{:ok, page} = Perata.Orders.list(client, filters)

client
|> Perata.Orders.list_stream(filters)
|> Enum.each(&IO.puts(&1.id))
```

Reativar uma assinatura suspensa, que volta a ser cobrada, ou retomar uma pausada; qualquer outra assinatura responde 409:

```elixir
{:ok, subscription} = Perata.Subscriptions.resume(client, subscription_id)
```

## Reembolso, assinatura com data e showcase

Reembolsar o pedido, sem o `payment_id`: envie o `order_id` (o id que `orders.get` recebe). Sem `amount_cents` devolve tudo o que ainda pode ser devolvido; com ele, só essa parte, em centavos (de 1 até o que resta). O `metadata` do pedido de reembolso guarda pares seus, que voltam como `refund_metadata` no reembolso e nos eventos `refund.created` e `refund.updated`; `reason` e `note` dizem o motivo. O reembolso traz `order_id`, `client_reference_id` e o `metadata` do pedido, e `refunds.get` lê um pelo id. Um reembolso que falha emite `refund.failed`, com `failure_reason` (em português) e `failure_code` (o código da Cielo, para o suporte).

```elixir
{:ok, refund} = Perata.Refunds.create(client, %{order_id: order_id})
# refund.order_id, refund.status, refund.amount_cents

{:ok, part} = Perata.Refunds.create(client, %{order_id: order_id, amount_cents: 2500})
{:ok, found} = Perata.Refunds.get(client, refund.id)
```

Assinatura que começa numa data: `subscription_start_at` em `checkouts.create` é o dia da primeira cobrança, como o `trial_end` do Stripe. O cartão é guardado e conferido com o emissor, nada é cobrado hoje, e a cobrança acontece nesse dia (vale a meia-noite dele em São Paulo, qualquer que seja o fuso enviado). Só vale em um preço recorrente com valor, e só no cartão de crédito; tem de ser de amanhã a um ano, senão a resposta é 422. `items` e `discount_id` também valem num checkout de assinatura, e um pedido ou pagamento de assinatura traz `subscription_id`, `cycle_sequence`, `period_start` e `period_end`; as listas de pedidos e pagamentos aceitam o filtro `subscription_id`.

```elixir
{:ok, checkout} =
  Perata.Checkouts.create(client, %{
    product_id: product_id,
    price_id: price_id,
    subscription_start_at: "2026-12-15T00:00:00-03:00"
  })

# checkout.subscription_start_at: o instante da primeira cobrança
```

Showcase: toda chave de API é de um showcase, e todo objeto da API traz o `showcase_id` dele. `showcase.get` lê o showcase da chave: o `id`, o `name`, se é o principal da organização (`is_principal`), se tem logo (`has_logo`) e o `environment` (`test` ou `live`). Uma chave só alcança o que é do seu showcase, e um 403 diz qual escopo faltou.

```elixir
{:ok, showcase} = Perata.ShowcaseService.get(client)
# showcase.id, showcase.name, showcase.is_principal, showcase.has_logo, showcase.environment
```

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```elixir
usage = Perata.new(System.fetch_env!("PERATA_USAGE_KEY")) # pus_test_… ou pus_live_…

{:ok, receipt} =
  Perata.Usage.ingest(usage, %{
    events: [
      %Perata.UsageIngestEvent{
        customer_id: customer_id,
        external_event_id: "requisicao-001", # a mesma fonte repetindo o id com o mesmo conteúdo é replay
        input_tokens: "1200",
        output_tokens: "300",
        cached_tokens: "0",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601() # segundos inteiros, até 90 dias atrás
      }
    ]
  })

# receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `external_event_id` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API é um `{:error, %Perata.Error{}}`, com `status`, `code` (`invalid_request`, `not_found`…), `message`, `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retry_after` em segundos.

## Webhooks

```elixir
{:ok, event} = Perata.verify_webhook(System.fetch_env!("PERATA_WEBHOOK_SECRET"), conn.req_headers, raw_body)

case event do
  %Perata.OrderWebhookEvent{type: "order.paid", data: order} -> IO.inspect(order.installments)
  %Perata.DisputeWebhookEvent{data: dispute} -> IO.inspect(dispute.provider_dispute_id)
  %Perata.SubscriptionWebhookEvent{type: "subscription.past_due", data: subscription} -> IO.inspect(subscription.payment_failure)
  %Perata.SubscriptionWebhookEvent{type: "subscription.suspended", data: subscription} -> IO.inspect(subscription.suspension_reason)
  %Perata.UnknownWebhookEvent{} -> :ok
end
```

O `subscription.past_due` sai a cada cobrança de cartão recusada (`payment_failure` traz o número da tentativa e quando o cartão será cobrado de novo): mantenha o acesso do cliente até o `subscription.suspended`. Esse diz que as tentativas acabaram (`suspension_reason`): cancele a assinatura ou reative-a com `Perata.Subscriptions.resume/3`.

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar. Uma assinatura que não confere devolve `{:error, %Perata.WebhookVerificationError{}}`.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `Perata.verify_webhook_signature/4` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `event.environment`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real. O showcase da venda vem em `event.showcase_id` (vazio se um servidor antigo não mandou): um endpoint é de um showcase só, e o mesmo `showcase_id` está nos objetos do evento.

Versão do SDK: 0.5.6 · contrato da API: 0.1.0
