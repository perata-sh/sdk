<?php

// Peráta's PHP SDK tests, with no dependency to install: php tests/run.php

declare(strict_types=1);

use Perata\IdentifiersWebhookEvent;
use Perata\OrderWebhookEvent;
use Perata\Perata;
use Perata\PerataException;
use Perata\RenewalChargeWebhookEvent;
use Perata\UnknownWebhookEvent;
use Perata\Webhook;
use Perata\WebhookVerificationException;

spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'Perata\\')) {
        require __DIR__ . '/../src/' . str_replace('\\', '/', substr($class, 7)) . '.php';
    }
});

$tests = [];
$failures = 0;

function check(bool $condition, string $what): void
{
    if (!$condition) {
        throw new \RuntimeException($what);
    }
}

/**
 * @param callable(array{method: string, url: string, headers: array<string, string>, body: ?string}): array{0: int, 1: array<string, string>, 2: mixed} $answer
 * @return array{0: Perata, 1: \ArrayObject<int, array{method: string, url: string, headers: array<string, string>, body: ?string}>}
 */
function client(callable $answer): array
{
    $seen = new \ArrayObject();
    $transport = static function (string $method, string $url, array $headers, ?string $body, float $timeout) use ($answer, $seen): array {
        $request = ['method' => $method, 'url' => $url, 'headers' => $headers, 'body' => $body];
        $seen[] = $request;
        [$status, $extra, $payload] = $answer($request);
        return [$status, $extra, $payload === null ? '' : json_encode($payload)];
    };
    return [new Perata('prk_test_key', 'https://perata.test/', transport: $transport), $seen];
}

function product(string $id): array
{
    return ['id' => $id, 'name' => 'Curso', 'description' => '', 'status' => 'active', 'showcase_id' => 'shw_1', 'created_at' => '2026-10-17T00:00:00Z'];
}

$tests['a call carries the key and unwraps the data'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [200, [], ['data' => product('prod_1')]]);
    $got = $perata->products->get('prod_1');
    check($got->id === 'prod_1' && $got->status === 'active' && $got->createdAt === '2026-10-17T00:00:00Z', 'product');
    check($seen[0]['method'] === 'GET' && $seen[0]['url'] === 'https://perata.test/api/v1/products/prod_1', 'request ' . $seen[0]['url']);
    check($seen[0]['headers']['Authorization'] === 'Bearer prk_test_key', 'key');
};

$tests['a write sends its body and idempotency key'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [201, [], ['data' => product('prod_1')]]);
    $perata->products->create(['name' => 'Curso'], idempotencyKey: 'create-1');
    check($seen[0]['method'] === 'POST' && $seen[0]['headers']['Idempotency-Key'] === 'create-1', 'request');
    check(json_decode((string) $seen[0]['body'], true) === ['name' => 'Curso'], 'body ' . $seen[0]['body']);
};

$tests['a checkout session hands back the client secret for the browser'] = static function (): void {
    $session = static fn (string $secret): array => [
        'id' => 'pcl_1', 'url' => 'https://perata.sh/pagamento/pcl_1', 'product_id' => 'prod_1', 'price_id' => 'price_1',
        'status' => 'active', 'label' => '', 'notify_customer_email' => true, 'renewal_mode' => '', 'quantity' => 1, 'success_url' => 'https://loja.example/obrigado', 'cancel_url' => '',
        'expires_at' => null, 'created_at' => '2026-11-16T12:00:00Z', 'session_id' => 'cs_1', 'client_secret' => $secret,
        'max_installments' => 0, 'installment_interest' => null, 'interest_free_installments' => 0, 'installment_monthly_rate_bp' => 0, 'min_installment_cents' => 0, 'pix_discount_bp' => null, 'boleto_discount_bp' => null, 'coupon_stacks_with_method_discount' => null, 'client_secret_expires_at' => '2026-11-16T12:30:00Z', 'status_key' => 'sk_1',
        'amount_cents' => null, 'items' => [], 'metadata' => [], 'client_reference_id' => '',
        'discount_id' => '', 'showcase_id' => 'shw_1', 'subscription_start_at' => null,
    ];
    $calls = 0;
    [$perata, $seen] = client(static function () use ($session, &$calls): array {
        return $calls++ === 0 ? [201, [], ['data' => $session('cs_secret_1')]] : [201, ['Idempotent-Replayed' => 'true'], ['data' => $session('')]];
    });
    $params = ['product_id' => 'prod_1', 'price_id' => 'price_1', 'success_url' => 'https://loja.example/obrigado'];
    $checkout = $perata->checkouts->create($params, idempotencyKey: 'pedido-1');
    check($checkout->clientSecret === 'cs_secret_1' && $checkout->sessionId === 'cs_1' && $checkout->statusKey === 'sk_1', 'secret and keys');
    check($checkout->clientSecretExpiresAt === '2026-11-16T12:30:00Z' && $checkout->url === 'https://perata.sh/pagamento/pcl_1' && $checkout->expiresAt === null, 'dates and url');
    check($seen[0]['method'] === 'POST' && $seen[0]['url'] === 'https://perata.test/api/v1/checkouts' && $seen[0]['headers']['Idempotency-Key'] === 'pedido-1', 'request');
    check(json_decode((string) $seen[0]['body'], true) === $params, 'body ' . $seen[0]['body']);
    $again = $perata->checkouts->create($params, idempotencyKey: 'pedido-1');
    check($again->clientSecret === '' && $again->sessionId === 'cs_1' && $again->statusKey === 'sk_1', 'replay');
};

