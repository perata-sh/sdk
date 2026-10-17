using System;
using System.Net.Http;

namespace Perata;

/// <summary>How a <see cref="PerataClient"/> reaches the API.</summary>
public sealed class PerataClientOptions
{
    /// <summary>Another address, such as a local server; <see cref="PerataClient.DefaultBaseUrl"/> when null.</summary>
    public string? BaseUrl { get; set; }

    /// <summary>How long a call waits for its response; 30 seconds when null.</summary>
    public TimeSpan? Timeout { get; set; }

    /// <summary>
    /// The HttpClient that sends the requests, such as one from
    /// <c>IHttpClientFactory</c>; the SDK's shared one when null. Its own
    /// timeout applies on top of <see cref="Timeout"/>.
    /// </summary>
    public HttpClient? HttpClient { get; set; }

    /// <summary>A handler the requests are sent through, when <see cref="HttpClient"/> is null: a test's, or a proxy's.</summary>
    public HttpMessageHandler? Handler { get; set; }
}
