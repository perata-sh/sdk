<?php

declare(strict_types=1);

namespace Perata;

/** Verifying the webhooks Peráta sends, as Standard Webhooks signs them. */
final class Webhook
{
    /** How far from now, in seconds, a webhook's timestamp may be. */
    public const TOLERANCE_SECONDS = 300;

    /**
     * Checks a webhook Peráta sent and answers its event. The signature is an
     * HMAC-SHA256 of "{webhook-id}.{webhook-timestamp}.{body}" under the key
     * the endpoint's whsec_ secret encodes. Pass the body exactly as it
     * arrived (file_get_contents('php://input')), before decoding it.
     *
     * @param array<string, string|list<string>> $headers
     */
    public static function verify(string $secret, array $headers, string $body, ?int $now = null): WebhookEvent
    {
        $encodedKey = str_starts_with($secret, 'whsec_') ? substr($secret, 6) : $secret;
        $key = base64_decode($encodedKey, true);
        if ($key === false || $key === '') {
            throw new \InvalidArgumentException('perata: the webhook secret is whsec_ and a base64 key');
        }
        $id = self::header($headers, 'webhook-id');
        $stamp = self::header($headers, 'webhook-timestamp');
        if ($id === '' || !ctype_digit($stamp) || abs(($now ?? time()) - (int) $stamp) > self::TOLERANCE_SECONDS) {
            throw new WebhookVerificationException();
        }
        $expected = hash_hmac('sha256', "{$id}.{$stamp}.{$body}", $key, true);
        foreach (preg_split('/\s+/', self::header($headers, 'webhook-signature'), -1, PREG_SPLIT_NO_EMPTY) ?: [] as $signature) {
            [$version, $encoded] = array_pad(explode(',', $signature, 2), 2, '');
            $decoded = base64_decode($encoded, true);
            if ($version === 'v1' && $decoded !== false && hash_equals($expected, $decoded)) {
                $event = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
                return new WebhookEvent($event['id'], $event['type'], $event['timestamp'], $event['data'] ?? []);
            }
        }
        throw new WebhookVerificationException();
    }

    /**
     * @param array<string, string|list<string>> $headers
     */
    private static function header(array $headers, string $name): string
    {
        foreach ($headers as $key => $value) {
            if (strtolower((string) $key) === $name) {
                return is_array($value) ? implode(' ', $value) : $value;
            }
        }
        return '';
    }
}