$tests['a model that may be null decodes both ways'] = static function (): void {
    $pix = ['copia_e_cola' => '000201', 'qr_code_svg' => '<svg/>', 'expires_at' => null];
    $payment = ['id' => 'pay_1', 'method' => 'pix', 'state' => 'pending', 'unresolved' => false, 'card_brand' => '', 'card_kind' => '', 'installments' => 1, 'pix' => $pix, 'boleto' => null];
    $got = \Perata\Models\CheckoutClientPayment::fromArray($payment);
    check($got->boleto === null && $got->pix !== null && $got->pix->copiaECola === '000201' && $got->pix->expiresAt === null, 'payment');
};

$tests['a base URL must be https unless it is loopback'] = static function (): void {
    foreach (['https://perata.sh', 'http://localhost:8080', 'http://LOCALHOST', 'http://127.0.0.1:1', 'http://127.255.0.3', 'http://[::1]:8080'] as $base) {
        new Perata('k', $base);
    }
    foreach (['http://perata.sh', 'http://localhost.evil.test', 'http://127.0.0.1.evil.test', 'http://10.0.0.1', 'ftp://localhost', 'perata.sh', '', 'http://[::2]'] as $base) {
        try {
            new Perata('k', $base);
            check(false, "accepted {$base}");
        } catch (InvalidArgumentException $refused) {
            check(str_contains($refused->getMessage(), 'must be https'), 'message');
        }
    }
};

$tests['a discount goes through create, get, list and delete'] = static function (): void {
    $discount = static fn (string $id): mixed => json_decode(str_replace('__ID__', $id, '{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}'), true);
    [$perata, $seen] = client(static function (array $request) use ($discount): array {
        if ($request['method'] === 'POST') {
            return [201, [], ['data' => $discount('disc_1')]];
        }
        if ($request['method'] === 'DELETE') {
            return [204, [], null];
        }
        if (str_ends_with((string) parse_url($request['url'], PHP_URL_PATH), '/api/v1/discounts')) {
            parse_str((string) parse_url($request['url'], PHP_URL_QUERY), $query);
            return [200, [], ['data' => ['items' => [$discount('disc_' . $query['page'])], 'pagination' => ['total_count' => 2, 'max_page' => 2]]]];
        }
        return [200, [], ['data' => $discount('disc_1')]];
    });
    $created = $perata->discounts->create(['name' => 'Black', 'type' => 'percentage', 'duration' => 'once', 'basis_points' => 1000]);
    check($created->id === 'disc_1' && $created->code === null && $created->productIds === ['prod_1'], 'created');
    check($perata->discounts->get('disc_1')->name === 'Black', 'get');
    $ids = [];
    foreach ($perata->discounts->listIter(['limit' => 1]) as $each) {
        $ids[] = $each->id;
    }
    check($ids === ['disc_1', 'disc_2'], 'walked ' . implode(',', $ids));
    $perata->discounts->delete('disc_1');
    $requests = array_map(static fn (array $each): string => $each['method'] . ' ' . parse_url($each['url'], PHP_URL_PATH), $seen->getArrayCopy());
    check($requests === ['POST /api/v1/discounts', 'GET /api/v1/discounts/disc_1', 'GET /api/v1/discounts', 'GET /api/v1/discounts', 'DELETE /api/v1/discounts/disc_1'], implode(' | ', $requests));
    check(json_decode((string) $seen[0]['body'], true) === ['name' => 'Black', 'type' => 'percentage', 'duration' => 'once', 'basis_points' => 1000], 'body');
};

$tests['a free-form value decodes nested'] = static function (): void {
    $state = json_decode('{"id":"cus_1","showcase_id":"shw_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}', true);
    [$perata] = client(static fn (): array => [200, [], ['data' => $state]]);
    $grant = $perata->customers->getState('cus_1')->grantedBenefits[0];
    check($grant->benefitMetadata === ['flags' => ['beta' => true, 'limits' => ['seats' => 5, 'tiers' => ['a', 2, null, 1.5]]]], 'metadata ' . json_encode($grant->benefitMetadata));
    check($grant->properties === ['links' => [['url' => 'https://example.com', 'expires' => null]]], 'properties ' . json_encode($grant->properties));
};

$tests['a POST without a key is sent with its own, a GET with none'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [201, [], ['data' => product('prod_1')]]);
    $perata->products->create(['name' => 'Curso']);
    $perata->products->create(['name' => 'Curso']);
    $perata->products->create(['name' => 'Curso'], idempotencyKey: 'mine');
    $perata->products->get('prod_1');
    $keys = array_map(static fn (array $each): ?string => $each['headers']['Idempotency-Key'] ?? null, $seen->getArrayCopy());
    $uuid = '/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/';
    check(preg_match($uuid, (string) $keys[0]) === 1 && preg_match($uuid, (string) $keys[1]) === 1, 'a UUID v4: ' . json_encode($keys));
    check($keys[0] !== $keys[1] && $keys[2] === 'mine' && $keys[3] === null, 'keys ' . json_encode($keys));
};

