# Peráta SDK para Python

SDK oficial da API da Peráta para Python 3.11+, sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
pip install perata-sdk
```

```python
import os
from perata import Perata

perata = Perata(os.environ["PERATA_API_KEY"])  # prk_test_… ou prk_live_…

product = perata.products.create({"name": "Curso"}, idempotency_key="produto-curso")

for product in perata.products.list_iter():
    print(product.name)
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

As escritas aceitam `idempotency_key=`, e todas aceitam `api_key=` para usar a chave de outra organização numa chamada. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança. Uma resposta 2xx fica guardada sob a chave; uma recusa 4xx ou uma falha 5xx a libera, e você pode repetir a escrita com a mesma chave, com o corpo corrigido ou como estava.

## Checkout transparente e embutido

O checkout embutido tem duas metades. O **servidor** cria a sessão com a chave de API e entrega ao navegador só o `client_secret`; o **navegador** monta os campos de pagamento com ele, sem chave de API. O cartão é digitado num quadro da Peráta e nunca passa pelo seu site nem pelo seu servidor.

```python
# No seu servidor, numa rota como POST /checkout/sessao
checkout = perata.checkouts.create({"product_id": product_id, "price_id": price_id})

# Só o client_secret e o status_key vão ao navegador, nunca a chave de API.
return {"clientSecret": checkout.client_secret, "statusKey": checkout.status_key}
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

```python
closed = perata.checkouts.expire(checkout_id)
# closed.status == "expired"
```

Listar com filtros: `client_reference_id` acha o pedido que você registrou ao criar o checkout, e `metadata` casa os pares que você guardou (até 10 pares; a linha precisa ter todos). Os dois valem nas listas de checkouts, pedidos, pagamentos e assinaturas, e o filtro segue nas páginas de `list_iter`.

```python
filters = {"client_reference_id": "pedido-123", "metadata": {"pedido": "123", "camera id": "a/b"}}
page = perata.orders.list(**filters)

for order in perata.orders.list_iter(**filters):
    print(order.id)
```

Reativar uma assinatura suspensa, que volta a ser cobrada, ou retomar uma pausada; qualquer outra assinatura responde 409:

```python
subscription = perata.subscriptions.resume(subscription_id)
```

## Reembolso, assinatura com data e showcase

Reembolsar o pedido, sem o `payment_id`: envie o `order_id` (o id que `orders.get` recebe). Sem `amount_cents` devolve tudo o que ainda pode ser devolvido; com ele, só essa parte, em centavos (de 1 até o que resta). O `metadata` do pedido de reembolso guarda pares seus, que voltam como `refund_metadata` no reembolso e nos eventos `refund.created` e `refund.updated`; `reason` e `note` dizem o motivo. O reembolso traz `order_id`, `client_reference_id` e o `metadata` do pedido, e `refunds.get` lê um pelo id. Um reembolso que falha emite `refund.failed`, com `failure_reason` (em português) e `failure_code` (o código da Cielo, para o suporte).

```python
refund = perata.refunds.create({"order_id": order_id})
# refund.order_id, refund.status, refund.amount_cents

