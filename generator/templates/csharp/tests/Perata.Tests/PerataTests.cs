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
        new("prk_test_key", new PerataClientOptions { BaseUrl = "https://perata.test/", Handler = recorder });

    private static string ProductJson(string id) =>
        $$"""{"id":"{{id}}","name":"Curso","description":"","status":"active","showcase_id":"shw_1","created_at":"2026-10-17T00:00:00Z"}""";

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

    private static string SessionJson(string clientSecret) =>
        $$"""{"id":"pcl_1","url":"https://perata.sh/pagamento/pcl_1","product_id":"prod_1","price_id":"price_1","status":"active","label":"","notify_customer_email":true,"renewal_mode":"","quantity":1,"success_url":"https://loja.example/obrigado","cancel_url":"","expires_at":null,"created_at":"2026-11-16T12:00:00Z","session_id":"cs_1","client_secret":"{{clientSecret}}","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-16T12:30:00Z","status_key":"sk_1","amount_cents":null,"items":[],"metadata":{},"client_reference_id":"","discount_id":"","showcase_id":"shw_1","subscription_start_at":null}""";

    [Fact]
    public async Task ACheckoutSessionHandsBackTheClientSecretForTheBrowser()
    {
        var calls = 0;
        var recorder = new Recorder(_ => calls++ == 0
            ? new Answer(HttpStatusCode.Created, $$"""{"data":{{SessionJson("cs_secret_1")}}}""")
            : new Answer(HttpStatusCode.Created, $$"""{"data":{{SessionJson("")}}}""", new Dictionary<string, string> { ["Idempotent-Replayed"] = "true" }));
        var perata = Client(recorder);
        var parameters = new CheckoutsCreateParams { ProductId = "prod_1", PriceId = "price_1", SuccessUrl = "https://loja.example/obrigado" };
        var options = new RequestOptions { IdempotencyKey = "pedido-1" };
        var checkout = await perata.Checkouts.CreateAsync(parameters, options);
        Assert.Equal("cs_secret_1", checkout.ClientSecret);
        Assert.Equal("cs_1", checkout.SessionId);
        Assert.Equal("sk_1", checkout.StatusKey);
        Assert.Equal("2026-11-16T12:30:00Z", checkout.ClientSecretExpiresAt);
        Assert.Equal("https://perata.sh/pagamento/pcl_1", checkout.Url);
        Assert.Null(checkout.ExpiresAt);
        var seen = recorder.Requests[0];
        Assert.Equal(HttpMethod.Post, seen.Method);
        Assert.Equal("/api/v1/checkouts", seen.Url.AbsolutePath);
        Assert.Equal("pedido-1", seen.Headers["Idempotency-Key"]);
        using var body = JsonDocument.Parse(seen.Body!);
        Assert.Equal("prod_1", body.RootElement.GetProperty("product_id").GetString());
        Assert.Equal("price_1", body.RootElement.GetProperty("price_id").GetString());
        Assert.Equal("https://loja.example/obrigado", body.RootElement.GetProperty("success_url").GetString());
        var again = await perata.Checkouts.CreateAsync(parameters, options);
        Assert.Equal("", again.ClientSecret);
        Assert.Equal("cs_1", again.SessionId);
    }

    [Fact]
    public void AModelThatMayBeNullDecodesBothWays()
    {
        const string json = """{"id":"pay_1","method":"pix","state":"pending","unresolved":false,"card_brand":"","card_kind":"","installments":1,"pix":{"copia_e_cola":"000201","qr_code_svg":"<svg/>","expires_at":null},"boleto":null}""";
        var got = JsonSerializer.Deserialize<CheckoutClientPayment>(json)!;
        Assert.Null(got.Boleto);
        Assert.Equal("000201", got.Pix!.CopiaECola);
        Assert.Null(got.Pix.ExpiresAt);
    }

    [Theory]
    [InlineData("https://perata.sh", true)]
    [InlineData("http://localhost:8080", true)]
    [InlineData("http://LOCALHOST", true)]
    [InlineData("http://127.0.0.1:1", true)]
    [InlineData("http://127.255.0.3", true)]
    [InlineData("http://[::1]:8080", true)]
    [InlineData("http://perata.sh", false)]
    [InlineData("http://localhost.evil.test", false)]
    [InlineData("http://127.0.0.1.evil.test", false)]
    [InlineData("http://10.0.0.1", false)]
    [InlineData("ftp://localhost", false)]
    [InlineData("perata.sh", false)]
    [InlineData("", false)]
    [InlineData("http://[::2]", false)]
    public void ABaseUrlMustBeHttpsUnlessItIsLoopback(string baseUrl, bool accepted)
    {
        if (accepted)
        {
            _ = new PerataClient("k", new PerataClientOptions { BaseUrl = baseUrl });
            return;
        }
        var refused = Assert.Throws<ArgumentException>(() => new PerataClient("k", new PerataClientOptions { BaseUrl = baseUrl }));
        Assert.Contains("must be https", refused.Message);
    }

    // A graduated price goes out with its tiers and without the fixed amount, and
    // a subscription reads back the quantity it bills and the order reference it
    // came from; AmountCents is the cycle's total for that quantity.
    [Fact]
    public async Task AGraduatedPriceCarriesItsTiersAndASubscriptionItsQuantity()
    {
        const string price = """{"id":"price_1","product_id":"prod_1","type":"recurring","interval":"month","interval_count":1,"currency":"BRL","status":"active","amount_cents":0,"pricing_model":"graduated","unit_amount_cents":null,"unit_label":"câmera","unit_label_plural":"câmeras","tiers":[{"up_to":1,"unit_amount_cents":25000},{"up_to":null,"unit_amount_cents":15000}]}""";
        const string subscription = """{"id":"sub_1","label":"","notify_customer_email":true,"renewal_mode":"manual","amount_cents":55000,"cancel_at_period_end":false,"client_reference_id":"pedido-9","currency":"BRL","current_period_end":"2026-12-20T00:00:00Z","current_period_start":"2026-11-20T00:00:00Z","customer_id":"cus_1","interval":"month","metadata":{"camera":"c1"},"price_id":"price_1","product_id":"prod_1","quantity":3,"showcase_id":"shw_1","status":"active","suspended_at":null,"suspension_reason":null,"trial_end":null,"trial_start":null}""";
        var recorder = new Recorder(seen => seen.Method == HttpMethod.Post
            ? new Answer(HttpStatusCode.Created, $$"""{"data":{{price}}}""")
            : new Answer(HttpStatusCode.OK, $$"""{"data":{{subscription}}}"""));
        var perata = Client(recorder);
        var created = await perata.Prices.CreateAsync(new PricesCreateParams
        {
            ProductId = "prod_1",
            Type = PricesCreateParams.TypeRecurring,
            Interval = PricesCreateParams.IntervalMonth,
            PricingModel = PricesCreateParams.PricingModelGraduated,
            Tiers = [new PricesCreateTier { UpTo = 1, UnitAmountCents = 25000 }, new PricesCreateTier { UnitAmountCents = 15000 }],
            UnitLabel = "câmera",
            UnitLabelPlural = "câmeras",
        });
        Assert.Equal("/api/v1/prices", recorder.Requests[0].Url.AbsolutePath);
        using var body = JsonDocument.Parse(recorder.Requests[0].Body!);
        Assert.Equal("graduated", body.RootElement.GetProperty("pricing_model").GetString());
        var tiers = body.RootElement.GetProperty("tiers");
        Assert.Equal(2, tiers.GetArrayLength());
        Assert.Equal(1, tiers[0].GetProperty("up_to").GetInt64());
        Assert.Equal(25000, tiers[0].GetProperty("unit_amount_cents").GetInt64());
        Assert.False(tiers[1].TryGetProperty("up_to", out var last) && last.ValueKind != JsonValueKind.Null, "the last tier has no limit");
        Assert.False(body.RootElement.TryGetProperty("amount_cents", out _), "a graduated price was sent with a fixed amount");
        Assert.Equal(Price.PricingModelGraduated, created.PricingModel);
        Assert.Equal(0, created.AmountCents);
        Assert.Null(created.UnitAmountCents);
        Assert.Equal([(1L, 25000L), (null, 15000L)], created.Tiers.Select(tier => (tier.UpTo, tier.UnitAmountCents)).ToArray());
        var got = await perata.Subscriptions.GetAsync("sub_1");
        Assert.Equal("/api/v1/subscriptions/sub_1", recorder.Requests[1].Url.AbsolutePath);
        Assert.Equal(3, got.Quantity);
        Assert.Equal(55000, got.AmountCents);
        Assert.Equal("pedido-9", got.ClientReferenceId);
    }

    // A checkout adds the buyer's remaining days to the first period, an
    // extension goes out alone (no price_id), and the sale reads back what it
    // took: the discount on the order and on the subscription, and the change
    // scheduled for the next period.
    [Fact]
    public async Task AFirstPeriodExtensionAndTheDiscountsTheSaleReadsBack()
    {
        var answers = new Dictionary<string, (HttpStatusCode, string)>
        {
            ["POST /api/v1/checkouts"] = (HttpStatusCode.Created, """{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"x","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"disc_1","first_period_extra_days":30,"renewal_mode":"manual","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}"""),
            ["PATCH /api/v1/subscriptions/sub_1"] = (HttpStatusCode.OK, """{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":{"price_id":"price_2","quantity":5,"amount_cents":90000,"effective_at":"2026-12-20T03:00:00Z"},"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":"disc_1","discount_ends_at":"2027-03-01T03:00:00Z","first_period_extra_days":30,"renewal_mode":"manual","label":"x","notify_customer_email":false}}"""),
            ["GET /api/v1/subscriptions/sub_2"] = (HttpStatusCode.OK, """{"data":{"id":"sub_2","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"manual","label":"x","notify_customer_email":false}}"""),
            ["GET /api/v1/orders/ord_1"] = (HttpStatusCode.OK, """{"data":{"id":"ord_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","amount_cents":9000,"currency":"BRL","status":"open","paid_at":null,"order_status":null,"refunded_amount_cents":0,"installments":0,"installment_interest_cents":0,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"x","subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"discount_id":"disc_1","discount_code":"BEMVINDO","subtotal_cents":10000,"discount_cents":1000}}"""),
            ["GET /api/v1/prices/price_1"] = (HttpStatusCode.OK, """{"data":{"id":"price_1","product_id":"prod_1","currency":"BRL","amount_cents":9000,"type":"one_time","interval":"none","interval_count":0,"pricing_model":"fixed","unit_amount_cents":null,"tiers":[],"unit_label":"x","unit_label_plural":"x","minimum_units":null,"maximum_units":null,"status":"archived"}}"""),
        };
        var recorder = new Recorder(seen =>
        {
            var (status, json) = answers[seen.Method + " " + seen.Url.AbsolutePath];
            return new Answer(status, json);
        });
        var perata = Client(recorder);
        var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams { ProductId = "prod_1", PriceId = "price_1", FirstPeriodExtraDays = 30 });
        using var created = JsonDocument.Parse(recorder.Requests[0].Body!);
        Assert.Equal(30, created.RootElement.GetProperty("first_period_extra_days").GetInt64());
        Assert.Equal(30, checkout.FirstPeriodExtraDays);
        Assert.Equal("disc_1", checkout.DiscountId);
        var subscription = await perata.Subscriptions.UpdateAsync("sub_1", new SubscriptionsUpdateParams { ExtendCurrentPeriodDays = 15 });
        using var sent = JsonDocument.Parse(recorder.Requests[1].Body!);
        Assert.Equal(HttpMethod.Patch, recorder.Requests[1].Method);
        Assert.Equal(15, sent.RootElement.GetProperty("extend_current_period_days").GetInt64());
        Assert.False(sent.RootElement.TryGetProperty("price_id", out _), "an extension was sent with a price_id");
        Assert.Equal(30, subscription.FirstPeriodExtraDays);
        Assert.Equal("disc_1", subscription.DiscountId);
        Assert.Equal("2027-03-01T03:00:00Z", subscription.DiscountEndsAt);
        var pending = subscription.PendingUpdate!;
        Assert.Equal(("price_2", 5L, 90000L, "2026-12-20T03:00:00Z"), (pending.PriceId, pending.Quantity, pending.AmountCents, pending.EffectiveAt));
        var none = await perata.Subscriptions.GetAsync("sub_2");
        Assert.Null(none.PendingUpdate);
        Assert.Null(none.FirstPeriodExtraDays);
        Assert.Null(none.DiscountId);
        var order = await perata.Orders.GetAsync("ord_1");
        Assert.Equal((10000L, 1000L, "disc_1", "BEMVINDO"), (order.SubtotalCents, order.DiscountCents, order.DiscountId, order.DiscountCode));
        var price = await perata.Prices.GetAsync("price_1");
        Assert.Equal("/api/v1/prices/price_1", recorder.Requests[4].Url.AbsolutePath);
        Assert.Equal("archived", price.Status);
    }

    // The payment reads back its fee, its net, its split and the payout that pays it.
    [Fact]
    public async Task APaymentReadsBackItsFeeItsSplitAndItsPayout()
    {
        var perata = Client(new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"id":"pay_1","showcase_id":"x","checkout_id":"x","customer_id":"x","method":"card","state":"unknown","amount_cents":0,"captured_cents":0,"refunded_cents":0,"currency":"BRL","created_at":"2026-11-20T12:00:00Z","metadata":{},"client_reference_id":"x","installments":0,"installment_amount_cents":0,"installment_interest_cents":0,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"fee_cents":450,"net_cents":8550,"expected_payout_on":"2026-12-21","payout_deposited_on":null,"payout_id":null,"split":[{"recipient_id":"shw_2","amount_cents":9000,"fee_cents":450,"net_cents":8550}]}}""")));
        var payment = await perata.Payments.GetAsync("pay_1");
        Assert.Equal((450L, 8550L, "2026-12-21"), (payment.FeeCents, payment.NetCents, payment.ExpectedPayoutOn));
        Assert.Null(payment.PayoutId);
        Assert.Null(payment.PayoutDepositedOn);
        var split = Assert.Single(payment.Split);
        Assert.Equal(("shw_2", 9000L, 450L, 8550L), (split.RecipientId, split.AmountCents, split.FeeCents, split.NetCents));
    }

    // The balance carries its period, the payouts are filtered and walked page by
    // page, and a payout reads back its lines: a fee has no payment.
    [Fact]
    public async Task TheBalanceAndThePayoutsReadBackWhatWillBeDeposited()
    {
        var recorder = new Recorder(seen =>
        {
            var json = seen.Url.AbsolutePath switch
            {
                "/api/v1/balance" => """{"data":{"total_to_receive_cents":100000,"released_cents":10000,"held_cents":5000,"scheduled_cents":60000,"later_cents":25000,"deposited_cents":42000,"period_from":"2026-11-01","period_to":"2026-11-20","currency":"BRL"}}""",
                "/api/v1/payouts/po_20261120" => """{"data":{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2,"items":[{"kind":"sale","payment_id":"pay_1","installment":1,"status":"deposited","amount_cents":10000,"fee_cents":300,"net_cents":9700},{"kind":"fee","payment_id":null,"installment":0,"status":"deposited","amount_cents":0,"fee_cents":150,"net_cents":-150}]}}""",
                _ => Query(seen.Url).GetValueOrDefault("page") == "2" ? """{"data":{"items":[{"id":"po_20261119","status":"released","expected_on":"2026-11-19","deposited_on":null,"amount_cents":5000,"fee_cents":200,"net_cents":4800,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}""" : """{"data":{"items":[{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}""",
            };
            return new Answer(HttpStatusCode.OK, json);
        });
        var perata = Client(recorder);
        var balance = await perata.Balance.GetAsync(new BalanceGetParams { DateFrom = "2026-11-01", DateTo = "2026-11-20" });
        Assert.Equal("2026-11-01", Query(recorder.Requests[0].Url)["date_from"]);
        Assert.Equal("2026-11-20", Query(recorder.Requests[0].Url)["date_to"]);
        Assert.Equal((100000L, 42000L, "2026-11-01", "2026-11-20", "BRL"), (balance.TotalToReceiveCents, balance.DepositedCents, balance.PeriodFrom, balance.PeriodTo, balance.Currency));
        Assert.Equal(balance.TotalToReceiveCents, balance.ReleasedCents + balance.HeldCents + balance.ScheduledCents + balance.LaterCents);
        var walked = new List<string>();
        await foreach (var payout in perata.Payouts.ListIterAsync(new PayoutsListParams { Limit = 1, Status = "deposited", DateFrom = "2026-11-01", Sorting = "-date" }))
        {
            walked.Add(payout.Id + ":" + payout.Status);
            Assert.Equal(payout.AmountCents - payout.FeeCents, payout.NetCents);
            Assert.Equal(payout.Status == "deposited", payout.DepositedOn is not null);
        }
        Assert.Equal(["po_20261120:deposited", "po_20261119:released"], walked);
        var query = Query(recorder.Requests[1].Url);
        Assert.Equal(("1", "1", "deposited", "2026-11-01", "-date"), (query["page"], query["limit"], query["status"], query["date_from"], query["sorting"]));
        var detail = await perata.Payouts.GetAsync("po_20261120");
        Assert.Equal((9550L, 2), (detail.NetCents, detail.Items.Count));
        Assert.Equal(("sale", "pay_1", 1L, 9700L), (detail.Items[0].Kind, detail.Items[0].PaymentId, detail.Items[0].Installment, detail.Items[0].NetCents));
        Assert.Equal(("fee", null, -150L), (detail.Items[1].Kind, detail.Items[1].PaymentId, detail.Items[1].NetCents));
    }

    // A checkout says how its subscription renews, the subscription reads back the
    // mode it resolved to, its label and whether the buyer is written to, an update
    // changes them, and the open renewal charge is read by its own route; without
    // one the API answers 404 no_open_charge.
    [Fact]
    public async Task TheRenewalModeTheLabelAndTheOpenCharge()
    {
        var answers = new Dictionary<string, (HttpStatusCode, string)>
        {
            ["POST /api/v1/checkouts"] = (HttpStatusCode.Created, """{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"Olho de Águia · Ana","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"x","first_period_extra_days":null,"renewal_mode":"automatic","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}"""),
            ["PATCH /api/v1/subscriptions/sub_1"] = (HttpStatusCode.OK, """{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"pix_automatic","label":"Olho de Águia · Ana","notify_customer_email":false}}"""),
            ["GET /api/v1/subscriptions/sub_1/open-charge"] = (HttpStatusCode.OK, """{"data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","reminder":null,"days_until_due":null,"notify_customer_email":true}}"""),
        };
        var recorder = new Recorder(seen => answers.TryGetValue(seen.Method + " " + seen.Url.AbsolutePath, out var found)
            ? new Answer(found.Item1, found.Item2)
            : new Answer(HttpStatusCode.NotFound, """{"error":"no_open_charge","message":"A assinatura não tem cobrança de renovação em aberto."}"""));
        var perata = Client(recorder);
        const string label = "Olho de Águia · Ana";
        var checkout = await perata.Checkouts.CreateAsync(new CheckoutsCreateParams
        {
            ProductId = "prod_1", PriceId = "price_1", RenewalMode = CheckoutsCreateParams.RenewalModeAutomatic, NotifyCustomerEmail = false, Label = label,
        });
        using var created = JsonDocument.Parse(recorder.Requests[0].Body!);
        Assert.Equal(("automatic", false, label), (created.RootElement.GetProperty("renewal_mode").GetString(), created.RootElement.GetProperty("notify_customer_email").GetBoolean(), created.RootElement.GetProperty("label").GetString()));
        Assert.Equal(("automatic", false, label), (checkout.RenewalMode, checkout.NotifyCustomerEmail, checkout.Label));
        var subscription = await perata.Subscriptions.UpdateAsync("sub_1", new SubscriptionsUpdateParams { RenewalMode = SubscriptionsUpdateParams.RenewalModeManual, NotifyCustomerEmail = true, Label = label });
        using var sent = JsonDocument.Parse(recorder.Requests[1].Body!);
        Assert.Equal(("manual", true, label), (sent.RootElement.GetProperty("renewal_mode").GetString(), sent.RootElement.GetProperty("notify_customer_email").GetBoolean(), sent.RootElement.GetProperty("label").GetString()));
        Assert.Equal(("pix_automatic", label, false), (subscription.RenewalMode, subscription.Label, subscription.NotifyCustomerEmail));
        var charge = await perata.Subscriptions.GetOpenChargeAsync("sub_1");
        Assert.Equal("/api/v1/subscriptions/sub_1/open-charge", recorder.Requests[2].Url.AbsolutePath);
        Assert.Equal(("rc_1", "sub_1", 9000L, "manual"), (charge.Id, charge.SubscriptionId, charge.AmountCents, charge.RenewalMode));
        Assert.Equal(("https://perata.sh/pagar/rc_1", "2026-12-20T03:00:00Z", "2026-12-27T03:00:00Z"), (charge.PaymentUrl, charge.DueAt, charge.ExpiresAt));
        Assert.Null(charge.Reminder);
        Assert.Null(charge.DaysUntilDue);
        Assert.True(charge.NotifyCustomerEmail);
        var refused = await Assert.ThrowsAsync<PerataException>(() => perata.Subscriptions.GetOpenChargeAsync("sub_2"));
        Assert.Equal((404, "no_open_charge"), (refused.Status, refused.Code));
    }

    // The renewal events carry the charge: due, and the reminder with its days.
    [Fact]
    public void TheRenewalEventsCarryTheCharge()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(SignedAt + 120);
        var due = Assert.IsType<RenewalChargeWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_7", SignedAt, "v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w="), """{"id":"msg_7","type":"subscription.renewal_due","timestamp":"2026-10-22T12:00:00Z","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":null,"days_until_due":null}}""", now));
        Assert.Equal(("subscription.renewal_due", "rc_1", "https://perata.sh/pagar/rc_1"), (due.Type, due.Data.Id, due.Data.PaymentUrl));
        Assert.Null(due.Data.Reminder);
        var reminder = Assert.IsType<RenewalChargeWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_8", SignedAt, "v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q="), """{"id":"msg_8","type":"subscription.renewal_reminder","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":"before_due","days_until_due":3}}""", now));
        Assert.Equal(("subscription.renewal_reminder", "live", "before_due", 3L), (reminder.Type, reminder.Environment, reminder.Data.Reminder, reminder.Data.DaysUntilDue));
    }

    [Fact]
    public async Task ADiscountGoesThroughCreateGetListAndDelete()
    {
        const string template = """{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}""";
        string Discount(string id) => template.Replace("__ID__", id);
        var recorder = new Recorder(seen =>
        {
            if (seen.Method == HttpMethod.Post)
            {
                return new Answer(HttpStatusCode.Created, $$"""{"data":{{Discount("disc_1")}}}""");
            }
            if (seen.Method == HttpMethod.Delete)
            {
                return new Answer(HttpStatusCode.NoContent, null);
            }
            if (seen.Url.AbsolutePath == "/api/v1/discounts")
            {
                return new Answer(HttpStatusCode.OK, """{"data":{"items":[""" + Discount("disc_" + Query(seen.Url)["page"]) + """],"pagination":{"total_count":2,"max_page":2}}}""");
            }
            return new Answer(HttpStatusCode.OK, $$"""{"data":{{Discount("disc_1")}}}""");
        });
        var perata = Client(recorder);
        var created = await perata.Discounts.CreateAsync(new DiscountsCreateParams { Name = "Black", Type = "percentage", Duration = "once", BasisPoints = 1000 });
        Assert.Equal("disc_1", created.Id);
        Assert.Null(created.Code);
        Assert.Equal(["prod_1"], created.ProductIds);
        Assert.Equal("Black", (await perata.Discounts.GetAsync("disc_1")).Name);
        var ids = new List<string>();
        await foreach (var each in perata.Discounts.ListIterAsync(new DiscountsListParams { Limit = 1 }))
        {
            ids.Add(each.Id);
        }
        Assert.Equal(["disc_1", "disc_2"], ids);
        await perata.Discounts.DeleteAsync("disc_1");
        Assert.Equal(
            ["POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"],
            recorder.Requests.Select(seen => seen.Method + " " + seen.Url.AbsolutePath).ToArray());
        using var body = JsonDocument.Parse(recorder.Requests[0].Body!);
        Assert.Equal(1000, body.RootElement.GetProperty("basis_points").GetInt32());
    }

    [Fact]
    public async Task AFreeFormValueDecodesNested()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"id":"cus_1","showcase_id":"shw_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}}"""));
        var grant = (await Client(recorder).Customers.GetStateAsync("cus_1")).GrantedBenefits[0];
        var limits = grant.BenefitMetadata["flags"].GetProperty("limits");
        Assert.True(grant.BenefitMetadata["flags"].GetProperty("beta").GetBoolean());
        Assert.Equal(5, limits.GetProperty("seats").GetInt32());
        var tiers = limits.GetProperty("tiers").EnumerateArray().ToArray();
        Assert.Equal("a", tiers[0].GetString());
        Assert.Equal(2, tiers[1].GetInt32());
        Assert.Equal(JsonValueKind.Null, tiers[2].ValueKind);
        Assert.Equal(1.5, tiers[3].GetDouble());
        var link = grant.Properties["links"][0];
        Assert.Equal("https://example.com", link.GetProperty("url").GetString());
        Assert.Equal(JsonValueKind.Null, link.GetProperty("expires").ValueKind);
    }

    [Fact]
    public async Task APostWithoutAKeyIsSentWithItsOwnAGetWithNone()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.Created, $$"""{"data":{{ProductJson("prod_1")}}}"""));
        var perata = Client(recorder);
        await perata.Products.CreateAsync(new ProductsCreateParams { Name = "Curso" });
        await perata.Products.CreateAsync(new ProductsCreateParams { Name = "Curso" });
        await perata.Products.CreateAsync(new ProductsCreateParams { Name = "Curso" }, new RequestOptions { IdempotencyKey = "mine" });
        await perata.Products.GetAsync("prod_1");
        var keys = recorder.Requests.Select(seen => seen.Headers.GetValueOrDefault("Idempotency-Key")).ToArray();
        var uuid = @"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$";
        Assert.Matches(uuid, keys[0]!);
        Assert.Matches(uuid, keys[1]!);
        Assert.NotEqual(keys[0], keys[1]);
        Assert.Equal("mine", keys[2]);
        Assert.Null(keys[3]);
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
    public async Task AMetadataFilterIsSentAsOnePairAKeyTheKeysSortedAndEscaped()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"items":[],"pagination":{"total_count":0,"max_page":1}}}"""));
        var metadata = new Dictionary<string, string> { ["pedido"] = "123", ["camera id"] = "a/b" };
        await Client(recorder).Orders.ListAsync(new OrdersListParams { ClientReferenceId = "pedido-1", Metadata = metadata });
        Assert.Equal("?client_reference_id=pedido-1&metadata%5Bcamera%20id%5D=a%2Fb&metadata%5Bpedido%5D=123", recorder.Requests[0].Url.Query);
        await foreach (var _ in Client(recorder).Checkouts.ListIterAsync(new CheckoutsListParams { Limit = 1, Metadata = metadata }))
        {
            Assert.Fail("an empty page has no items");
        }
        Assert.Equal("?page=1&limit=1&metadata%5Bcamera%20id%5D=a%2Fb&metadata%5Bpedido%5D=123", recorder.Requests[1].Url.Query);
    }

    [Fact]
    public async Task CustomersAreListedByEmail()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"items":[],"pagination":{"total_count":0,"max_page":1}}}"""));
        await Client(recorder).Customers.ListAsync(new CustomersListParams { Email = "ana@example.com" });
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal("/api/v1/customers", seen.Url.AbsolutePath);
        Assert.Equal("?email=ana%40example.com", seen.Url.Query);
    }

    [Fact]
    public async Task UsageIngestionCarriesTheSourceCredentialAndItsEvents()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"created":1,"replayed":0}}"""));
        var usage = new PerataClient("pus_live_source", new PerataClientOptions { BaseUrl = "https://perata.test/", Handler = recorder });
        var receipt = await usage.Usage.IngestAsync(new UsageIngestParams
        {
            Events =
            [
                new UsageIngestEvent
                {
                    CustomerId = "cus_1", ExternalEventId = "req-1", InputTokens = "1200", OutputTokens = "300", CachedTokens = "0",
                    OccurredAt = "2026-11-13T12:00:00Z", Cost = new UsageIngestEventCost { Amount = "1.250000", Currency = "brl" },
                },
            ],
        });
        Assert.Equal(1, receipt.Created);
        Assert.Equal(0, receipt.Replayed);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Post, seen.Method);
        Assert.Equal("/api/v1/usage/token-events", seen.Url.AbsolutePath);
        Assert.Equal("Bearer pus_live_source", seen.Headers["Authorization"]);
        using var sent = JsonDocument.Parse(seen.Body!);
        var events = sent.RootElement.GetProperty("events");
        Assert.Equal(1, events.GetArrayLength());
        var first = events[0];
        Assert.Equal("cus_1", first.GetProperty("customer_id").GetString());
        Assert.Equal("1.250000", first.GetProperty("_cost").GetProperty("amount").GetString());
        Assert.Equal("brl", first.GetProperty("_cost").GetProperty("currency").GetString());
        Assert.False(first.TryGetProperty("_llm", out _));
        Assert.False(first.TryGetProperty("parent_id", out _));
    }

    [Theory]
    [InlineData(401, """{"error":"invalid_credential"}""", "invalid_credential", 0, "")]
    [InlineData(409, """{"error":"conflict","record":2,"message":"conflict"}""", "conflict", 2, "conflict")]
    [InlineData(422, """{"error":"invalid_request","record":3,"message":"validation failed: customer_id","fields":{"customer_id":["unknown"]}}""", "invalid_request", 3, "validation failed: customer_id")]
    [InlineData(400, """{"error":"invalid_request","message":"malformed JSON"}""", "invalid_request", 0, "malformed JSON")]
    [InlineData(415, """{"error":"unsupported_media_type"}""", "unsupported_media_type", 0, "")]
    [InlineData(500, """{"error":"unavailable"}""", "unavailable", 0, "")]
    [InlineData(409, """{"data":{"error":"event_conflict","record":2,"message":"conflict"}}""", "event_conflict", 2, "conflict")]
    public async Task UsageIngestionErrorsAreTheFlatErrorDocument(int status, string body, string code, int record, string message)
    {
        var recorder = new Recorder(_ => new Answer((HttpStatusCode)status, body));
        var usage = new PerataClient("pus_test_source", new PerataClientOptions { BaseUrl = "https://perata.test/", Handler = recorder });
        var refused = await Assert.ThrowsAsync<PerataException>(() => usage.Usage.IngestAsync(new UsageIngestParams
        {
            Events = [new UsageIngestEvent { CustomerId = "cus_1", ExternalEventId = "req-1", InputTokens = "1", OutputTokens = "0", CachedTokens = "0", OccurredAt = "2026-11-13T12:00:00Z" }],
        }));
        Assert.Equal(status, refused.Status);
        Assert.Equal(code, refused.Code);
        Assert.Equal(record, refused.Record);
        Assert.Equal(message, refused.ApiMessage);
        if (status == 422)
        {
            Assert.Equal(["unknown"], refused.Fields["customer_id"]);
        }
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

    // The webhook vectors every SDK checks: Standard Webhooks' own example, and
    // Peráta events signed under two secrets, as while one is rotated.
    private const string ReferenceSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    private const string OldSecret = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
    private const string NewSecret = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
    private const string OrderPaid = """{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}""";
    private const string UsageRecorded = """{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}""";
    private const string OrderPaidLive = """{"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}""";
    private const string PayoutSentTest = """{"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","environment":"test","data":{"payout_id":"po_1","amount_cents":5000}}""";
    private const string PayoutSent = """{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}""";
    private const long SignedAt = 1792670400;

    private static Dictionary<string, string> WebhookHeaders(string id, long at, string signature) => new()
    {
        ["Webhook-Id"] = id,
        ["webhook-timestamp"] = at.ToString(System.Globalization.CultureInfo.InvariantCulture),
        ["webhook-signature"] = signature,
    };

    [Fact]
    public void TheStandardWebhooksVectorVerifies()
    {
        var body = Encoding.UTF8.GetBytes("""{"test": 2432232314}""");
        var headers = WebhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
        var at = DateTimeOffset.FromUnixTimeSeconds(1614265330);
        Webhook.VerifySignature(ReferenceSecret, headers, body, at);
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(ReferenceSecret, headers, [.. body, (byte)' '], at));
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(ReferenceSecret, headers, body, at.AddSeconds(301)));
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(NewSecret, headers, body, at));
    }

    [Theory]
    [InlineData("+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8=")]
    [InlineData("\u00b2", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY=")]
    [InlineData("", "x")]
    [InlineData("1_6", "x")]
    public void ATimestampThatIsNotPlainDigitsIsRefused(string stamp, string signature)
    {
        var headers = WebhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 0, "v1," + signature);
        headers["webhook-timestamp"] = stamp;
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(ReferenceSecret, headers, "{\"test\": 2432232314}"u8.ToArray(), DateTimeOffset.FromUnixTimeSeconds(1614265330)));
    }

    [Fact]
    public void AWebhookCarriesTheEnvironmentItHappenedIn()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(SignedAt + 120);
        foreach (var (id, signature, body) in new[] { ("msg_2", "v1,F6yjAk5yoz2jK2Q70MVlMG2eFKNVM17nIhiWKfmjCzc= v1,npiewgDGHvzxB3L7ys4KBiP2hooWdiMkdW2tPNyOv/8=", OrderPaid), ("msg_3", "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=", UsageRecorded), ("msg_4", "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=", PayoutSent) })
        {
            Assert.Equal("", Webhook.Verify(NewSecret, WebhookHeaders(id, SignedAt, signature), body, now).Environment);
            Assert.Equal("", Webhook.Verify(NewSecret, WebhookHeaders(id, SignedAt, signature), body, now).ShowcaseId);
        }
        var order = Assert.IsType<OrderWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_5", SignedAt, "v1,uz6PnD5ymh2ny+f3isuMCyoYJ/B1du6G21/9CW1HB7I="), OrderPaidLive, now));
        Assert.Equal("live", order.Environment);
        Assert.Equal("shw_1", order.ShowcaseId);
        Assert.Equal("shw_1", order.Data.ShowcaseId);
        var unknown = Assert.IsType<UnknownWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_6", SignedAt, "v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM="), PayoutSentTest, now));
        Assert.Equal("test", unknown.Environment);
        Assert.Equal("", unknown.ShowcaseId);
    }

    [Fact]
    public void AWebhookAnswersItsTypedEvent()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(SignedAt + 120);
        var headers = WebhookHeaders("msg_2", SignedAt, "v1,F6yjAk5yoz2jK2Q70MVlMG2eFKNVM17nIhiWKfmjCzc= v1,npiewgDGHvzxB3L7ys4KBiP2hooWdiMkdW2tPNyOv/8=");
        foreach (var secret in new[] { NewSecret, OldSecret })
        {
            var order = Assert.IsType<OrderWebhookEvent>(Webhook.Verify(secret, headers, OrderPaid, now));
            Assert.Equal(("order.paid", "ord_1", 3L, 360L), (order.Type, order.Data.Id, order.Data.Installments, order.Data.InstallmentInterestCents));
        }
        Assert.Throws<WebhookVerificationException>(() => Webhook.Verify(ReferenceSecret, headers, OrderPaid, now));
        var usage = Assert.IsType<IdentifiersWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_3", SignedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), UsageRecorded, now));
        Assert.Equal(("msg_3", "mer_1"), (usage.Id, usage.Data["merchant_id"]));
        var unknown = Assert.IsType<UnknownWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_4", SignedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), PayoutSent, now));
        Assert.Equal("payout.sent", unknown.Type);
        Assert.Equal("po_1", unknown.Data.GetProperty("payout_id").GetString());
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
        var landed = false;
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
                if (context.Request.RawUrl!.EndsWith("/moved", StringComparison.Ordinal))
                {
                    context.Response.StatusCode = 302;
                    context.Response.AddHeader("Location", prefix + "api/v1/products/landed");
                    answer = "{}";
                }
                else if (context.Request.RawUrl.EndsWith("/landed", StringComparison.Ordinal))
                {
                    landed = true;
                    answer = "{}";
                }
                else if (context.Request.Headers["Authorization"] != "Bearer prk_test_key")
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
                        ["showcase_id"] = "shw_1",
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

            var redirected = await Assert.ThrowsAsync<PerataException>(() =>
                new PerataClient("prk_test_key", new PerataClientOptions { BaseUrl = prefix }).Products.GetAsync("moved"));
            Assert.Equal(302, redirected.Status);
            Assert.False(landed, "a redirect was followed");
        }
        finally
        {
            listener.Stop();
            await serving;
        }
    }
}
