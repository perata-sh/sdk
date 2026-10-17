using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Perata.Tests;

public class PerataTests
{
    private sealed record Seen(HttpMethod Method, Uri Url, Dictionary<string, string> Headers, string? Body);

    private sealed record Answer(HttpStatusCode Status, string? Json, Dictionary<string, string>? Headers = null);

    /// <summary>Answers every request with what answer says, recording what was sent.</summary>
    private sealed class Recorder(Func<Seen, Answer> answer) : HttpMessageHandler
    {
        public List<Seen> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
            string? body = null;
            if (request.Content is not null)
            {
                foreach (var header in request.Content.Headers)
                {
                    headers[header.Key] = string.Join(",", header.Value);
                }
                body = await request.Content.ReadAsStringAsync(cancellationToken);
            }
            var seen = new Seen(request.Method, request.RequestUri!, headers, body);
            Requests.Add(seen);
            var reply = answer(seen);
            var response = new HttpResponseMessage(reply.Status) { Content = new StringContent(reply.Json ?? "", Encoding.UTF8, "application/json") };
            foreach (var (name, value) in reply.Headers ?? [])
            {
                response.Headers.TryAddWithoutValidation(name, value);
            }
            return response;
        }
    }

    private static PerataClient Client(Recorder recorder) =>
        new("prk_test_key", new PerataClientOptions { BaseUrl = "http://perata.test/", Handler = recorder });

    private static string ProductJson(string id) =>
        $$"""{"id":"{{id}}","name":"Curso","description":"","status":"active","created_at":"2026-10-17T00:00:00Z"}""";

    private static Dictionary<string, string> Query(Uri url) =>
        url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(parts => parts[0], parts => parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : "");

    [Fact]
    public async Task ACallCarriesTheKeyAndUnwrapsTheData()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, $$"""{"data":{{ProductJson("prod_1")}}}"""));
        var got = await Client(recorder).Products.GetAsync("prod_1");
        Assert.Equal("prod_1", got.Id);
        Assert.Equal(Product.StatusActive, got.Status);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Get, seen.Method);
        Assert.Equal("/api/v1/products/prod_1", seen.Url.AbsolutePath);
        Assert.Equal("Bearer prk_test_key", seen.Headers["Authorization"]);
        Assert.Equal("perata-csharp/" + PerataClient.Version, seen.Headers["User-Agent"]);
    }

    [Fact]
    public async Task AWriteSendsItsBodyAndIdempotencyKey()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.Created, $$"""{"data":{{ProductJson("prod_1")}}}"""));
        await Client(recorder).Products.CreateAsync(new ProductsCreateParams { Name = "Curso" }, new RequestOptions { IdempotencyKey = "create-1" });
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Post, seen.Method);
        Assert.Equal("create-1", seen.Headers["Idempotency-Key"]);
        Assert.Equal("application/json", seen.Headers["Content-Type"]);
        using var body = JsonDocument.Parse(seen.Body!);
        Assert.Equal("Curso", body.RootElement.GetProperty("name").GetString());
        Assert.False(body.RootElement.TryGetProperty("description", out _), "an optional field left out was sent");
    }

    [Fact]
    public async Task IteratingWalksEveryPage()
    {
        var recorder = new Recorder(seen =>
        {
            var page = Query(seen.Url)["page"];
            return new Answer(HttpStatusCode.OK, """{"data":{"items":[""" + ProductJson("prod_" + page) + """],"pagination":{"total_count":3,"max_page":3}}}""");
        });
        var ids = new List<string>();
        await foreach (var product in Client(recorder).Products.ListIterAsync(new ProductsListParams { Limit = 1 }))
        {
            ids.Add(product.Id);
        }
        Assert.Equal(["prod_1", "prod_2", "prod_3"], ids);
        Assert.Equal("1", Query(recorder.Requests[0].Url)["limit"]);
    }

    [Fact]
    public async Task ARefusalIsATypedError()
    {
        var recorder = new Recorder(seen => seen.Url.AbsolutePath == "/api/v1/customers"
            ? new Answer(HttpStatusCode.UnprocessableEntity, """{"error":"invalid_request","fields":{"email":["send an e-mail"]}}""")
            : new Answer(HttpStatusCode.TooManyRequests, null, new() { ["Retry-After"] = "7" }));
        var perata = Client(recorder);
        var refused = await Assert.ThrowsAsync<PerataException>(() => perata.Customers.CreateAsync(new CustomersCreateParams { Name = "x", Email = "x" }));
        Assert.Equal(422, refused.Status);
        Assert.Equal("invalid_request", refused.Code);
        Assert.Equal(["send an e-mail"], refused.Fields["email"]);
        var limited = await Assert.ThrowsAsync<PerataException>(() => perata.Products.ListAsync());
        Assert.Equal(429, limited.Status);
        Assert.Equal(7, limited.RetryAfter);
    }

    [Fact]
    public void AWebhookVerifiesOnlyWhenPerataSignedIt()
    {
        var key = Encoding.UTF8.GetBytes("0123456789abcdef0123456789abcdef");
        var secret = "whsec_" + Convert.ToBase64String(key);
        var body = Encoding.UTF8.GetBytes("""{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}""");
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

        Dictionary<string, string> Sign(long at, byte[] payload)
        {
            var signed = Encoding.UTF8.GetBytes($"msg_1.{at}.").Concat(payload).ToArray();
            return new()
            {
                ["Webhook-Id"] = "msg_1",
                ["webhook-timestamp"] = at.ToString(System.Globalization.CultureInfo.InvariantCulture),
                ["webhook-signature"] = "v1,bm90LXRoaXMtb25l v1," + Convert.ToBase64String(HMACSHA256.HashData(key, signed)),
            };
        }

        var unix = now.ToUnixTimeSeconds();
        var verified = Webhook.Verify(secret, Sign(unix, body), body, now);
        Assert.Equal("checkout_session.succeeded", verified.Type);
        Assert.Equal("cs_1", verified.Data["checkout_session_id"]);
        Assert.Throws<WebhookVerificationException>(() => Webhook.Verify(secret, Sign(unix, body), [.. body, (byte)' '], now));
        Assert.Throws<WebhookVerificationException>(() => Webhook.Verify(secret, Sign(unix - 600, body), body, now));
    }

    [Fact]
    public async Task TheRealHttpSendsAndReadsThroughHttpClient()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var prefix = $"http://127.0.0.1:{port}/";
        using var listener = new HttpListener();
        listener.Prefixes.Add(prefix);
        listener.Start();
        var serving = Task.Run(async () =>
        {
            while (listener.IsListening)
            {
                HttpListenerContext context;
                try
                {
                    context = await listener.GetContextAsync();
                }
                catch (Exception e) when (e is HttpListenerException or ObjectDisposedException or InvalidOperationException)
                {
                    return;
                }
                string answer;
                context.Response.ContentType = "application/json";
                if (context.Request.Headers["Authorization"] != "Bearer prk_test_key")
                {
                    context.Response.StatusCode = 401;
                    context.Response.AddHeader("Retry-After", "3");
                    answer = """{"error":"invalid_credential"}""";
                }
                else
                {
                    using var reader = new System.IO.StreamReader(context.Request.InputStream, Encoding.UTF8);
                    using var sent = JsonDocument.Parse(await reader.ReadToEndAsync());
                    var product = new Dictionary<string, string>
                    {
                        ["id"] = "prod_1",
                        ["name"] = sent.RootElement.GetProperty("name").GetString()!,
                        ["description"] = context.Request.Headers["Idempotency-Key"] ?? "",
                        ["status"] = "active",
                        ["created_at"] = context.Request.HttpMethod + " " + context.Request.RawUrl,
                    };
                    context.Response.StatusCode = 201;
                    answer = "{\"data\":" + JsonSerializer.Serialize(product) + "}";
                }
                var bytes = Encoding.UTF8.GetBytes(answer);
                context.Response.ContentLength64 = bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes);
                context.Response.Close();
            }
        });
        try
        {
            var product = await new PerataClient("prk_test_key", new PerataClientOptions { BaseUrl = prefix })
                .Products.CreateAsync(new ProductsCreateParams { Name = "Curso" }, new RequestOptions { IdempotencyKey = "create-1" });
            Assert.Equal("Curso", product.Name);
            Assert.Equal("create-1", product.Description);
            Assert.Equal("POST /api/v1/products", product.CreatedAt);

            var refused = await Assert.ThrowsAsync<PerataException>(() =>
                new PerataClient("prk_test_other", new PerataClientOptions { BaseUrl = prefix }).Products.GetAsync("prod_1"));
            Assert.Equal(401, refused.Status);
            Assert.Equal("invalid_credential", refused.Code);
            Assert.Equal(3, refused.RetryAfter);
        }
        finally
        {
            listener.Stop();
            await serving;
        }
    }
}
