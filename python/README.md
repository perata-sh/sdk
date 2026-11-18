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
| `perata.refunds` | `create`, `list`, `list_iter` |
| `perata.subscriptions` | `cancel`, `get`, `list`, `list_iter`, `update` |
| `perata.usage` | `ingest` |
| `perata.webhooks` | `create_endpoint`, `delete_endpoint`, `get_endpoint`, `list_deliveries`, `list_deliveries_iter`, `list_endpoints`, `list_endpoints_iter`, `update_endpoint` |

As escritas aceitam `idempotency_key=`, e todas aceitam `api_key=` para usar a chave de outra organização numa chamada. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

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
    case UnknownWebhookEvent():
        pass  # um tipo que esta versão do SDK ainda não conhece: event.data é o JSON
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `Order`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `verify_webhook_signature` só confere a assinatura.

Versão do SDK: 0.5.2 · contrato da API: 0.1.0
