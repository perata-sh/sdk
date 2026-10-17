using System.Collections.Generic;

namespace Perata;

/// <summary>What Peráta posts to an endpoint.</summary>
/// <param name="Id">The message's id, the same on every delivery of it.</param>
/// <param name="Type">What happened: <c>checkout_session.succeeded</c>…</param>
/// <param name="Timestamp">When it happened, RFC 3339.</param>
/// <param name="Data">The event's ids and values.</param>
public sealed record WebhookEvent(string Id, string Type, string Timestamp, IReadOnlyDictionary<string, string> Data);