part = perata.refunds.create({"order_id": order_id, "amount_cents": 2500})
found = perata.refunds.get(refund.id)
```

Assinatura que começa numa data: `subscription_start_at` em `checkouts.create` é o dia da primeira cobrança, como o `trial_end` do Stripe. O cartão é guardado e conferido com o emissor, nada é cobrado hoje, e a cobrança acontece nesse dia (vale a meia-noite dele em São Paulo, qualquer que seja o fuso enviado). Só vale em um preço recorrente com valor, e só no cartão de crédito; tem de ser de amanhã a um ano, senão a resposta é 422. `items` e `discount_id` também valem num checkout de assinatura, e um pedido ou pagamento de assinatura traz `subscription_id`, `cycle_sequence`, `period_start` e `period_end`; as listas de pedidos e pagamentos aceitam o filtro `subscription_id`.

```python
checkout = perata.checkouts.create({
    "product_id": product_id,
    "price_id": price_id,
    "subscription_start_at": "2026-12-15T00:00:00-03:00",
})
# checkout.subscription_start_at: o instante da primeira cobrança
```

Showcase: toda chave de API é de um showcase, e todo objeto da API traz o `showcase_id` dele. `showcase.get` lê o showcase da chave: o `id`, o `name`, se é o principal da organização (`is_principal`), se tem logo (`has_logo`) e o `environment` (`test` ou `live`). Uma chave só alcança o que é do seu showcase, e um 403 diz qual escopo faltou.

```python
showcase = perata.showcase.get()
# showcase.id, showcase.name, showcase.is_principal, showcase.has_logo, showcase.environment
```

## Consumo (ingestão de eventos)

A ingestão de consumo usa outra credencial: a de uma fonte de ingestão (**Configurações › Fontes de ingestão**), `pus_test_…` em teste e `pus_live_…` em produção. Monte um cliente com ela; a chave de API da organização (`prk_…`) é recusada aqui com 401, e uma credencial de um ambiente nunca escreve no outro.

```python
from datetime import datetime, timezone

usage = Perata(os.environ["PERATA_USAGE_KEY"])  # pus_test_… ou pus_live_…

receipt = usage.usage.ingest({"events": [{
    "customer_id": customer_id,
    "external_event_id": "requisicao-001",  # a mesma fonte repetindo o id com o mesmo conteúdo é replay
    "input_tokens": "1200",
    "output_tokens": "300",
    "cached_tokens": "0",
    "occurred_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),  # segundos inteiros, até 90 dias atrás
}]})
# receipt.created, receipt.replayed
```

De 1 a 100 eventos por chamada, até 64 KiB, todos gravados ou nenhum. Não há `Idempotency-Key` aqui: a identidade de um evento é o `external_event_id` da fonte, e repetir uma chamada é seguro (`replayed`); o mesmo id com outro conteúdo responde 409 (`conflict`), e um evento inválido, 422 (`invalid_request`) com `record` dizendo qual, a partir de 1.

## Erros

Uma recusa da API levanta `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `fields` (o problema de cada campo), `record` (na ingestão, o evento recusado) e, num 429, `retry_after` em segundos.

## Webhooks

```python
from perata import verify_webhook

event = verify_webhook(os.environ["PERATA_WEBHOOK_SECRET"], request.headers, request.get_data())
match event:
    case OrderWebhookEvent(type="order.paid", data=order):
        print(order.id, order.installments)
    case DisputeWebhookEvent(data=dispute):
        print(event.type, dispute.provider_dispute_id)
    case SubscriptionWebhookEvent(type="subscription.past_due", data=subscription):
        print(subscription.id, subscription.payment_failure)  # uma cobrança de cartão foi recusada
    case SubscriptionWebhookEvent(type="subscription.suspended", data=subscription):
        print(subscription.id, subscription.suspension_reason)  # as tentativas acabaram
    case UnknownWebhookEvent():
        pass  # um tipo que esta versão do SDK ainda não conhece: event.data é o JSON
```

O `subscription.past_due` sai a cada cobrança de cartão recusada (`payment_failure` traz o número da tentativa e quando o cartão será cobrado de novo): mantenha o acesso do cliente até o `subscription.suspended`. Esse diz que as tentativas acabaram (`suspension_reason`): cancele a assinatura ou reative-a com `subscriptions.resume`.

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `WebhookOrder`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `verify_webhook_signature` só confere a assinatura.

Todo evento traz o ambiente em que aconteceu, em `event.environment`: `"test"` ou `"live"` (vazio se um servidor antigo não mandou). Recuse o evento do ambiente errado: um endpoint de produção deve responder 400 a um evento `"test"`, para que um teste não dê baixa em um pedido real. O showcase da venda vem em `event.showcase_id` (vazio se um servidor antigo não mandou): um endpoint é de um showcase só, e o mesmo `showcase_id` está nos objetos do evento.

Versão do SDK: 0.5.6 · contrato da API: 0.1.0
