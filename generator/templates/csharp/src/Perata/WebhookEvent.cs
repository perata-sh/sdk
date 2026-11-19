using System.Text.Json;

namespace Perata;

/// <summary>
/// A webhook Peráta sent, verified: one record a kind of data
/// (<see cref="OrderWebhookEvent"/> carries a <see cref="WebhookOrder"/>…), or
/// <see cref="UnknownWebhookEvent"/> for a type this SDK does not know yet.
/// Within a record, <see cref="Type"/> says what happened.
/// </summary>
/// <param name="Id">The message's id, the same as the webhook-id header and on every delivery of it.</param>
/// <param name="Type">What happened: <c>order.paid</c>…</param>
/// <param name="Timestamp">When it happened, RFC 3339.</param>
/// <param name="Environment">The environment it happened in, <c>test</c> or <c>live</c>; empty when an older server did not send it.</param>
/// <param name="ShowcaseId">The showcase of the sale, the same <c>showcase_id</c> the API's objects carry; empty when an older server did not send it.</param>
public abstract record WebhookEvent(string Id, string Type, string Timestamp, string Environment, string ShowcaseId);

/// <summary>An event of a type this SDK does not know yet, its data as it was sent.</summary>
/// <param name="Id">The message's id.</param>
/// <param name="Type">What happened.</param>
/// <param name="Timestamp">When it happened, RFC 3339.</param>
/// <param name="Environment">The environment it happened in, <c>test</c> or <c>live</c>.</param>
/// <param name="ShowcaseId">The showcase of the sale.</param>
/// <param name="Data">The event's data, as JSON.</param>
public sealed record UnknownWebhookEvent(string Id, string Type, string Timestamp, string Environment, string ShowcaseId, JsonElement Data)
    : WebhookEvent(Id, Type, Timestamp, Environment, ShowcaseId);
