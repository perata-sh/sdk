package sh.perata;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
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
        return Perata.builder("prk_test_key").baseUrl("http://perata.test/").transport(recorder).build();
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

    @Test
    void aWebhookVerifiesOnlyWhenPerataSignedIt() throws Exception {
        byte[] key = "0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8);
        String secret = "whsec_" + Base64.getEncoder().encodeToString(key);
        byte[] body = "{\"id\":\"msg_1\",\"type\":\"checkout_session.succeeded\",\"timestamp\":\"2026-10-17T00:00:00Z\",\"data\":{\"checkout_session_id\":\"cs_1\"}}"
                .getBytes(StandardCharsets.UTF_8);
        Instant now = Instant.ofEpochSecond(1_800_000_000L);

        WebhookEvent event = Webhook.verify(secret, sign(key, now.getEpochSecond(), body), body, now);
        assertEquals("checkout_session.succeeded", event.getType());
        assertEquals("cs_1", event.getData().get("checkout_session_id"));

        byte[] tampered = (new String(body, StandardCharsets.UTF_8) + " ").getBytes(StandardCharsets.UTF_8);
        assertThrows(WebhookVerificationException.class, () -> Webhook.verify(secret, sign(key, now.getEpochSecond(), body), tampered, now));
        assertThrows(WebhookVerificationException.class, () -> Webhook.verify(secret, sign(key, now.getEpochSecond() - 600, body), body, now));
    }

    private static Map<String, String> sign(byte[] key, long at, byte[] payload) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        mac.update(("msg_1." + at + ".").getBytes(StandardCharsets.UTF_8));
        String signature = Base64.getEncoder().encodeToString(mac.doFinal(payload));
        Map<String, String> headers = new HashMap<>();
        headers.put("Webhook-Id", "msg_1");
        headers.put("webhook-timestamp", Long.toString(at));
        headers.put("webhook-signature", "v1,bm90LXRoaXMtb25l v1," + signature);
        return headers;
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
