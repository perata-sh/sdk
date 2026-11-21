package sh.perata;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.Test;

class PerataTest {
    /** Answers every request with what answer says, recording what was sent. */
    private static final class Recorder implements Transport {
        final List<Request> seen = new ArrayList<>();
        private final Function<Request, Response> answer;

        Recorder(Function<Request, Response> answer) {
            this.answer = answer;
        }

        @Override
        public Response send(Request request) {
            seen.add(request);
            return answer.apply(request);
        }
    }

    private static Perata client(Recorder recorder) {
        return Perata.builder("prk_test_key").baseUrl("https://perata.test/").transport(recorder).build();
    }

    private static Transport.Response json(int status, Map<String, String> headers, Object payload) {
        byte[] body = payload == null ? new byte[0] : Json.write(payload).getBytes(StandardCharsets.UTF_8);
        return new Transport.Response(status, headers, body);
    }

    private static Map<String, Object> product(String id) {
        Map<String, Object> product = new LinkedHashMap<>();
        product.put("id", id);
        product.put("name", "Curso");
        product.put("description", "");
        product.put("status", "active");
        product.put("showcase_id", "shw_1");
        product.put("created_at", "2026-10-17T00:00:00Z");
        return product;
    }

    private static Map<String, Object> data(Object value) {
        return Map.of("data", value);
    }

    private static Map<String, String> query(String url) {
        Map<String, String> query = new HashMap<>();
        String raw = URI.create(url).getRawQuery();
        if (raw != null) {
            for (String pair : raw.split("&")) {
                String[] parts = pair.split("=", 2);
                query.put(parts[0], parts.length > 1 ? parts[1] : "");
            }
        }
        return query;
    }

