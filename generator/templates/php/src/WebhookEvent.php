<?php

declare(strict_types=1);

namespace Perata;

/**
 * A webhook Peráta sent, verified: one subclass a kind of data
 * (OrderWebhookEvent carries a WebhookOrder…), or UnknownWebhookEvent for a type
 * this SDK does not know yet. Within a class, $type says what happened.
 */
abstract class WebhookEvent
{
    public function __construct(
        /** The message's id, the same as the webhook-id header. */
        public readonly string $id,
        /** What happened: order.paid… */
        public readonly string $type,
        /** When it happened, in RFC 3339. */
        public readonly string $timestamp,
        /** The environment it happened in, "test" or "live"; empty when an older server did not send it. */
        public readonly string $environment = '',
    ) {
    }
}
