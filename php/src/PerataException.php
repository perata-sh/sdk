<?php

declare(strict_types=1);

namespace Perata;

/**
 * A request the API refused. $errorCode is the API's: invalid_credential,
 * forbidden, not_found, invalid_request, conflict, idempotency_conflict,
 * body_too_large or unavailable; the usage ingestion adds invalid_events and
 * event_conflict. $fields says, for invalid_request, what is wrong with each
 * field. $record is, for the usage ingestion, the position (from 1) in the
 * batch of the event the API refused, and 0 for any other error. $retryAfter
 * is how many seconds to wait on a 429.
 */
final class PerataException extends \RuntimeException
{
    /**
     * @param array<string, list<string>> $fields
     */
    public function __construct(
        public readonly int $status,
        public readonly string $errorCode,
        string $message = '',
        public readonly array $fields = [],
        public readonly ?int $retryAfter = null,
        public readonly int $record = 0,
    ) {
        parent::__construct($message !== '' ? "perata: {$status} {$errorCode}: {$message}" : "perata: {$status} {$errorCode}", $status);
    }

    /**
     * @param array<string, string> $headers in lower case
     */
    public static function fromResponse(int $status, array $headers, string $body): self
    {
        $data = json_decode($body, true);
        if (!is_array($data)) {
            $data = []; // A refusal without a JSON body is still a refusal.
        }
        // The API's errors are the problem itself; the usage ingestion's are
        // wrapped in data, as its answers are.
        if (!array_key_exists('error', $data) && is_array($data['data'] ?? null)) {
            $data = $data['data'];
        }
        $retryAfter = $headers['retry-after'] ?? '';
        return new self(
            $status,
            is_string($data['error'] ?? null) ? $data['error'] : '',
            is_string($data['message'] ?? null) ? $data['message'] : '',
            is_array($data['fields'] ?? null) ? $data['fields'] : [],
            ctype_digit($retryAfter) ? (int) $retryAfter : null,
            is_int($data['record'] ?? null) ? $data['record'] : 0,
        );
    }
}