    @Test
    void aCallCarriesTheKeyAndUnwrapsTheData() {
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(product("prod_1"))));
        Product got = client(recorder).products().get("prod_1");
        assertEquals("prod_1", got.getId());
        assertEquals(Product.STATUS_ACTIVE, got.getStatus());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("GET", seen.getMethod());
        assertEquals("/api/v1/products/prod_1", URI.create(seen.getUrl()).getPath());
        assertEquals("Bearer prk_test_key", seen.getHeaders().get("Authorization"));
        assertEquals("perata-java/" + Perata.VERSION, seen.getHeaders().get("User-Agent"));
    }

    @Test
    void aWriteSendsItsBodyAndIdempotencyKey() {
        Recorder recorder = new Recorder(request -> json(201, Map.of(), data(product("prod_1"))));
        client(recorder).products().create(
                ProductsService.CreateParams.builder().name("Curso").build(),
                RequestOptions.builder().idempotencyKey("create-1").build());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("POST", seen.getMethod());
        assertEquals("create-1", seen.getHeaders().get("Idempotency-Key"));
        assertEquals("application/json", seen.getHeaders().get("Content-Type"));
        assertEquals(Map.of("name", "Curso"), Json.parse(new String(seen.getBody(), StandardCharsets.UTF_8)));
    }

    private static Map<String, Object> session(String clientSecret) {
        Map<String, Object> session = new LinkedHashMap<>();
        session.put("id", "pcl_1");
        session.put("url", "https://perata.sh/pagamento/pcl_1");
        session.put("product_id", "prod_1");
        session.put("price_id", "price_1");
        session.put("status", "active");
        session.put("label", "");
        session.put("notify_customer_email", true);
        session.put("renewal_mode", "");
        session.put("quantity", 1);
        session.put("success_url", "https://loja.example/obrigado");
        session.put("cancel_url", "");
        session.put("expires_at", null);
        session.put("created_at", "2026-11-16T12:00:00Z");
        session.put("session_id", "cs_1");
        session.put("client_secret", clientSecret);
        session.put("client_secret_expires_at", "2026-11-16T12:30:00Z");
        session.put("status_key", "sk_1");
        session.put("amount_cents", null);
        session.put("items", java.util.List.of());
        session.put("metadata", java.util.Map.of());
        session.put("client_reference_id", "");
        session.put("discount_id", "");
        session.put("showcase_id", "shw_1");
        session.put("subscription_start_at", null);
        return session;
    }

    @Test
    void aCheckoutSessionHandsBackTheClientSecretForTheBrowser() {
        int[] calls = {0};
        Recorder recorder = new Recorder(request -> calls[0]++ == 0
                ? json(201, Map.of(), data(session("cs_secret_1")))
                : json(201, Map.of("Idempotent-Replayed", "true"), data(session(""))));
        Perata perata = client(recorder);
        CheckoutsService.CreateParams params = CheckoutsService.CreateParams.builder()
                .productId("prod_1").priceId("price_1").successUrl("https://loja.example/obrigado").build();
        RequestOptions options = RequestOptions.builder().idempotencyKey("pedido-1").build();
        CheckoutCreated checkout = perata.checkouts().create(params, options);
        assertEquals("cs_secret_1", checkout.getClientSecret());
        assertEquals("cs_1", checkout.getSessionId());
        assertEquals("sk_1", checkout.getStatusKey());
        assertEquals("2026-11-16T12:30:00Z", checkout.getClientSecretExpiresAt());
        assertEquals("https://perata.sh/pagamento/pcl_1", checkout.getUrl());
        assertNull(checkout.getExpiresAt());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("POST", seen.getMethod());
        assertEquals("/api/v1/checkouts", URI.create(seen.getUrl()).getPath());
        assertEquals("pedido-1", seen.getHeaders().get("Idempotency-Key"));
        assertEquals(
                Map.of("product_id", "prod_1", "price_id", "price_1", "success_url", "https://loja.example/obrigado"),
                Json.parse(new String(seen.getBody(), StandardCharsets.UTF_8)));
        CheckoutCreated again = perata.checkouts().create(params, options);
        assertEquals("", again.getClientSecret());
        assertEquals("cs_1", again.getSessionId());
    }

    @Test
    void aModelThatMayBeNullDecodesBothWays() {
        Map<String, Object> pix = new LinkedHashMap<>();
        pix.put("copia_e_cola", "000201");
        pix.put("qr_code_svg", "<svg/>");
        pix.put("expires_at", null);
        Map<String, Object> payment = new LinkedHashMap<>();
        payment.put("id", "pay_1");
        payment.put("method", "pix");
        payment.put("state", "pending");
        payment.put("unresolved", false);
        payment.put("card_brand", "");
        payment.put("card_kind", "");
        payment.put("installments", 1L);
        payment.put("pix", pix);
        payment.put("boleto", null);
        CheckoutClientPayment got = CheckoutClientPayment.fromJson(payment);
        assertNull(got.getBoleto());
        assertEquals("000201", got.getPix().getCopiaECola());
        assertNull(got.getPix().getExpiresAt());
    }

    @Test
    void aBaseUrlMustBeHttpsUnlessItIsLoopback() {
        for (String base : List.of("https://perata.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080")) {
            Perata.builder("k").baseUrl(base).build();
        }
        for (String base : List.of("http://perata.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "perata.sh", "", "http://[::2]", "http://127.0.0.300")) {
            IllegalArgumentException refused = assertThrows(IllegalArgumentException.class, () -> Perata.builder("k").baseUrl(base).build(), base);
            assertTrue(refused.getMessage().contains("must be https"));
        }
    }

    @Test
    void aDiscountGoesThroughCreateGetListAndDelete() {
        String template = "{\"id\":\"__ID__\",\"name\":\"Black\",\"code\":null,\"type\":\"percentage\",\"basis_points\":1000,\"amount_cents\":0,\"currency\":\"BRL\",\"duration\":\"once\",\"duration_in_months\":0,\"max_redemptions\":null,\"max_redemptions_per_customer\":null,\"redemptions_count\":0,\"starts_at\":\"2026-10-17T00:00:00Z\",\"ends_at\":null,\"status\":\"active\",\"product_ids\":[\"prod_1\"],\"created_at\":\"2026-10-17T00:00:00Z\",\"modified_at\":\"2026-10-17T00:00:00Z\"}";
        Recorder recorder = new Recorder(request -> {
            if (request.getMethod().equals("POST")) {
                return json(201, Map.of(), data(Json.parse(template.replace("__ID__", "disc_1"))));
            }
            if (request.getMethod().equals("DELETE")) {
                return json(204, Map.of(), null);
            }
            if (URI.create(request.getUrl()).getPath().equals("/api/v1/discounts")) {
                String page = query(request.getUrl()).get("page");
                return json(200, Map.of(), data(Map.of(
                        "items", List.of(Json.parse(template.replace("__ID__", "disc_" + page))),
                        "pagination", Map.of("total_count", 2, "max_page", 2))));
            }
            return json(200, Map.of(), data(Json.parse(template.replace("__ID__", "disc_1"))));
        });
        Perata perata = client(recorder);
        Discount created = perata.discounts().create(DiscountsService.CreateParams.builder().name("Black").type("percentage").duration("once").basisPoints(1000L).build());
        assertEquals("disc_1", created.getId());
        assertNull(created.getCode());
        assertEquals(List.of("prod_1"), created.getProductIds());
        assertEquals("Black", perata.discounts().get("disc_1").getName());
        List<String> ids = new ArrayList<>();
        for (Discount each : perata.discounts().listIter(DiscountsService.ListParams.builder().limit(1).build())) {
            ids.add(each.getId());
        }
        assertEquals(List.of("disc_1", "disc_2"), ids);
        perata.discounts().delete("disc_1");
        List<String> requests = new ArrayList<>();
        for (Transport.Request each : recorder.seen) {
            requests.add(each.getMethod() + " " + URI.create(each.getUrl()).getPath());
        }
        assertEquals(List.of("POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"), requests);
        assertEquals(Map.of("name", "Black", "type", "percentage", "duration", "once", "basis_points", 1000L), Json.parse(new String(recorder.seen.get(0).getBody(), StandardCharsets.UTF_8)));
    }

    @Test
    void aFreeFormValueDecodesNested() {
        String state = "{\"id\":\"cus_1\",\"showcase_id\":\"shw_1\",\"name\":\"Ana\",\"email\":\"ana@example.com\",\"external_id\":\"\",\"status\":\"active\",\"created_at\":\"2026-10-17T00:00:00Z\",\"active_subscriptions\":[],\"granted_benefits\":[{\"id\":\"gr_1\",\"granted_at\":\"2026-10-17T00:00:00Z\",\"benefit_id\":\"ben_1\",\"benefit_type\":\"feature_flag\",\"benefit_metadata\":{\"flags\":{\"beta\":true,\"limits\":{\"seats\":5,\"tiers\":[\"a\",2,null,1.5]}}},\"properties\":{\"links\":[{\"url\":\"https://example.com\",\"expires\":null}]}}]}";
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(Json.parse(state))));
        CustomerStateBenefitGrant grant = client(recorder).customers().getState("cus_1").getGrantedBenefits().get(0);
        Map<?, ?> flags = (Map<?, ?>) grant.getBenefitMetadata().get("flags");
        Map<?, ?> limits = (Map<?, ?>) flags.get("limits");
        assertEquals(true, flags.get("beta"));
        assertEquals(5L, limits.get("seats"));
        assertEquals(java.util.Arrays.asList("a", 2L, null, 1.5), limits.get("tiers"));
        Map<?, ?> link = (Map<?, ?>) ((List<?>) grant.getProperties().get("links")).get(0);
        assertEquals("https://example.com", link.get("url"));
        assertTrue(link.containsKey("expires") && link.get("expires") == null);
    }

    @Test
    void aPostWithoutAKeyIsSentWithItsOwnAGetWithNone() {
        Recorder recorder = new Recorder(request -> json(201, Map.of(), data(product("prod_1"))));
        Perata perata = client(recorder);
        ProductsService.CreateParams params = ProductsService.CreateParams.builder().name("Curso").build();
        perata.products().create(params);
        perata.products().create(params);
        perata.products().create(params, RequestOptions.builder().idempotencyKey("mine").build());
        perata.products().get("prod_1");
        String uuid = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
        String first = recorder.seen.get(0).getHeaders().get("Idempotency-Key");
        String second = recorder.seen.get(1).getHeaders().get("Idempotency-Key");
        assertTrue(first.matches(uuid) && second.matches(uuid), first + " " + second);
        assertNotEquals(first, second);
        assertEquals("mine", recorder.seen.get(2).getHeaders().get("Idempotency-Key"));
        assertNull(recorder.seen.get(3).getHeaders().get("Idempotency-Key"));
    }

    @Test
    void iteratingWalksEveryPage() {
        Recorder recorder = new Recorder(request -> {
            String page = query(request.getUrl()).get("page");
            return json(200, Map.of(), data(Map.of(
                    "items", List.of(product("prod_" + page)),
                    "pagination", Map.of("total_count", 3, "max_page", 3))));
        });
        List<String> ids = new ArrayList<>();
        for (Product product : client(recorder).products().listIter(ProductsService.ListParams.builder().limit(1).build())) {
            ids.add(product.getId());
        }
        assertEquals(List.of("prod_1", "prod_2", "prod_3"), ids);
        assertEquals("1", query(recorder.seen.get(0).getUrl()).get("limit"));
    }

    @Test
    void aMetadataFilterIsSentAsOnePairAKeyTheKeysSortedAndEscaped() {
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(Map.of(
                "items", List.of(),
                "pagination", Map.of("total_count", 0, "max_page", 1)))));
        Map<String, String> metadata = Map.of("pedido", "123", "camera id", "a/b");
        client(recorder).orders().list(OrdersService.ListParams.builder().clientReferenceId("pedido-1").metadata(metadata).build());
        assertEquals(
                "client_reference_id=pedido-1&metadata%5Bcamera%20id%5D=a%2Fb&metadata%5Bpedido%5D=123",
                URI.create(recorder.seen.get(0).getUrl()).getRawQuery());
        for (Checkout ignored : client(recorder).checkouts().listIter(CheckoutsService.ListParams.builder().limit(1).metadata(metadata).build())) {
            throw new AssertionError("an empty page has no items");
        }
        assertEquals(
                "page=1&limit=1&metadata%5Bcamera%20id%5D=a%2Fb&metadata%5Bpedido%5D=123",
                URI.create(recorder.seen.get(1).getUrl()).getRawQuery());
    }

    @Test
    void customersAreListedByEmail() {
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(Map.of(
                "items", List.of(),
                "pagination", Map.of("total_count", 0, "max_page", 1)))));
        client(recorder).customers().list(CustomersService.ListParams.builder().email("ana@example.com").build());
        URI url = URI.create(recorder.seen.get(0).getUrl());
        assertEquals("/api/v1/customers", url.getPath());
        assertEquals("email=ana%40example.com", url.getRawQuery());
    }

    // A graduated price goes out with its tiers and without the fixed amount, and
    // a subscription reads back the quantity it bills and the order reference it
    // came from; amount_cents is the cycle's total for that quantity.
    @Test
    void aGraduatedPriceCarriesItsTiersAndASubscriptionItsQuantity() {
        String price = "{\"id\":\"price_1\",\"product_id\":\"prod_1\",\"type\":\"recurring\",\"interval\":\"month\",\"interval_count\":1,\"currency\":\"BRL\",\"status\":\"active\",\"amount_cents\":0,\"pricing_model\":\"graduated\",\"unit_amount_cents\":null,\"unit_label\":\"câmera\",\"unit_label_plural\":\"câmeras\",\"tiers\":[{\"up_to\":1,\"unit_amount_cents\":25000},{\"up_to\":null,\"unit_amount_cents\":15000}]}";
        String subscription = "{\"id\":\"sub_1\",\"label\":\"\",\"notify_customer_email\":true,\"renewal_mode\":\"manual\",\"amount_cents\":55000,\"cancel_at_period_end\":false,\"client_reference_id\":\"pedido-9\",\"currency\":\"BRL\",\"current_period_end\":\"2026-12-20T00:00:00Z\",\"current_period_start\":\"2026-11-20T00:00:00Z\",\"customer_id\":\"cus_1\",\"interval\":\"month\",\"metadata\":{\"camera\":\"c1\"},\"price_id\":\"price_1\",\"product_id\":\"prod_1\",\"quantity\":3,\"showcase_id\":\"shw_1\",\"status\":\"active\",\"suspended_at\":null,\"suspension_reason\":null,\"trial_end\":null,\"trial_start\":null}";
        Recorder recorder = new Recorder(request -> "POST".equals(request.getMethod())
                ? json(201, Map.of(), data(Json.parse(price)))
                : json(200, Map.of(), data(Json.parse(subscription))));
        Perata perata = client(recorder);
        Price created = perata.prices().create(PricesService.CreateParams.builder()
                .productId("prod_1").type("recurring").interval("month").pricingModel("graduated")
                .tiers(List.of(
                        PricesService.PricesCreateTier.builder().upTo(1L).unitAmountCents(25000L).build(),
                        PricesService.PricesCreateTier.builder().unitAmountCents(15000L).build()))
                .unitLabel("câmera").unitLabelPlural("câmeras")
                .build());
        assertEquals("/api/v1/prices", URI.create(recorder.seen.get(0).getUrl()).getPath());
        Map<String, Object> sent = Json.asObject(Json.parse(new String(recorder.seen.get(0).getBody(), StandardCharsets.UTF_8)));
        assertEquals("graduated", sent.get("pricing_model"));
        assertEquals(List.of(Map.of("up_to", 1L, "unit_amount_cents", 25000L), Map.of("unit_amount_cents", 15000L)), sent.get("tiers"));
        assertFalse(sent.containsKey("amount_cents"));
        assertEquals("graduated", created.getPricingModel());
        assertEquals(0L, created.getAmountCents());
        assertNull(created.getUnitAmountCents());
        assertEquals(2, created.getTiers().size());
        assertEquals(Long.valueOf(1), created.getTiers().get(0).getUpTo());
        assertNull(created.getTiers().get(1).getUpTo());
        assertEquals(15000L, created.getTiers().get(1).getUnitAmountCents());
        Subscription got = perata.subscriptions().get("sub_1");
        assertEquals("/api/v1/subscriptions/sub_1", URI.create(recorder.seen.get(1).getUrl()).getPath());
        assertEquals(3L, got.getQuantity());
        assertEquals(55000L, got.getAmountCents());
        assertEquals("pedido-9", got.getClientReferenceId());
    }

    // A checkout adds the buyer's remaining days to the first period, an
    // extension goes out alone (no price_id), and the sale reads back what it
    // took: the discount on the order and on the subscription, and the change
    // scheduled for the next period.
    @Test
    void aFirstPeriodExtensionAndTheDiscountsTheSaleReadsBack() {
        Map<String, String> answers = new HashMap<>();
        answers.put("POST /api/v1/checkouts", "{\"data\":{\"id\":\"pcl_1\",\"showcase_id\":\"x\",\"url\":\"x\",\"product_id\":\"prod_1\",\"price_id\":\"price_1\",\"status\":\"active\",\"label\":\"x\",\"quantity\":0,\"amount_cents\":null,\"items\":[],\"metadata\":{},\"client_reference_id\":\"x\",\"success_url\":\"x\",\"cancel_url\":\"x\",\"expires_at\":null,\"subscription_start_at\":null,\"discount_id\":\"disc_1\",\"first_period_extra_days\":30,\"renewal_mode\":\"manual\",\"notify_customer_email\":false,\"created_at\":\"2026-11-20T12:00:00Z\",\"session_id\":\"cs_1\",\"client_secret\":\"cs_secret_1\",\"client_secret_expires_at\":\"2026-11-20T12:00:00Z\",\"status_key\":\"x\"}}");
        answers.put("PATCH /api/v1/subscriptions/sub_1", "{\"data\":{\"id\":\"sub_1\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"status\":\"active\",\"amount_cents\":0,\"quantity\":0,\"currency\":\"BRL\",\"interval\":\"x\",\"current_period_start\":\"2026-11-20T12:00:00Z\",\"current_period_end\":\"2026-11-20T12:00:00Z\",\"cancel_at_period_end\":false,\"pending_update\":{\"price_id\":\"price_2\",\"quantity\":5,\"amount_cents\":90000,\"effective_at\":\"2026-12-20T03:00:00Z\"},\"suspended_at\":null,\"suspension_reason\":null,\"trial_start\":null,\"trial_end\":null,\"metadata\":{},\"client_reference_id\":\"x\",\"discount_id\":\"disc_1\",\"discount_ends_at\":\"2027-03-01T03:00:00Z\",\"first_period_extra_days\":30,\"renewal_mode\":\"manual\",\"label\":\"x\",\"notify_customer_email\":false}}");
        answers.put("GET /api/v1/subscriptions/sub_2", "{\"data\":{\"id\":\"sub_2\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"status\":\"active\",\"amount_cents\":0,\"quantity\":0,\"currency\":\"BRL\",\"interval\":\"x\",\"current_period_start\":\"2026-11-20T12:00:00Z\",\"current_period_end\":\"2026-11-20T12:00:00Z\",\"cancel_at_period_end\":false,\"pending_update\":null,\"suspended_at\":null,\"suspension_reason\":null,\"trial_start\":null,\"trial_end\":null,\"metadata\":{},\"client_reference_id\":\"x\",\"discount_id\":null,\"discount_ends_at\":null,\"first_period_extra_days\":null,\"renewal_mode\":\"manual\",\"label\":\"x\",\"notify_customer_email\":false}}");
        answers.put("GET /api/v1/orders/ord_1", "{\"data\":{\"id\":\"ord_1\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"amount_cents\":9000,\"currency\":\"BRL\",\"status\":\"open\",\"paid_at\":null,\"order_status\":null,\"refunded_amount_cents\":0,\"installments\":0,\"installment_interest_cents\":0,\"items\":[],\"metadata\":{},\"client_reference_id\":\"x\",\"subscription_id\":null,\"cycle_sequence\":null,\"period_start\":null,\"period_end\":null,\"discount_id\":\"disc_1\",\"discount_code\":\"BEMVINDO\",\"subtotal_cents\":10000,\"discount_cents\":1000}}");
        answers.put("GET /api/v1/prices/price_1", "{\"data\":{\"id\":\"price_1\",\"product_id\":\"prod_1\",\"currency\":\"BRL\",\"amount_cents\":9000,\"type\":\"one_time\",\"interval\":\"none\",\"interval_count\":0,\"pricing_model\":\"fixed\",\"unit_amount_cents\":null,\"tiers\":[],\"unit_label\":\"x\",\"unit_label_plural\":\"x\",\"minimum_units\":null,\"maximum_units\":null,\"status\":\"archived\"}}");
        Recorder recorder = new Recorder(request -> json("POST".equals(request.getMethod()) ? 201 : 200, Map.of(),
                Json.parse(answers.get(request.getMethod() + " " + URI.create(request.getUrl()).getPath()))));
        Perata perata = client(recorder);
        CheckoutCreated checkout = perata.checkouts().create(CheckoutsService.CreateParams.builder()
                .productId("prod_1").priceId("price_1").firstPeriodExtraDays(30L).build());
        Map<String, Object> created = Json.asObject(Json.parse(new String(recorder.seen.get(0).getBody(), StandardCharsets.UTF_8)));
        assertEquals(30L, created.get("first_period_extra_days"));
        assertEquals(Long.valueOf(30), checkout.getFirstPeriodExtraDays());
        assertEquals("disc_1", checkout.getDiscountId());
        Subscription subscription = perata.subscriptions().update("sub_1", SubscriptionsService.UpdateParams.builder().extendCurrentPeriodDays(15L).build());
        Map<String, Object> sent = Json.asObject(Json.parse(new String(recorder.seen.get(1).getBody(), StandardCharsets.UTF_8)));
        assertEquals("PATCH", recorder.seen.get(1).getMethod());
        assertEquals(15L, sent.get("extend_current_period_days"));
        assertFalse(sent.containsKey("price_id"));
        assertEquals(Long.valueOf(30), subscription.getFirstPeriodExtraDays());
        assertEquals("disc_1", subscription.getDiscountId());
        assertEquals("2027-03-01T03:00:00Z", subscription.getDiscountEndsAt());
        SubscriptionPendingUpdate pending = subscription.getPendingUpdate();
        assertEquals("price_2", pending.getPriceId());
        assertEquals(5L, pending.getQuantity());
        assertEquals(90000L, pending.getAmountCents());
        assertEquals("2026-12-20T03:00:00Z", pending.getEffectiveAt());
        Subscription none = perata.subscriptions().get("sub_2");
        assertNull(none.getPendingUpdate());
        assertNull(none.getFirstPeriodExtraDays());
        assertNull(none.getDiscountId());
        Order order = perata.orders().get("ord_1");
        assertEquals(10000L, order.getSubtotalCents());
        assertEquals(1000L, order.getDiscountCents());
        assertEquals("disc_1", order.getDiscountId());
        assertEquals("BEMVINDO", order.getDiscountCode());
        Price price = perata.prices().get("price_1");
        assertEquals("/api/v1/prices/price_1", URI.create(recorder.seen.get(4).getUrl()).getPath());
        assertEquals("archived", price.getStatus());
    }

    // The payment reads back its fee, its net, its split and the payout that pays it.
    @Test
    void aPaymentReadsBackItsFeeItsSplitAndItsPayout() {
        Recorder recorder = new Recorder(request -> json(200, Map.of(), Json.parse("{\"data\":{\"id\":\"pay_1\",\"showcase_id\":\"x\",\"checkout_id\":\"x\",\"customer_id\":\"x\",\"method\":\"card\",\"state\":\"unknown\",\"amount_cents\":0,\"captured_cents\":0,\"refunded_cents\":0,\"currency\":\"BRL\",\"created_at\":\"2026-11-20T12:00:00Z\",\"metadata\":{},\"client_reference_id\":\"x\",\"installments\":0,\"installment_amount_cents\":0,\"installment_interest_cents\":0,\"subscription_id\":null,\"cycle_sequence\":null,\"period_start\":null,\"period_end\":null,\"fee_cents\":450,\"net_cents\":8550,\"expected_payout_on\":\"2026-12-21\",\"payout_deposited_on\":null,\"payout_id\":null,\"split\":[{\"recipient_id\":\"shw_2\",\"amount_cents\":9000,\"fee_cents\":450,\"net_cents\":8550}]}}")));
        Payment payment = client(recorder).payments().get("pay_1");
        assertEquals(450L, payment.getFeeCents());
        assertEquals(8550L, payment.getNetCents());
        assertEquals("2026-12-21", payment.getExpectedPayoutOn());
        assertNull(payment.getPayoutId());
        assertNull(payment.getPayoutDepositedOn());
        assertEquals(1, payment.getSplit().size());
        assertEquals("shw_2", payment.getSplit().get(0).getRecipientId());
        assertEquals(9000L, payment.getSplit().get(0).getAmountCents());
        assertEquals(450L, payment.getSplit().get(0).getFeeCents());
        assertEquals(8550L, payment.getSplit().get(0).getNetCents());
    }

    // The balance carries its period, the payouts are filtered and walked page by
    // page, and a payout reads back its lines: a fee has no payment.
    @Test
    void theBalanceAndThePayoutsReadBackWhatWillBeDeposited() {
        Recorder recorder = new Recorder(request -> {
            String path = URI.create(request.getUrl()).getPath();
            String raw = URI.create(request.getUrl()).getRawQuery();
            String body = "{\"data\":{\"items\":[{\"id\":\"po_20261120\",\"status\":\"deposited\",\"expected_on\":\"2026-11-20\",\"deposited_on\":\"2026-11-20\",\"amount_cents\":10000,\"fee_cents\":450,\"net_cents\":9550,\"currency\":\"BRL\",\"item_count\":2}],\"pagination\":{\"total_count\":2,\"max_page\":2}}}";
            if (path.equals("/api/v1/balance")) {
                body = "{\"data\":{\"total_to_receive_cents\":100000,\"released_cents\":10000,\"held_cents\":5000,\"scheduled_cents\":60000,\"later_cents\":25000,\"deposited_cents\":42000,\"period_from\":\"2026-11-01\",\"period_to\":\"2026-11-20\",\"currency\":\"BRL\"}}";
            } else if (path.equals("/api/v1/payouts/po_20261120")) {
                body = "{\"data\":{\"id\":\"po_20261120\",\"status\":\"deposited\",\"expected_on\":\"2026-11-20\",\"deposited_on\":\"2026-11-20\",\"amount_cents\":10000,\"fee_cents\":450,\"net_cents\":9550,\"currency\":\"BRL\",\"item_count\":2,\"items\":[{\"kind\":\"sale\",\"payment_id\":\"pay_1\",\"installment\":1,\"status\":\"deposited\",\"amount_cents\":10000,\"fee_cents\":300,\"net_cents\":9700},{\"kind\":\"fee\",\"payment_id\":null,\"installment\":0,\"status\":\"deposited\",\"amount_cents\":0,\"fee_cents\":150,\"net_cents\":-150}]}}";
            } else if (raw != null && raw.contains("page=2")) {
                body = "{\"data\":{\"items\":[{\"id\":\"po_20261119\",\"status\":\"released\",\"expected_on\":\"2026-11-19\",\"deposited_on\":null,\"amount_cents\":5000,\"fee_cents\":200,\"net_cents\":4800,\"currency\":\"BRL\",\"item_count\":2}],\"pagination\":{\"total_count\":2,\"max_page\":2}}}";
            }
            return json(200, Map.of(), Json.parse(body));
        });
        Perata perata = client(recorder);
        Balance balance = perata.balance().get(BalanceService.GetParams.builder().dateFrom("2026-11-01").dateTo("2026-11-20").build());
        assertEquals(Map.of("date_from", "2026-11-01", "date_to", "2026-11-20"), query(recorder.seen.get(0).getUrl()));
        assertEquals(100000L, balance.getTotalToReceiveCents());
        assertEquals(balance.getTotalToReceiveCents(), balance.getReleasedCents() + balance.getHeldCents() + balance.getScheduledCents() + balance.getLaterCents());
        assertEquals(42000L, balance.getDepositedCents());
        assertEquals("2026-11-01", balance.getPeriodFrom());
        assertEquals("2026-11-20", balance.getPeriodTo());
        assertEquals("BRL", balance.getCurrency());
        List<String> walked = new ArrayList<>();
        for (Payout payout : perata.payouts().listIter(PayoutsService.ListParams.builder().status("deposited").dateFrom("2026-11-01").sorting("-date").limit(1).build())) {
            walked.add(payout.getId() + ":" + payout.getStatus());
            assertEquals(payout.getAmountCents() - payout.getFeeCents(), payout.getNetCents());
            assertEquals("deposited".equals(payout.getStatus()), payout.getDepositedOn() != null);
        }
        assertEquals(List.of("po_20261120:deposited", "po_20261119:released"), walked);
        assertEquals(Map.of("page", "1", "limit", "1", "status", "deposited", "date_from", "2026-11-01", "sorting", "-date"), query(recorder.seen.get(1).getUrl()));
        PayoutDetail payout = perata.payouts().get("po_20261120");
        assertEquals(9550L, payout.getNetCents());
        assertEquals(2, payout.getItems().size());
        PayoutItem sale = payout.getItems().get(0);
        assertEquals("sale", sale.getKind());
        assertEquals("pay_1", sale.getPaymentId());
        assertEquals(1L, sale.getInstallment());
        assertEquals(9700L, sale.getNetCents());
        PayoutItem fee = payout.getItems().get(1);
        assertEquals("fee", fee.getKind());
        assertNull(fee.getPaymentId());
        assertEquals(-150L, fee.getNetCents());
    }

    // A checkout says how its subscription renews, the subscription reads back the
    // mode it resolved to, its label and whether the buyer is written to, an update
    // changes them, and the open renewal charge is read by its own route; without
    // one the API answers 404 no_open_charge.
    @Test
    void theRenewalModeTheLabelAndTheOpenCharge() {
        Map<String, String> answers = new HashMap<>();
        answers.put("POST /api/v1/checkouts", "{\"data\":{\"id\":\"pcl_1\",\"showcase_id\":\"x\",\"url\":\"x\",\"product_id\":\"prod_1\",\"price_id\":\"price_1\",\"status\":\"active\",\"label\":\"Olho de Águia · Ana\",\"quantity\":0,\"amount_cents\":null,\"items\":[],\"metadata\":{},\"client_reference_id\":\"x\",\"success_url\":\"x\",\"cancel_url\":\"x\",\"expires_at\":null,\"subscription_start_at\":null,\"discount_id\":\"x\",\"first_period_extra_days\":null,\"renewal_mode\":\"automatic\",\"notify_customer_email\":false,\"created_at\":\"2026-11-20T12:00:00Z\",\"session_id\":\"cs_1\",\"client_secret\":\"cs_secret_1\",\"client_secret_expires_at\":\"2026-11-20T12:00:00Z\",\"status_key\":\"x\"}}");
        answers.put("PATCH /api/v1/subscriptions/sub_1", "{\"data\":{\"id\":\"sub_1\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"status\":\"active\",\"amount_cents\":0,\"quantity\":0,\"currency\":\"BRL\",\"interval\":\"x\",\"current_period_start\":\"2026-11-20T12:00:00Z\",\"current_period_end\":\"2026-11-20T12:00:00Z\",\"cancel_at_period_end\":false,\"pending_update\":null,\"suspended_at\":null,\"suspension_reason\":null,\"trial_start\":null,\"trial_end\":null,\"metadata\":{},\"client_reference_id\":\"x\",\"discount_id\":null,\"discount_ends_at\":null,\"first_period_extra_days\":null,\"renewal_mode\":\"pix_automatic\",\"label\":\"Olho de Águia · Ana\",\"notify_customer_email\":false}}");
        answers.put("GET /api/v1/subscriptions/sub_1/open-charge", "{\"data\":{\"id\":\"rc_1\",\"subscription_id\":\"sub_1\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"cycle_sequence\":2,\"amount_cents\":9000,\"currency\":\"BRL\",\"label\":\"Olho de Águia · Ana\",\"renewal_mode\":\"manual\",\"period_start\":\"2026-11-20T12:00:00Z\",\"period_end\":\"2026-11-20T12:00:00Z\",\"due_at\":\"2026-12-20T03:00:00Z\",\"expires_at\":\"2026-12-27T03:00:00Z\",\"payment_url\":\"https://perata.sh/pagar/rc_1\",\"metadata\":{},\"client_reference_id\":\"x\",\"reminder\":null,\"days_until_due\":null,\"notify_customer_email\":true}}");
        Recorder recorder = new Recorder(request -> {
            String body = answers.get(request.getMethod() + " " + URI.create(request.getUrl()).getPath());
            if (body == null) {
                return json(404, Map.of(), Map.of("error", "no_open_charge", "message", "A assinatura não tem cobrança de renovação em aberto."));
            }
            return json("POST".equals(request.getMethod()) ? 201 : 200, Map.of(), Json.parse(body));
        });
        Perata perata = client(recorder);
        String label = "Olho de Águia · Ana";
        CheckoutCreated checkout = perata.checkouts().create(CheckoutsService.CreateParams.builder()
                .productId("prod_1").priceId("price_1").renewalMode("automatic").notifyCustomerEmail(false).label(label).build());
        Map<String, Object> sent = Json.asObject(Json.parse(new String(recorder.seen.get(0).getBody(), StandardCharsets.UTF_8)));
        assertEquals("automatic", sent.get("renewal_mode"));
        assertEquals(false, sent.get("notify_customer_email"));
        assertEquals(label, sent.get("label"));
        assertEquals("automatic", checkout.getRenewalMode());
        assertFalse(checkout.getNotifyCustomerEmail());
        assertEquals(label, checkout.getLabel());
        Subscription subscription = perata.subscriptions().update("sub_1",
                SubscriptionsService.UpdateParams.builder().renewalMode("manual").notifyCustomerEmail(true).label(label).build());
        sent = Json.asObject(Json.parse(new String(recorder.seen.get(1).getBody(), StandardCharsets.UTF_8)));
        assertEquals("manual", sent.get("renewal_mode"));
        assertEquals(true, sent.get("notify_customer_email"));
        assertEquals(label, sent.get("label"));
        assertEquals("pix_automatic", subscription.getRenewalMode());
        assertEquals(label, subscription.getLabel());
        assertFalse(subscription.getNotifyCustomerEmail());
        RenewalCharge charge = perata.subscriptions().getOpenCharge("sub_1");
        assertEquals("/api/v1/subscriptions/sub_1/open-charge", URI.create(recorder.seen.get(2).getUrl()).getPath());
        assertEquals("rc_1", charge.getId());
        assertEquals("sub_1", charge.getSubscriptionId());
        assertEquals(9000L, charge.getAmountCents());
        assertEquals("manual", charge.getRenewalMode());
        assertEquals("https://perata.sh/pagar/rc_1", charge.getPaymentUrl());
        assertEquals("2026-12-20T03:00:00Z", charge.getDueAt());
        assertEquals("2026-12-27T03:00:00Z", charge.getExpiresAt());
        assertNull(charge.getReminder());
        assertNull(charge.getDaysUntilDue());
        assertTrue(charge.getNotifyCustomerEmail());
        PerataException refused = assertThrows(PerataException.class, () -> perata.subscriptions().getOpenCharge("sub_2"));
        assertEquals(404, refused.getStatus());
        assertEquals("no_open_charge", refused.getCode());
    }

    // The renewal events carry the charge: due, and the reminder with its days.
    @Test
    void theRenewalEventsCarryTheCharge() {
        Instant now = Instant.ofEpochSecond(SIGNED_AT + 120);
        WebhookEvent due = Webhook.verify(NEW_SECRET, webhookHeaders("msg_7", SIGNED_AT, "v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w="),
                "{\"id\":\"msg_7\",\"type\":\"subscription.renewal_due\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"id\":\"rc_1\",\"subscription_id\":\"sub_1\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"cycle_sequence\":2,\"amount_cents\":9000,\"currency\":\"BRL\",\"label\":\"Olho de Águia · Ana\",\"renewal_mode\":\"manual\",\"period_start\":\"2026-11-20T12:00:00Z\",\"period_end\":\"2026-11-20T12:00:00Z\",\"due_at\":\"2026-12-20T03:00:00Z\",\"expires_at\":\"2026-12-27T03:00:00Z\",\"payment_url\":\"https://perata.sh/pagar/rc_1\",\"metadata\":{},\"client_reference_id\":\"x\",\"notify_customer_email\":true,\"reminder\":null,\"days_until_due\":null}}".getBytes(StandardCharsets.UTF_8), now);
        RenewalChargeWebhookEvent renewal = assertInstanceOf(RenewalChargeWebhookEvent.class, due);
        assertEquals("subscription.renewal_due", renewal.getType());
        assertEquals("rc_1", renewal.getData().getId());
        assertEquals("https://perata.sh/pagar/rc_1", renewal.getData().getPaymentUrl());
        assertNull(renewal.getData().getReminder());
        WebhookEvent live = Webhook.verify(NEW_SECRET, webhookHeaders("msg_8", SIGNED_AT, "v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q="),
                "{\"id\":\"msg_8\",\"type\":\"subscription.renewal_reminder\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"environment\":\"live\",\"showcase_id\":\"shw_1\",\"data\":{\"id\":\"rc_1\",\"subscription_id\":\"sub_1\",\"showcase_id\":\"x\",\"customer_id\":\"x\",\"product_id\":\"x\",\"price_id\":\"x\",\"cycle_sequence\":2,\"amount_cents\":9000,\"currency\":\"BRL\",\"label\":\"Olho de Águia · Ana\",\"renewal_mode\":\"manual\",\"period_start\":\"2026-11-20T12:00:00Z\",\"period_end\":\"2026-11-20T12:00:00Z\",\"due_at\":\"2026-12-20T03:00:00Z\",\"expires_at\":\"2026-12-27T03:00:00Z\",\"payment_url\":\"https://perata.sh/pagar/rc_1\",\"metadata\":{},\"client_reference_id\":\"x\",\"notify_customer_email\":true,\"reminder\":\"before_due\",\"days_until_due\":3}}".getBytes(StandardCharsets.UTF_8), now);
        RenewalChargeWebhookEvent reminder = assertInstanceOf(RenewalChargeWebhookEvent.class, live);
        assertEquals("subscription.renewal_reminder", reminder.getType());
        assertEquals("live", reminder.getEnvironment());
        assertEquals("before_due", reminder.getData().getReminder());
        assertEquals(Long.valueOf(3), reminder.getData().getDaysUntilDue());
    }

    @Test
    @SuppressWarnings("unchecked")
    void usageIngestionCarriesTheSourceCredentialAndItsEvents() {
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(Map.of("created", 1L, "replayed", 0L))));
        Perata usage = Perata.builder("pus_live_source").baseUrl("https://perata.test/").transport(recorder).build();
        UsageIngestReceipt receipt = usage.usage().ingest(UsageService.IngestParams.builder().events(List.of(UsageService.UsageIngestEvent.builder()
                .customerId("cus_1").externalEventId("req-1").inputTokens("1200").outputTokens("300").cachedTokens("0")
                .occurredAt("2026-11-13T12:00:00Z")
                .cost(UsageService.UsageIngestEventCost.builder().amount("1.250000").currency("brl").build())
                .build())).build());
        assertEquals(1L, receipt.getCreated());
        assertEquals(0L, receipt.getReplayed());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("POST", seen.getMethod());
        assertEquals("/api/v1/usage/token-events", URI.create(seen.getUrl()).getPath());
        assertEquals("Bearer pus_live_source", seen.getHeaders().get("Authorization"));
        Map<String, Object> sent = Json.asObject(Json.parse(new String(seen.getBody(), StandardCharsets.UTF_8)));
        List<Object> events = (List<Object>) sent.get("events");
        assertEquals(1, events.size());
        Map<String, Object> event = Json.asObject(events.get(0));
        assertEquals("cus_1", event.get("customer_id"));
        assertEquals(Map.of("amount", "1.250000", "currency", "brl"), event.get("_cost"));
        assertEquals(false, event.containsKey("_llm"));
        assertEquals(false, event.containsKey("parent_id"));
    }

    @Test
    void usageIngestionErrorsAreTheFlatErrorDocument() {
        UsageService.IngestParams params = UsageService.IngestParams.builder().events(List.of(UsageService.UsageIngestEvent.builder()
                .customerId("cus_1").externalEventId("req-1").inputTokens("1").outputTokens("0").cachedTokens("0").occurredAt("2026-11-13T12:00:00Z").build())).build();
        Object[][] cases = {
            {401, Map.of("error", "invalid_credential"), "invalid_credential", 0, ""},
            {409, Map.of("error", "conflict", "record", 2L, "message", "conflict"), "conflict", 2, "conflict"},
            {422, Map.of("error", "invalid_request", "record", 3L, "message", "validation failed: customer_id", "fields", Map.of("customer_id", List.of("unknown"))), "invalid_request", 3, "validation failed: customer_id"},
            {400, Map.of("error", "invalid_request", "message", "malformed JSON"), "invalid_request", 0, "malformed JSON"},
            {415, Map.of("error", "unsupported_media_type"), "unsupported_media_type", 0, ""},
            {500, Map.of("error", "unavailable"), "unavailable", 0, ""},
        };
        for (Object[] each : cases) {
            Recorder recorder = new Recorder(request -> json((Integer) each[0], Map.of(), each[1]));
            PerataException refused = assertThrows(PerataException.class, () -> client(recorder).usage().ingest(params));
            assertEquals(each[0], refused.getStatus());
            assertEquals(each[2], refused.getCode());
            assertEquals(each[3], refused.getRecord());
            assertEquals(each[4], refused.getApiMessage());
            if ((Integer) each[0] == 422) {
                assertEquals(List.of("unknown"), refused.getFields().get("customer_id"));
            }
        }
    }

    @Test
    void anErrorWrappedInDataByAnOlderServerIsStillRead() {
        UsageService.IngestParams params = UsageService.IngestParams.builder().events(List.of(UsageService.UsageIngestEvent.builder()
                .customerId("cus_1").externalEventId("req-1").inputTokens("1").outputTokens("0").cachedTokens("0").occurredAt("2026-11-13T12:00:00Z").build())).build();
        Recorder recorder = new Recorder(request -> json(409, Map.of(), data(Map.of("error", "event_conflict", "record", 2L, "message", "conflict"))));
        PerataException refused = assertThrows(PerataException.class, () -> client(recorder).usage().ingest(params));
        assertEquals(409, refused.getStatus());
        assertEquals("event_conflict", refused.getCode());
        assertEquals(2, refused.getRecord());
    }

    @Test
    void aRefusalIsATypedError() {
        Recorder recorder = new Recorder(request -> URI.create(request.getUrl()).getPath().equals("/api/v1/customers")
                ? json(422, Map.of(), Map.of("error", "invalid_request", "fields", Map.of("email", List.of("send an e-mail"))))
                : json(429, Map.of("Retry-After", "7"), null));
        Perata perata = client(recorder);
        PerataException refused = assertThrows(PerataException.class,
                () -> perata.customers().create(CustomersService.CreateParams.builder().name("x").email("x").build()));
        assertEquals(422, refused.getStatus());
        assertEquals("invalid_request", refused.getCode());
        assertEquals(List.of("send an e-mail"), refused.getFields().get("email"));
        PerataException limited = assertThrows(PerataException.class, () -> perata.products().list());
        assertEquals(429, limited.getStatus());
        assertEquals(Integer.valueOf(7), limited.getRetryAfter());
    }

    // The webhook vectors every SDK checks: Standard Webhooks' own example, and
    // Peráta events signed under two secrets, as while one is rotated.
    private static final String REFERENCE_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    private static final String OLD_SECRET = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
    private static final String NEW_SECRET = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
    private static final String ORDER_PAID = "{\"id\":\"msg_2\",\"type\":\"order.paid\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"id\":\"ord_1\",\"customer_id\":\"cus_1\",\"product_id\":\"prod_1\",\"price_id\":\"price_1\",\"amount_cents\":12000,\"currency\":\"BRL\",\"status\":\"succeeded\",\"paid_at\":\"2026-10-22T12:00:00Z\",\"order_status\":\"paid\",\"refunded_amount_cents\":0,\"refund_id\":null,\"refund_amount_cents\":null,\"installments\":3,\"installment_interest_cents\":360,\"items\":[],\"metadata\":{},\"client_reference_id\":\"\",\"showcase_id\":\"shw_1\",\"subtotal_cents\":12000,\"discount_cents\":0,\"discount_id\":null,\"discount_code\":null}}";
    private static final String USAGE_RECORDED = "{\"id\":\"msg_3\",\"type\":\"usage_event.recorded\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"event_id\":\"ue_1\",\"aggregate\":\"usage_event\",\"aggregate_id\":\"ue_1\",\"merchant_id\":\"mer_1\",\"environment\":\"test\"}}";
    private static final String ORDER_PAID_LIVE = "{\"id\":\"msg_5\",\"type\":\"order.paid\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"environment\":\"live\",\"showcase_id\":\"shw_1\",\"data\":{\"id\":\"ord_1\",\"customer_id\":\"cus_1\",\"product_id\":\"prod_1\",\"price_id\":\"price_1\",\"amount_cents\":12000,\"currency\":\"BRL\",\"status\":\"succeeded\",\"paid_at\":\"2026-10-22T12:00:00Z\",\"order_status\":\"paid\",\"refunded_amount_cents\":0,\"refund_id\":null,\"refund_amount_cents\":null,\"installments\":3,\"installment_interest_cents\":360,\"items\":[],\"metadata\":{},\"client_reference_id\":\"\",\"showcase_id\":\"shw_1\",\"subtotal_cents\":12000,\"discount_cents\":0,\"discount_id\":null,\"discount_code\":null}}";
    private static final String PAYOUT_SENT_TEST = "{\"id\":\"msg_6\",\"type\":\"payout.sent\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"environment\":\"test\",\"data\":{\"payout_id\":\"po_1\",\"amount_cents\":5000}}";
    private static final String PAYOUT_SENT = "{\"id\":\"msg_4\",\"type\":\"payout.sent\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"payout_id\":\"po_1\",\"amount_cents\":5000}}";
    private static final long SIGNED_AT = 1792670400L;

    private static Map<String, String> webhookHeaders(String id, long at, String signature) {
        Map<String, String> headers = new HashMap<>();
        headers.put("Webhook-Id", id);
        headers.put("webhook-timestamp", Long.toString(at));
        headers.put("webhook-signature", signature);
        return headers;
    }

    @Test
    void theStandardWebhooksVectorVerifies() {
        byte[] body = "{\"test\": 2432232314}".getBytes(StandardCharsets.UTF_8);
        Map<String, String> headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330L, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
        Instant at = Instant.ofEpochSecond(1614265330L);
        Webhook.verifySignature(REFERENCE_SECRET, headers, body, at);
        byte[] changed = "{\"test\": 2432232314} ".getBytes(StandardCharsets.UTF_8);
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(REFERENCE_SECRET, headers, changed, at));
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(REFERENCE_SECRET, headers, body, at.plusSeconds(301)));
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, headers, body, at));
    }

    @Test
    void aTimestampThatIsNotPlainDigitsIsRefused() {
        byte[] body = "{\"test\": 2432232314}".getBytes(StandardCharsets.UTF_8);
        String[][] cases = {{"+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="}, {"\u00b2", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="}, {"", "x"}, {"1_6", "x"}};
        for (String[] each : cases) {
            Map<String, String> headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 0L, "v1," + each[1]);
            headers.put("webhook-timestamp", each[0]);
            assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(REFERENCE_SECRET, headers, body, Instant.ofEpochSecond(1614265330L)), each[0]);
        }
    }

    @Test
    void aWebhookCarriesTheEnvironmentItHappenedIn() {
        Instant now = Instant.ofEpochSecond(SIGNED_AT + 120);
        String[][] older = {
            {"msg_2", "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=", ORDER_PAID},
            {"msg_3", "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=", USAGE_RECORDED},
            {"msg_4", "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=", PAYOUT_SENT},
        };
        for (String[] each : older) {
            WebhookEvent event = Webhook.verify(NEW_SECRET, webhookHeaders(each[0], SIGNED_AT, each[1]), each[2].getBytes(StandardCharsets.UTF_8), now);
            assertEquals("", event.getEnvironment(), each[0]);
            assertEquals("", event.getShowcaseId(), each[0]);
        }
        WebhookEvent order = Webhook.verify(NEW_SECRET, webhookHeaders("msg_5", SIGNED_AT, "v1,vJOO2qPe9Vzlr42VPwCuIO+a6Sg8ZVfl9z4WuLJItwg="), ORDER_PAID_LIVE.getBytes(StandardCharsets.UTF_8), now);
        assertInstanceOf(OrderWebhookEvent.class, order);
        assertEquals("live", order.getEnvironment());
        assertEquals("shw_1", order.getShowcaseId());
        assertEquals("shw_1", ((OrderWebhookEvent) order).getData().getShowcaseId());
        WebhookEvent unknown = Webhook.verify(NEW_SECRET, webhookHeaders("msg_6", SIGNED_AT, "v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM="), PAYOUT_SENT_TEST.getBytes(StandardCharsets.UTF_8), now);
        assertInstanceOf(UnknownWebhookEvent.class, unknown);
        assertEquals("test", unknown.getEnvironment());
        assertEquals("", unknown.getShowcaseId());
    }

    @Test
    void aWebhookAnswersItsTypedEvent() {
        Instant now = Instant.ofEpochSecond(SIGNED_AT + 120);
        Map<String, String> headers = webhookHeaders("msg_2", SIGNED_AT, "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=");
        byte[] orderPaid = ORDER_PAID.getBytes(StandardCharsets.UTF_8);
        for (String secret : List.of(NEW_SECRET, OLD_SECRET)) {
            WebhookEvent event = Webhook.verify(secret, headers, orderPaid, now);
            OrderWebhookEvent order = assertInstanceOf(OrderWebhookEvent.class, event);
            assertEquals("order.paid", order.getType());
            assertEquals("ord_1", order.getData().getId());
            assertEquals(3L, order.getData().getInstallments());
            assertEquals(360L, order.getData().getInstallmentInterestCents());
        }
        assertThrows(WebhookVerificationException.class, () -> Webhook.verify(REFERENCE_SECRET, headers, orderPaid, now));
        WebhookEvent usage = Webhook.verify(NEW_SECRET, webhookHeaders("msg_3", SIGNED_AT, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="),
                USAGE_RECORDED.getBytes(StandardCharsets.UTF_8), now);
        assertEquals("mer_1", assertInstanceOf(IdentifiersWebhookEvent.class, usage).getData().get("merchant_id"));
        assertEquals("msg_3", usage.getId());
        WebhookEvent unknown = Webhook.verify(NEW_SECRET, webhookHeaders("msg_4", SIGNED_AT, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="),
                PAYOUT_SENT.getBytes(StandardCharsets.UTF_8), now);
        assertEquals("payout.sent", unknown.getType());
        assertEquals("po_1", assertInstanceOf(UnknownWebhookEvent.class, unknown).getData().get("payout_id"));
    }

    @Test
    void theRealHttpSendsAndReadsThroughTheJdkClient() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] answer;
            if (!"Bearer prk_test_key".equals(exchange.getRequestHeaders().getFirst("Authorization"))) {
                exchange.getResponseHeaders().set("Retry-After", "3");
                answer = Json.write(Map.of("error", "invalid_credential")).getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(401, answer.length);
            } else {
                Map<String, Object> sent = Json.asObject(Json.parse(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8)));
                String idempotencyKey = exchange.getRequestHeaders().getFirst("Idempotency-Key");
                Map<String, Object> product = product("prod_1");
                product.put("name", sent.get("name"));
                product.put("description", idempotencyKey == null ? "" : idempotencyKey);
                product.put("showcase_id", "shw_1");
                product.put("created_at", exchange.getRequestMethod() + " " + exchange.getRequestURI());
                answer = Json.write(data(product)).getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(201, answer.length);
            }
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(answer);
            }
        });
        server.start();
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            Product product = Perata.builder("prk_test_key").baseUrl(base).build().products().create(
                    ProductsService.CreateParams.builder().name("Curso").build(),
                    RequestOptions.builder().idempotencyKey("create-1").build());
            assertEquals("Curso", product.getName());
            assertEquals("create-1", product.getDescription());
            assertEquals("POST /api/v1/products", product.getCreatedAt());

            PerataException refused = assertThrows(PerataException.class,
                    () -> Perata.builder("prk_test_other").baseUrl(base).build().products().get("prod_1"));
            assertEquals(401, refused.getStatus());
            assertEquals("invalid_credential", refused.getCode());
            assertEquals(Integer.valueOf(3), refused.getRetryAfter());
            assertFalse(refused.getMessage().isEmpty());
            assertTrue(refused.getFields().isEmpty());
        } finally {
            server.stop(0);
        }
    }
}
