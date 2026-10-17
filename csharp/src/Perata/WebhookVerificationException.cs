using System;

namespace Perata;

/// <summary>A request Peráta did not sign, or signed too long ago.</summary>
public sealed class WebhookVerificationException : Exception
{
    /// <summary>The refusal of a webhook.</summary>
    public WebhookVerificationException()
        : base("perata: webhook signature does not verify")
    {
    }
}
