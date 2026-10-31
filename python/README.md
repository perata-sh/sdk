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
| `perata.checkouts` | `create`, `get`, `update` |
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
| `perata.webhooks` | `create_endpoint`, `delete_endpoint`, `get_endpoint`, `list_deliveries`, `list_deliveries_iter`, `list_endpoints`, `list_endpoints_iter`, `update_endpoint` |

As escritas aceitam `idempotency_key=`, e todas aceitam `api_key=` para usar a chave de outra organização numa chamada. Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Erros

Uma recusa da API levanta `PerataError`, com `status`, `code` (`invalid_request`, `not_found`…), `fields` (o problema de cada campo) e, num 429, `retry_after` em segundos.

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

Versão do SDK: 0.2.0 · contrato da API: 0.1.0
