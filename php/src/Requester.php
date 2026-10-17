<?php

declare(strict_types=1);

namespace Perata;

/** What a service calls the API through. */
interface Requester
{
    /**
     * @param array<string, mixed> $query
     * @param array<string, mixed>|null $body
     * @return array<string, mixed>
     */
    public function request(string $method, string $path, array $query = [], ?array $body = null, ?string $idempotencyKey = null, ?string $apiKey = null): array;
}