$tests['iterating walks every page'] = static function (): void {
    [$perata, $seen] = client(static function (array $request): array {
        parse_str((string) parse_url($request['url'], PHP_URL_QUERY), $query);
        return [200, [], ['data' => ['items' => [product('prod_' . $query['page'])], 'pagination' => ['total_count' => 3, 'max_page' => 3]]]];
    });
    $ids = [];
    foreach ($perata->products->listIter(['limit' => 1]) as $item) {
        $ids[] = $item->id;
    }
    check($ids === ['prod_1', 'prod_2', 'prod_3'], 'walked ' . implode(',', $ids));
    check(str_contains($seen[0]['url'], 'limit=1'), 'limit');
};

$tests['a metadata filter is sent as one pair a key, the keys sorted and escaped'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [200, [], ['data' => ['items' => [], 'pagination' => ['total_count' => 0, 'max_page' => 1]]]]);
    $metadata = ['pedido' => '123', 'camera id' => 'a/b'];
    $perata->orders->list(['client_reference_id' => 'pedido-1', 'metadata' => $metadata]);
    $want = 'https://perata.test/api/v1/orders?client_reference_id=pedido-1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123';
    check($seen[0]['url'] === $want, 'query ' . $seen[0]['url']);
    parse_str((string) parse_url($seen[0]['url'], PHP_URL_QUERY), $read);
    check(($read['metadata'] ?? null) === ['camera id' => 'a/b', 'pedido' => '123'], 'the server reads ' . json_encode($read));
    foreach ($perata->checkouts->listIter(['limit' => 1, 'metadata' => $metadata]) as $ignored) {
        throw new \RuntimeException('an empty page has no items');
    }
    check($seen[1]['url'] === 'https://perata.test/api/v1/checkouts?page=1&limit=1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123', 'walk ' . $seen[1]['url']);
};

$tests['customers are listed by e-mail'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [200, [], ['data' => ['items' => [], 'pagination' => ['total_count' => 0, 'max_page' => 1]]]]);
    $perata->customers->list(['email' => 'ana@example.com']);
    check($seen[0]['url'] === 'https://perata.test/api/v1/customers?email=ana%40example.com', 'query ' . $seen[0]['url']);
};

// A graduated price goes out with its tiers and without the fixed amount, and a
// subscription reads back the quantity it bills and the order reference it came
// from; amount_cents is the cycle's total for that quantity.
$tests['a graduated price carries its tiers and a subscription its quantity'] = static function (): void {
    $tiers = [['up_to' => 1, 'unit_amount_cents' => 25000], ['up_to' => null, 'unit_amount_cents' => 15000]];
    $price = ['id' => 'price_1', 'product_id' => 'prod_1', 'type' => 'recurring', 'interval' => 'month', 'interval_count' => 1, 'currency' => 'BRL', 'status' => 'active', 'amount_cents' => 0, 'pricing_model' => 'graduated', 'unit_amount_cents' => null, 'unit_label' => 'câmera', 'unit_label_plural' => 'câmeras', 'tiers' => $tiers];
    $subscription = ['id' => 'sub_1', 'label' => '', 'notify_customer_email' => true, 'renewal_mode' => 'manual', 'amount_cents' => 55000, 'cancel_at_period_end' => false, 'client_reference_id' => 'pedido-9', 'currency' => 'BRL', 'current_period_end' => '2026-12-20T00:00:00Z', 'current_period_start' => '2026-11-20T00:00:00Z', 'customer_id' => 'cus_1', 'interval' => 'month', 'metadata' => ['camera' => 'c1'], 'price_id' => 'price_1', 'product_id' => 'prod_1', 'quantity' => 3, 'showcase_id' => 'shw_1', 'status' => 'active', 'suspended_at' => null, 'suspension_reason' => null, 'trial_end' => null, 'trial_start' => null];
    [$perata, $seen] = client(static fn (array $request): array => $request['method'] === 'POST' ? [201, [], ['data' => $price]] : [200, [], ['data' => $subscription]]);
    $created = $perata->prices->create(['product_id' => 'prod_1', 'type' => 'recurring', 'interval' => 'month', 'pricing_model' => 'graduated', 'tiers' => $tiers, 'unit_label' => 'câmera', 'unit_label_plural' => 'câmeras']);
    check($seen[0]['url'] === 'https://perata.test/api/v1/prices', 'path ' . $seen[0]['url']);
    $sent = json_decode((string) $seen[0]['body'], true);
    check($sent['pricing_model'] === 'graduated' && $sent['tiers'] === $tiers && !array_key_exists('amount_cents', $sent), 'body ' . $seen[0]['body']);
    check($created->pricingModel === 'graduated' && $created->amountCents === 0 && $created->unitAmountCents === null, 'price');
    check(count($created->tiers) === 2 && $created->tiers[0]->upTo === 1 && $created->tiers[1]->upTo === null && $created->tiers[1]->unitAmountCents === 15000, 'tiers');
    $got = $perata->subscriptions->get('sub_1');
    check($seen[1]['url'] === 'https://perata.test/api/v1/subscriptions/sub_1', 'path ' . $seen[1]['url']);
    check($got->quantity === 3 && $got->amountCents === 55000 && $got->clientReferenceId === 'pedido-9', 'subscription');
};

