using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Perata;

/// <summary>Verifying the webhooks Peráta sends, as Standard Webhooks signs them.</summary>
public static class Webhook
{
    /// <summary>How far from now a webhook's timestamp may be.</summary>
    public static readonly TimeSpan Tolerance = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Checks a webhook Peráta sent and answers its event. The signature is an
    /// HMAC-SHA256 of <c>{webhook-id}.{webhook-timestamp}.{body}</c> under the
    /// key the endpoint's <c>whsec_</c> secret encodes. Pass the body exactly
    /// as it arrived, before parsing it.
    /// </summary>
    /// <typeparam name="TValue">A header's value: a string, or several of them (ASP.NET's StringValues, HttpHeaders' lists).</typeparam>
    /// <param name="secret">The endpoint's secret, <c>whsec_</c> and a base64 key.</param>
    /// <param name="headers">The request's headers, by any case.</param>
    /// <param name="body">The raw body.</param>
    /// <param name="now">The moment the timestamp is checked against; the current time when null.</param>
    /// <returns>The event.</returns>
    /// <exception cref="WebhookVerificationException">Peráta did not sign the request, or signed it too long ago.</exception>
    /// <exception cref="ArgumentException">The secret is not <c>whsec_</c> and a base64 key.</exception>
    public static WebhookEvent Verify<TValue>(string secret, IEnumerable<KeyValuePair<string, TValue>> headers, byte[] body, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(secret);
        ArgumentNullException.ThrowIfNull(headers);
        ArgumentNullException.ThrowIfNull(body);
        byte[] key;
        try
        {
            key = Convert.FromBase64String(secret.StartsWith("whsec_", StringComparison.Ordinal) ? secret[6..] : secret);
        }
        catch (FormatException)
        {
            key = [];
        }
        if (key.Length == 0)
        {
            throw new ArgumentException("perata: the webhook secret is whsec_ and a base64 key", nameof(secret));
        }
        var id = Header(headers, "webhook-id");
        var stamp = Header(headers, "webhook-timestamp");
        if (id.Length == 0 || stamp.Length is 0 or > 18 || !Digits(stamp))
        {
            throw new WebhookVerificationException();
        }
        var at = (now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds();
        if (Math.Abs(at - long.Parse(stamp, NumberStyles.None, CultureInfo.InvariantCulture)) > (long)Tolerance.TotalSeconds)
        {
            throw new WebhookVerificationException();
        }
        var prefix = Encoding.UTF8.GetBytes(id + "." + stamp + ".");
        var signed = new byte[prefix.Length + body.Length];
        prefix.CopyTo(signed, 0);
        body.CopyTo(signed, prefix.Length);
        var expected = HMACSHA256.HashData(key, signed);
        foreach (var signature in Header(headers, "webhook-signature").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var comma = signature.IndexOf(',', StringComparison.Ordinal);
            if (comma < 0 || signature[..comma] != "v1")
            {
                continue;
            }
            byte[] decoded;
            try
            {
                decoded = Convert.FromBase64String(signature[(comma + 1)..]);
            }
            catch (FormatException)
            {
                continue;
            }
            if (CryptographicOperations.FixedTimeEquals(decoded, expected))
            {
                return Event(body);
            }
        }
        throw new WebhookVerificationException();
    }

    /// <summary>
    /// <see cref="Verify{TValue}(string, IEnumerable{KeyValuePair{string, TValue}}, byte[], DateTimeOffset?)"/>
    /// with the body as text, encoded in UTF-8.
    /// </summary>
    /// <typeparam name="TValue">A header's value: a string, or several of them.</typeparam>
    /// <param name="secret">The endpoint's secret, <c>whsec_</c> and a base64 key.</param>
    /// <param name="headers">The request's headers, by any case.</param>
    /// <param name="body">The raw body.</param>
    /// <param name="now">The moment the timestamp is checked against; the current time when null.</param>
    /// <returns>The event.</returns>
    /// <exception cref="WebhookVerificationException">Peráta did not sign the request, or signed it too long ago.</exception>
    public static WebhookEvent Verify<TValue>(string secret, IEnumerable<KeyValuePair<string, TValue>> headers, string body, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(body);
        return Verify(secret, headers, Encoding.UTF8.GetBytes(body), now);
    }

    private static WebhookEvent Event(byte[] body)
    {
        var payload = JsonSerializer.Deserialize(body, PerataJson.Default.WebhookPayload)
            ?? throw new JsonException("perata: the webhook has no body");
        return new WebhookEvent(
            payload.Id ?? throw new JsonException("perata: the webhook has no id"),
            payload.Type ?? throw new JsonException("perata: the webhook has no type"),
            payload.Timestamp ?? throw new JsonException("perata: the webhook has no timestamp"),
            payload.Data ?? new Dictionary<string, string>());
    }

    private static bool Digits(string text)
    {
        foreach (var c in text)
        {
            if (!char.IsAsciiDigit(c))
            {
                return false;
            }
        }
        return true;
    }

    private static string Header<TValue>(IEnumerable<KeyValuePair<string, TValue>> headers, string name)
    {
        foreach (var header in headers)
        {
            if (!string.Equals(header.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            return header.Value switch
            {
                null => "",
                string text => text,
                IEnumerable<string> values => string.Join(' ', values),
                var other => other.ToString() ?? "",
            };
        }
        return "";
    }
}
