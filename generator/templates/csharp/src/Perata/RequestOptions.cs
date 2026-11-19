namespace Perata;

/// <summary>Options for one call.</summary>
public sealed record RequestOptions
{
    /// <summary>
    /// Makes a write safe to repeat: the same key with the same body answers
    /// the first response again; with another body, a 409. A 2xx answer stays
    /// under the key; a 4xx or 5xx frees it, so the same key can be sent
    /// again. Reads ignore it.
    /// </summary>
    public string? IdempotencyKey { get; init; }

    /// <summary>Sends this call with another organization's key.</summary>
    public string? ApiKey { get; init; }
}