// A checkout adds the buyer's remaining days to the first period, an extension
// goes out alone (no price_id), and the sale reads back what it took: the
// discount on the order and on the subscription, the change scheduled for the
// next period.
$tests['a first period extension and the discounts the sale reads back'] = static function (): void {
    $answers = [
        'POST /api/v1/checkouts' => [201, '{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"x","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"disc_1","first_period_extra_days":30,"renewal_mode":"manual","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}'],
        'PATCH /api/v1/subscriptions/sub_1' => [200, '{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":{"price_id":"price_2","quantity":5,"amount_cents":90000,"effective_at":"2026-12-20T03:00:00Z"},"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":"disc_1","discount_ends_at":"2027-03-01T03:00:00Z","first_period_extra_days":30,"renewal_mode":"manual","label":"x","notify_customer_email":false}}'],
        'GET /api/v1/subscriptions/sub_2' => [200, '{"data":{"id":"sub_2","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"manual","label":"x","notify_customer_email":false}}'],
        'GET /api/v1/orders/ord_1' => [200, '{"data":{"id":"ord_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","amount_cents":9000,"currency":"BRL","status":"open","paid_at":null,"order_status":null,"refunded_amount_cents":0,"installments":0,"installment_interest_cents":0,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"x","subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"discount_id":"disc_1","discount_code":"BEMVINDO","subtotal_cents":10000,"discount_cents":1000}}'],
        'GET /api/v1/prices/price_1' => [200, '{"data":{"id":"price_1","product_id":"prod_1","currency":"BRL","amount_cents":9000,"type":"one_time","interval":"none","interval_count":0,"pricing_model":"fixed","unit_amount_cents":null,"tiers":[],"unit_label":"x","unit_label_plural":"x","minimum_units":null,"maximum_units":null,"status":"archived"}}'],
    ];
    [$perata, $seen] = client(static function (array $request) use ($answers): array {
        [$status, $body] = $answers[$request['method'] . ' ' . parse_url($request['url'], PHP_URL_PATH)];
        return [$status, [], json_decode($body, true)];
    });
    $checkout = $perata->checkouts->create(['product_id' => 'prod_1', 'price_id' => 'price_1', 'first_period_extra_days' => 30]);
    check(json_decode((string) $seen[0]['body'], true)['first_period_extra_days'] === 30, 'checkout body ' . $seen[0]['body']);
    check($checkout->firstPeriodExtraDays === 30 && $checkout->discountId === 'disc_1', 'checkout');
    $subscription = $perata->subscriptions->update('sub_1', ['extend_current_period_days' => 15]);
    $sent = json_decode((string) $seen[1]['body'], true);
    check($seen[1]['method'] === 'PATCH' && $sent['extend_current_period_days'] === 15 && !array_key_exists('price_id', $sent), 'update body ' . $seen[1]['body']);
    check($subscription->firstPeriodExtraDays === 30 && $subscription->discountId === 'disc_1' && $subscription->discountEndsAt === '2027-03-01T03:00:00Z', 'subscription');
    $pending = $subscription->pendingUpdate;
    check($pending !== null && $pending->priceId === 'price_2' && $pending->quantity === 5 && $pending->amountCents === 90000 && $pending->effectiveAt === '2026-12-20T03:00:00Z', 'pending update');
    $none = $perata->subscriptions->get('sub_2');
    check($none->pendingUpdate === null && $none->firstPeriodExtraDays === null && $none->discountId === null, 'subscription without any');
    $order = $perata->orders->get('ord_1');
    check($order->subtotalCents === 10000 && $order->discountCents === 1000 && $order->discountId === 'disc_1' && $order->discountCode === 'BEMVINDO', 'order');
    $price = $perata->prices->get('price_1');
    check($seen[4]['url'] === 'https://perata.test/api/v1/prices/price_1' && $price->status === 'archived', 'price');
};

// The payment reads back its fee, its net, its split and the payout that pays it.
$tests['a payment reads back its fee, its split and its payout'] = static function (): void {
    [$perata] = client(static fn (): array => [200, [], json_decode('{"data":{"id":"pay_1","showcase_id":"x","checkout_id":"x","customer_id":"x","method":"card","state":"unknown","amount_cents":0,"captured_cents":0,"refunded_cents":0,"currency":"BRL","created_at":"2026-11-20T12:00:00Z","metadata":{},"client_reference_id":"x","installments":0,"installment_amount_cents":0,"installment_interest_cents":0,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"fee_cents":450,"net_cents":8550,"expected_payout_on":"2026-12-21","payout_deposited_on":null,"payout_id":null,"split":[{"recipient_id":"shw_2","amount_cents":9000,"fee_cents":450,"net_cents":8550}]}}', true)]);
    $payment = $perata->payments->get('pay_1');
    check($payment->feeCents === 450 && $payment->netCents === 8550 && $payment->expectedPayoutOn === '2026-12-21' && $payment->payoutId === null && $payment->payoutDepositedOn === null, 'payment');
    check(count($payment->split) === 1 && $payment->split[0]->recipientId === 'shw_2' && $payment->split[0]->amountCents === 9000 && $payment->split[0]->feeCents === 450 && $payment->split[0]->netCents === 8550, 'split');
};

