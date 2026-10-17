<?php

declare(strict_types=1);

namespace Perata;

/** What Peráta posts to an endpoint. */
final class WebhookEvent
{
    /**
     * @param array<string, string> $data
     */
    public function __construct(
        public readonly string $id,
        public readonly string $type,
        public readonly string $timestamp,
        public readonly array $data,
    ) {
    }
}
