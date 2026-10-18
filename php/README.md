# Peráta SDK para PHP

SDK oficial da API da Peráta para PHP 8.1+, só com as extensões `curl` e `json`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [perata-sh/sdk](https://github.com/perata-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
composer require perata-sh/sdk
```

```php
$perata = new Perata\Perata(getenv('PERATA_API_KEY')); // prk_test_… ou prk_live_…

$product = $perata->products->create(['name' => 'Curso'], idempotencyKey: 'produto-curso');

foreach ($perata->products->listIter() as $product) {
    echo $product->name, PHP_EOL;
}
```

## Recursos

| Serviço | Métodos |
|---|---|
| `$perata->checkouts` | `create` |
| `$perata->customers` | `create`, `get`, `list`, `listIter` |
| `$perata->orders` | `list`, `listIter` |
| `$perata->paymentMethods` | `detach`, `list`, `listIter` |
| `$perata->payments` | `get`, `list`, `listIter` |
| `$perata->prices` | `create`, `list`, `listIter` |
| `$perata->products` | `create`, `get`, `list`, `listIter` |
| `$perata->refunds` | `create` |
| `$perata->subscriptions` | `cancel`, `get`, `list`, `listIter` |

Os modelos são classes com propriedades `readonly` em camelCase (`$payment->amountCents`); os corpos das escritas são arrays com os nomes da API (`['product_id' => …]`), descritos para o PHPStan.

## Erros

Uma recusa da API lança `Perata\PerataException`, com `status`, `errorCode` (`invalid_request`, `not_found`…), `fields` (o problema de cada campo) e, num 429, `retryAfter` em segundos.

## Webhooks

```php
$event = Perata\Webhook::verify(getenv('PERATA_WEBHOOK_SECRET'), getallheaders(), file_get_contents('php://input'));
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Passe o corpo cru, antes de interpretar.

Versão do SDK: 0.1.1 · contrato da API: 0.1.0