// The balance carries its period, the payouts are filtered and walked page by
// page, and a payout reads back its lines: a fee has no payment.
$tests['the balance and the payouts read back what will be deposited'] = static function (): void {
    [$perata, $seen] = client(static function (array $request): array {
        $url = (string) $request['url'];
        if (str_contains($url, '/api/v1/balance')) {
            return [200, [], json_decode('{"data":{"total_to_receive_cents":100000,"released_cents":10000,"held_cents":5000,"scheduled_cents":60000,"later_cents":25000,"deposited_cents":42000,"period_from":"2026-11-01","period_to":"2026-11-20","currency":"BRL"}}', true)];
        }
        if (str_contains($url, '/api/v1/payouts/po_20261120')) {
            return [200, [], json_decode('{"data":{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2,"items":[{"kind":"sale","payment_id":"pay_1","installment":1,"status":"deposited","amount_cents":10000,"fee_cents":300,"net_cents":9700},{"kind":"fee","payment_id":null,"installment":0,"status":"deposited","amount_cents":0,"fee_cents":150,"net_cents":-150}]}}', true)];
        }
        return [200, [], str_contains($url, 'page=2') ? json_decode('{"data":{"items":[{"id":"po_20261119","status":"released","expected_on":"2026-11-19","deposited_on":null,"amount_cents":5000,"fee_cents":200,"net_cents":4800,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}', true) : json_decode('{"data":{"items":[{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}', true)];
    });
    $balance = $perata->balance->get(['date_from' => '2026-11-01', 'date_to' => '2026-11-20']);
    check($seen[0]['url'] === 'https://perata.test/api/v1/balance?date_from=2026-11-01&date_to=2026-11-20', 'balance url ' . $seen[0]['url']);
    check($balance->totalToReceiveCents === 100000 && $balance->depositedCents === 42000 && $balance->periodFrom === '2026-11-01' && $balance->periodTo === '2026-11-20' && $balance->currency === 'BRL', 'balance');
    check($balance->releasedCents + $balance->heldCents + $balance->scheduledCents + $balance->laterCents === $balance->totalToReceiveCents, 'balance parts');
    $walked = [];
    foreach ($perata->payouts->listIter(['status' => 'deposited', 'date_from' => '2026-11-01', 'sorting' => '-date', 'limit' => 1]) as $payout) {
        $walked[] = $payout->id . ':' . $payout->status;
        check($payout->netCents === $payout->amountCents - $payout->feeCents, 'payout net');
        check(($payout->status === 'deposited') === ($payout->depositedOn !== null), 'deposited_on');
    }
    check($walked === ['po_20261120:deposited', 'po_20261119:released'], 'walked ' . implode(',', $walked));
    check($seen[1]['url'] === 'https://perata.test/api/v1/payouts?page=1&status=deposited&date_from=2026-11-01&sorting=-date&limit=1', 'payouts url ' . $seen[1]['url']);
    $payout = $perata->payouts->get('po_20261120');
    check($payout->netCents === 9550 && count($payout->items) === 2, 'payout');
    $sale = $payout->items[0];
    $fee = $payout->items[1];
    check($sale->kind === 'sale' && $sale->paymentId === 'pay_1' && $sale->installment === 1 && $sale->netCents === 9700, 'sale');
    check($fee->kind === 'fee' && $fee->paymentId === null && $fee->netCents === -150, 'fee');
};

