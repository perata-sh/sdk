<?php

// Peráta's PHP SDK tests, with no dependency to install: php tests/run.php

declare(strict_types=1);

use Perata\Perata;
use Perata\PerataException;
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

$tests['a webhook verifies only when Peráta signed it'] = static function (): void {
    $key = '0123456789abcdef0123456789abcdef';
    $secret = 'whsec_' . base64_encode($key);
    $body = '{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}';
    $now = 1_800_000_000;
    $sign = static fn (int $at, string $payload): array => [
        'webhook-id' => 'msg_1',
        'webhook-timestamp' => (string) $at,
        'webhook-signature' => 'v1,bm90LXRoaXMtb25l v1,' . base64_encode(hash_hmac('sha256', "msg_1.{$at}.{$payload}", $key, true)),
    ];
    $event = Webhook::verify($secret, $sign($now, $body), $body, $now);
    check($event->type === 'checkout_session.succeeded' && $event->data['checkout_session_id'] === 'cs_1', 'event');
    foreach ([[$sign($now, $body), $body . ' '], [$sign($now - 600, $body), $body]] as [$headers, $payload]) {
        try {
            Webhook::verify($secret, $headers, $payload, $now);
            check(false, 'a forged or stale webhook verified');
        } catch (WebhookVerificationException) {
        }
    }
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
