<?php

declare(strict_types=1);

namespace Perata;

/** A request Peráta did not sign, or signed too long ago. */
final class WebhookVerificationException extends \RuntimeException
{
    public function __construct(string $message = 'perata: webhook signature does not verify')
    {
        parent::__construct($message);
    }
}