// A checkout says how its subscription renews, the subscription reads back the
// mode it resolved to, its label and whether the buyer is written to, an update
// changes them, and the open renewal charge is read by its own route; without
// one the API answers 404 no_open_charge.
$tests['the renewal mode, the label and the open charge'] = static function (): void {
    $answers = [
        'POST /api/v1/checkouts' => [201, '{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"Olho de Águia · Ana","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"x","first_period_extra_days":null,"renewal_mode":"automatic","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}'],
        'PATCH /api/v1/subscriptions/sub_1' => [200, '{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"pix_automatic","label":"Olho de Águia · Ana","notify_customer_email":false}}'],
        'GET /api/v1/subscriptions/sub_1/open-charge' => [200, '{"data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","reminder":null,"days_until_due":null,"notify_customer_email":true}}'],
    ];
    [$perata, $seen] = client(static function (array $request) use ($answers): array {
        $route = $request['method'] . ' ' . parse_url($request['url'], PHP_URL_PATH);
        if (isset($answers[$route])) {
            return [$answers[$route][0], [], json_decode($answers[$route][1], true)];
        }
        return [404, [], ['error' => 'no_open_charge', 'message' => 'A assinatura não tem cobrança de renovação em aberto.']];
    });
    $label = 'Olho de Águia · Ana';
    $checkout = $perata->checkouts->create(['product_id' => 'prod_1', 'price_id' => 'price_1', 'renewal_mode' => 'automatic', 'notify_customer_email' => false, 'label' => $label]);
    $sent = json_decode((string) $seen[0]['body'], true);
    check($sent['renewal_mode'] === 'automatic' && $sent['notify_customer_email'] === false && $sent['label'] === $label, 'checkout body ' . $seen[0]['body']);
    check($checkout->renewalMode === 'automatic' && $checkout->notifyCustomerEmail === false && $checkout->label === $label, 'checkout');
    $subscription = $perata->subscriptions->update('sub_1', ['renewal_mode' => 'manual', 'notify_customer_email' => true, 'label' => $label]);
    $sent = json_decode((string) $seen[1]['body'], true);
    check($sent['renewal_mode'] === 'manual' && $sent['notify_customer_email'] === true && $sent['label'] === $label, 'update body ' . $seen[1]['body']);
    check($subscription->renewalMode === 'pix_automatic' && $subscription->label === $label && $subscription->notifyCustomerEmail === false, 'subscription');
    $charge = $perata->subscriptions->getOpenCharge('sub_1');
    check($seen[2]['url'] === 'https://perata.test/api/v1/subscriptions/sub_1/open-charge', 'charge url ' . $seen[2]['url']);
    check($charge->id === 'rc_1' && $charge->subscriptionId === 'sub_1' && $charge->amountCents === 9000 && $charge->renewalMode === 'manual', 'charge');
    check($charge->paymentUrl === 'https://perata.sh/pagar/rc_1' && $charge->dueAt === '2026-12-20T03:00:00Z' && $charge->expiresAt === '2026-12-27T03:00:00Z' && $charge->reminder === null && $charge->daysUntilDue === null && $charge->notifyCustomerEmail === true, 'charge fields');
    try {
        $perata->subscriptions->getOpenCharge('sub_2');
        check(false, 'a missing open charge was read');
    } catch (PerataException $refused) {
        check($refused->status === 404 && $refused->errorCode === 'no_open_charge', 'refusal');
    }
};

// The renewal events carry the charge: due, and the reminder with its days.
$tests['the renewal events carry the charge'] = static function (): void {
    $now = SIGNED_AT + 120;
    $due = Webhook::verify(NEW_SECRET, webhookHeaders('msg_7', SIGNED_AT, 'v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w='), '{"id":"msg_7","type":"subscription.renewal_due","timestamp":"2026-10-22T12:00:00Z","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":null,"days_until_due":null}}', $now);
    check($due instanceof RenewalChargeWebhookEvent && $due->type === 'subscription.renewal_due' && $due->data->id === 'rc_1' && $due->data->paymentUrl === 'https://perata.sh/pagar/rc_1' && $due->data->reminder === null, 'due event');
    $reminder = Webhook::verify(NEW_SECRET, webhookHeaders('msg_8', SIGNED_AT, 'v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q='), '{"id":"msg_8","type":"subscription.renewal_reminder","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":"before_due","days_until_due":3}}', $now);
    check($reminder instanceof RenewalChargeWebhookEvent && $reminder->type === 'subscription.renewal_reminder' && $reminder->environment === 'live' && $reminder->data->reminder === 'before_due' && $reminder->data->daysUntilDue === 3, 'reminder event');
};

$tests['usage ingestion carries the source credential and its events'] = static function (): void {
    $seen = new \ArrayObject();
    $transport = static function (string $method, string $url, array $headers, ?string $body, float $timeout) use ($seen): array {
        $seen[] = ['method' => $method, 'url' => $url, 'headers' => $headers, 'body' => $body];
        return [200, [], json_encode(['data' => ['created' => 1, 'replayed' => 0]])];
    };
    $usage = new Perata('pus_live_source', 'https://perata.test/', transport: $transport);
    $receipt = $usage->usage->ingest(['events' => [[
        'customer_id' => 'cus_1', 'external_event_id' => 'req-1', 'input_tokens' => '1200', 'output_tokens' => '300', 'cached_tokens' => '0',
        'occurred_at' => '2026-11-13T12:00:00Z', '_cost' => ['amount' => '1.250000', 'currency' => 'brl'],
    ]]]);
    check($receipt->created === 1 && $receipt->replayed === 0, 'receipt');
    check($seen[0]['method'] === 'POST' && $seen[0]['url'] === 'https://perata.test/api/v1/usage/token-events', 'request ' . $seen[0]['url']);
    check($seen[0]['headers']['Authorization'] === 'Bearer pus_live_source', 'credential');
    $sent = json_decode((string) $seen[0]['body'], true);
    check(is_array($sent) && count($sent['events']) === 1 && $sent['events'][0]['_cost'] === ['amount' => '1.250000', 'currency' => 'brl'], 'body ' . $seen[0]['body']);
    check(!array_key_exists('_llm', $sent['events'][0]) && !array_key_exists('parent_id', $sent['events'][0]), 'an optional field left out was sent');
};

