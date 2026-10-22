<?php

// Peráta's PHP SDK tests, with no dependency to install: php tests/run.php

declare(strict_types=1);

use Perata\IdentifiersWebhookEvent;
use Perata\OrderWebhookEvent;
use Perata\Perata;
use Perata\PerataException;
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
    return [new Perata('prk_test_key', 'http://perata.test/', transport: $transport), $seen];
}

function product(string $id): array
{
    return ['id' => $id, 'name' => 'Curso', 'description' => '', 'status' => 'active', 'created_at' => '2026-10-17T00:00:00Z'];
}

$tests['a call carries the key and unwraps the data'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [200, [], ['data' => product('prod_1')]]);
    $got = $perata->products->get('prod_1');
    check($got->id === 'prod_1' && $got->status === 'active' && $got->createdAt === '2026-10-17T00:00:00Z', 'product');
    check($seen[0]['method'] === 'GET' && $seen[0]['url'] === 'http://perata.test/api/v1/products/prod_1', 'request ' . $seen[0]['url']);
    check($seen[0]['headers']['Authorization'] === 'Bearer prk_test_key', 'key');
};

$tests['a write sends its body and idempotency key'] = static function (): void {
    [$perata, $seen] = client(static fn (): array => [201, [], ['data' => product('prod_1')]]);
    $perata->products->create(['name' => 'Curso'], idempotencyKey: 'create-1');
    check($seen[0]['method'] === 'POST' && $seen[0]['headers']['Idempotency-Key'] === 'create-1', 'request');
    check(json_decode((string) $seen[0]['body'], true) === ['name' => 'Curso'], 'body ' . $seen[0]['body']);
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
const ORDER_PAID = '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}';
const USAGE_RECORDED = '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}';
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

$tests['a webhook answers its typed event'] = static function (): void {
    $now = SIGNED_AT + 120;
    $headers = webhookHeaders('msg_2', SIGNED_AT, 'v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=');
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