$tests['usage ingestion errors are the flat error document'] = static function (): void {
    $event = ['customer_id' => 'cus_1', 'external_event_id' => 'req-1', 'input_tokens' => '1', 'output_tokens' => '0', 'cached_tokens' => '0', 'occurred_at' => '2026-11-13T12:00:00Z'];
    $cases = [
        [401, ['error' => 'invalid_credential'], 'invalid_credential', 0, ''],
        [409, ['error' => 'conflict', 'record' => 2, 'message' => 'conflict'], 'conflict', 2, 'conflict'],
        [422, ['error' => 'invalid_request', 'record' => 3, 'message' => 'validation failed: customer_id', 'fields' => ['customer_id' => ['unknown']]], 'invalid_request', 3, 'validation failed: customer_id'],
        [400, ['error' => 'invalid_request', 'message' => 'malformed JSON'], 'invalid_request', 0, 'malformed JSON'],
        [415, ['error' => 'unsupported_media_type'], 'unsupported_media_type', 0, ''],
        [500, ['error' => 'unavailable'], 'unavailable', 0, ''],
    ];
    foreach ($cases as [$status, $body, $code, $record, $message]) {
        [$perata] = client(static fn (): array => [$status, [], $body]);
        try {
            $perata->usage->ingest(['events' => [$event]]);
            check(false, "a {$status} did not throw");
        } catch (PerataException $refused) {
            check($refused->status === $status && $refused->errorCode === $code && $refused->record === $record, "refusal {$status}");
            check($message === '' || str_contains($refused->getMessage(), $message), 'message');
            check($status !== 422 || $refused->fields === ['customer_id' => ['unknown']], 'fields');
        }
    }
};

$tests['an error wrapped in data by an older server is still read'] = static function (): void {
    $event = ['customer_id' => 'cus_1', 'external_event_id' => 'req-1', 'input_tokens' => '1', 'output_tokens' => '0', 'cached_tokens' => '0', 'occurred_at' => '2026-11-13T12:00:00Z'];
    [$perata] = client(static fn (): array => [409, [], ['data' => ['error' => 'event_conflict', 'record' => 2, 'message' => 'conflict']]]);
    try {
        $perata->usage->ingest(['events' => [$event]]);
        check(false, 'a 409 did not throw');
    } catch (PerataException $refused) {
        check($refused->status === 409 && $refused->errorCode === 'event_conflict' && $refused->record === 2, 'legacy refusal');
    }
};

$tests['a refusal is a typed error'] = static function (): void {
    [$perata] = client(static fn (array $request): array => str_ends_with($request['url'], '/api/v1/customers')
        ? [422, [], ['error' => 'invalid_request', 'fields' => ['email' => ['send an e-mail']]]]
        : [429, ['retry-after' => '7'], null]);
    try {
        $perata->customers->create(['name' => 'x', 'email' => 'x']);
        check(false, 'a 422 did not throw');
    } catch (PerataException $refused) {
        check($refused->status === 422 && $refused->errorCode === 'invalid_request' && $refused->fields['email'] === ['send an e-mail'], 'refusal');
    }
    try {
        $perata->products->list();
        check(false, 'a 429 did not throw');
    } catch (PerataException $limited) {
        check($limited->status === 429 && $limited->retryAfter === 7, 'retry after');
    }
};

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const REFERENCE_SECRET = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
const OLD_SECRET = 'whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=';
const NEW_SECRET = 'whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=';
const ORDER_PAID = '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}';
const USAGE_RECORDED = '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}';
const ORDER_PAID_LIVE = '{"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}';
const PAYOUT_SENT_TEST = '{"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","environment":"test","data":{"payout_id":"po_1","amount_cents":5000}}';
const PAYOUT_SENT = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}';
const SIGNED_AT = 1792670400;

/**
 * @return array<string, string>
 */
function webhookHeaders(string $id, int $at, string $signature): array
{
    return ['Webhook-Id' => $id, 'webhook-timestamp' => (string) $at, 'webhook-signature' => $signature];
}

function refused(callable $call): bool
{
    try {
        $call();
        return false;
    } catch (WebhookVerificationException) {
        return true;
    }
}

$tests['the Standard Webhooks vector verifies'] = static function (): void {
    $body = '{"test": 2432232314}';
    $headers = webhookHeaders('msg_p5jXN8AQM9LWM0D4loKWxJek', 1614265330, 'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=');
    Webhook::verifySignature(REFERENCE_SECRET, $headers, $body, 1614265330);
    check(refused(static fn () => Webhook::verifySignature(REFERENCE_SECRET, $headers, $body . ' ', 1614265330)), 'a changed body verified');
    check(refused(static fn () => Webhook::verifySignature(REFERENCE_SECRET, $headers, $body, 1614265330 + 301)), 'a stale webhook verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, $headers, $body, 1614265330)), 'another secret verified');
};

$tests['a timestamp that is not plain digits is refused'] = static function (): void {
    foreach ([['+1614265330', 'JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8='], ['²', 'PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY='], ['', 'x'], ['1_6', 'x']] as [$stamp, $signature]) {
        $headers = ['Webhook-Id' => 'msg_p5jXN8AQM9LWM0D4loKWxJek', 'webhook-timestamp' => $stamp, 'webhook-signature' => 'v1,' . $signature];
        check(refused(static fn () => Webhook::verifySignature(REFERENCE_SECRET, $headers, '{"test": 2432232314}', 1614265330)), "verified {$stamp}");
    }
};

$tests['a webhook carries the environment it happened in'] = static function (): void {
    $now = SIGNED_AT + 120;
    foreach ([['msg_2', 'v1,F6yjAk5yoz2jK2Q70MVlMG2eFKNVM17nIhiWKfmjCzc= v1,npiewgDGHvzxB3L7ys4KBiP2hooWdiMkdW2tPNyOv/8=', ORDER_PAID], ['msg_3', 'v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=', USAGE_RECORDED], ['msg_4', 'v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=', PAYOUT_SENT]] as [$id, $signature, $body]) {
        $event = Webhook::verify(NEW_SECRET, webhookHeaders($id, SIGNED_AT, $signature), $body, $now);
        check($event->environment === '', "no environment in {$id}");
        check($event->showcaseId === '', "no showcase in {$id}");
    }
    $order = Webhook::verify(NEW_SECRET, webhookHeaders('msg_5', SIGNED_AT, 'v1,uz6PnD5ymh2ny+f3isuMCyoYJ/B1du6G21/9CW1HB7I='), ORDER_PAID_LIVE, $now);
    check($order instanceof OrderWebhookEvent && $order->environment === 'live', 'order environment');
    check($order instanceof OrderWebhookEvent && $order->showcaseId === 'shw_1' && $order->data->showcaseId === 'shw_1', 'order showcase');
    $unknown = Webhook::verify(NEW_SECRET, webhookHeaders('msg_6', SIGNED_AT, 'v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM='), PAYOUT_SENT_TEST, $now);
    check($unknown instanceof UnknownWebhookEvent && $unknown->environment === 'test', 'unknown environment');
    check($unknown instanceof UnknownWebhookEvent && $unknown->showcaseId === '', 'unknown showcase');
};

$tests['a webhook answers its typed event'] = static function (): void {
    $now = SIGNED_AT + 120;
    $headers = webhookHeaders('msg_2', SIGNED_AT, 'v1,F6yjAk5yoz2jK2Q70MVlMG2eFKNVM17nIhiWKfmjCzc= v1,npiewgDGHvzxB3L7ys4KBiP2hooWdiMkdW2tPNyOv/8=');
    foreach ([NEW_SECRET, OLD_SECRET] as $secret) {
        $event = Webhook::verify($secret, $headers, ORDER_PAID, $now);
        check($event instanceof OrderWebhookEvent && $event->type === 'order.paid' && $event->data->id === 'ord_1'
            && $event->data->installments === 3 && $event->data->installmentInterestCents === 360, 'order event');
    }
    check(refused(static fn () => Webhook::verify(REFERENCE_SECRET, $headers, ORDER_PAID, $now)), 'a secret that signed nothing verified');
    $usage = Webhook::verify(NEW_SECRET, webhookHeaders('msg_3', SIGNED_AT, 'v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU='), USAGE_RECORDED, $now);
    check($usage instanceof IdentifiersWebhookEvent && $usage->id === 'msg_3' && $usage->data['merchant_id'] === 'mer_1', 'identifiers event');
    $unknown = Webhook::verify(NEW_SECRET, webhookHeaders('msg_4', SIGNED_AT, 'v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY='), PAYOUT_SENT, $now);
    check($unknown instanceof UnknownWebhookEvent && $unknown->type === 'payout.sent' && $unknown->data === ['payout_id' => 'po_1', 'amount_cents' => 5000], 'unknown event');
};

$tests['the real HTTP sends and reads through curl'] = static function (): void {
    $socket = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr(strrchr((string) stream_socket_get_name($socket, false), ':'), 1);
    fclose($socket);
    $server = proc_open([PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/server.php'], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    try {
        for ($tries = 0; $tries < 50 && @fsockopen('127.0.0.1', $port) === false; $tries++) {
            usleep(100_000);
        }
        $perata = new Perata('prk_test_key', "http://127.0.0.1:{$port}");
        $product = $perata->products->create(['name' => 'Curso'], idempotencyKey: 'create-1');
        check($product->name === 'Curso' && $product->description === 'create-1' && $product->createdAt === 'POST /api/v1/products', 'over HTTP: ' . json_encode($product));
        try {
            (new Perata('prk_test_other', "http://127.0.0.1:{$port}"))->products->get('prod_1');
            check(false, 'a 401 did not throw');
        } catch (PerataException $refused) {
            check($refused->status === 401 && $refused->errorCode === 'invalid_credential' && $refused->retryAfter === 3, 'over HTTP refusal');
        }
    } finally {
        proc_terminate($server);
        proc_close($server);
    }
};

foreach ($tests as $name => $test) {
    try {
        $test();
        echo "ok   {$name}\n";
    } catch (\Throwable $error) {
        $failures++;
        echo "FAIL {$name}: {$error->getMessage()}\n";
    }
}
echo $failures === 0 ? "\nPASS " . count($tests) . " tests\n" : "\nFAIL {$failures} of " . count($tests) . " tests\n";
exit($failures === 0 ? 0 : 1);
