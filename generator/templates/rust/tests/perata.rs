use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

use perata::{
    verify_webhook_at, verify_webhook_signature_at, BalanceGetParams, BoxError,
    CheckoutClientPayment, CheckoutsCreateParams, CheckoutsListParams, Client,
    CustomersCreateParams, CustomersListParams, DiscountsCreateParams,
    DiscountsCreateParamsDuration, DiscountsCreateParamsType, DiscountsListParams, Error,
    HttpRequest, HttpResponse, OrdersListParams, PayoutStatus, PayoutsListParams,
    PricePricingModel, PriceStatus, PricesCreateParams, PricesCreateParamsInterval,
    PricesCreateParamsPricingModel, PricesCreateParamsType, PricesCreateTier, ProductStatus,
    ProductsCreateParams, ProductsListParams, SubscriptionsUpdateParams, UsageIngestEvent,
    UsageIngestEventCost, UsageIngestEventCostCurrency, UsageIngestParams, WebhookError,
    WebhookEvent,
};

type Seen = Arc<Mutex<Vec<HttpRequest>>>;

fn client(answer: impl Fn(&HttpRequest) -> HttpResponse + Send + Sync + 'static) -> (Client, Seen) {
    let seen: Seen = Arc::default();
    let record = Arc::clone(&seen);
    let transport = move |request: HttpRequest| -> Result<HttpResponse, BoxError> {
        let response = answer(&request);
        record.lock().unwrap().push(request);
        Ok(response)
    };
    let client = Client::builder("prk_test_key")
        .base_url("https://perata.test/")
        .transport(transport)
        .build();
    (client, seen)
}

fn product(id: &str) -> serde_json::Value {
    serde_json::json!({"id": id, "name": "Curso", "description": "", "status": "active", "showcase_id": "shw_1", "created_at": "2026-10-17T00:00:00Z"})
}

fn json(status: u16, body: serde_json::Value) -> HttpResponse {
    HttpResponse::new(status, body.to_string()).with_header("Content-Type", "application/json")
}

fn query(url: &str, name: &str) -> Option<String> {
    let (_, query) = url.split_once('?')?;
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.to_owned())
    })
}

#[test]
fn a_call_carries_the_key_and_unwraps_the_data() {
    let (client, seen) = client(|_| json(200, serde_json::json!({"data": product("prod_1")})));
    let got = client.products().get("prod_1").unwrap();
    assert_eq!(got.id, "prod_1");
    assert_eq!(got.status, ProductStatus::Active);
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].url, "https://perata.test/api/v1/products/prod_1");
    assert_eq!(seen[0].header("authorization"), Some("Bearer prk_test_key"));
    assert_eq!(
        seen[0].header("user-agent"),
        Some(format!("perata-rust/{}", perata::VERSION).as_str())
    );
}

#[test]
fn a_write_sends_its_body_and_idempotency_key() {
    let (client, seen) = client(|_| json(201, serde_json::json!({"data": product("prod_1")})));
    let created = client
        .products()
        .idempotency_key("create-1")
        .create(&ProductsCreateParams::new("Curso"))
        .unwrap();
    assert_eq!(created.name, "Curso");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].header("idempotency-key"), Some("create-1"));
    assert_eq!(seen[0].header("content-type"), Some("application/json"));
    let body: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    // The optional description, left unset, is not sent.
    assert_eq!(body, serde_json::json!({"name": "Curso"}));
}

#[test]
fn a_checkout_session_hands_back_the_client_secret_for_the_browser() {
    let session = |secret: &str| {
        serde_json::json!({"data": {
            "id": "pcl_1", "url": "https://perata.sh/pagamento/pcl_1", "product_id": "prod_1", "price_id": "price_1",
            "status": "active", "label": "", "notify_customer_email": true, "renewal_mode": "", "quantity": 1, "success_url": "https://loja.example/obrigado", "cancel_url": "",
            "expires_at": null, "created_at": "2026-11-16T12:00:00Z", "session_id": "cs_1", "client_secret": secret,
            "max_installments": 0, "installment_interest": null, "interest_free_installments": 0, "installment_monthly_rate_bp": 0, "min_installment_cents": 0, "pix_discount_bp": null, "boleto_discount_bp": null, "coupon_stacks_with_method_discount": null, "client_secret_expires_at": "2026-11-16T12:30:00Z", "status_key": "sk_1",
            "amount_cents": null, "items": [], "metadata": {}, "client_reference_id": "",
            "discount_id": "", "showcase_id": "shw_1", "subscription_start_at": null
        }})
    };
    let calls = std::sync::atomic::AtomicUsize::new(0);
    let (client, seen) = client(move |_| {
        if calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
            json(201, session("cs_secret_1"))
        } else {
            json(201, session("")).with_header("Idempotent-Replayed", "true")
        }
    });
    let params = CheckoutsCreateParams::new("price_1", "prod_1")
        .success_url("https://loja.example/obrigado");
    let checkout = client
        .checkouts()
        .idempotency_key("pedido-1")
        .create(&params)
        .unwrap();
    assert_eq!(checkout.client_secret, "cs_secret_1");
    assert_eq!(checkout.session_id, "cs_1");
    assert_eq!(checkout.status_key, "sk_1");
    assert_eq!(checkout.client_secret_expires_at, "2026-11-16T12:30:00Z");
    assert_eq!(checkout.url, "https://perata.sh/pagamento/pcl_1");
    assert_eq!(checkout.expires_at, None);
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0].method, "POST");
        assert_eq!(seen[0].url, "https://perata.test/api/v1/checkouts");
        assert_eq!(seen[0].header("idempotency-key"), Some("pedido-1"));
        let body: serde_json::Value =
            serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
        assert_eq!(
            body,
            serde_json::json!({"product_id": "prod_1", "price_id": "price_1", "success_url": "https://loja.example/obrigado"})
        );
    }
    let again = client
        .checkouts()
        .idempotency_key("pedido-1")
        .create(&params)
        .unwrap();
    assert_eq!(again.client_secret, "");
    assert_eq!(again.session_id, "cs_1");
}

#[test]
fn a_model_that_may_be_null_decodes_both_ways() {
    let payment: CheckoutClientPayment = serde_json::from_value(serde_json::json!({
        "id": "pay_1", "method": "pix", "state": "pending", "unresolved": false, "card_brand": "", "card_kind": "",
        "installments": 1,
        "pix": {"copia_e_cola": "000201", "qr_code_svg": "<svg/>", "expires_at": null},
        "boleto": null
    }))
    .unwrap();
    assert!(payment.boleto.is_none());
    let pix = payment.pix.unwrap();
    assert_eq!(pix.copia_e_cola, "000201");
    assert_eq!(pix.expires_at, None);
}

#[test]
fn a_base_url_must_be_https_unless_it_is_loopback() {
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for (base, accepted) in [
        ("https://perata.sh", true),
        ("http://localhost:8080", true),
        ("http://LOCALHOST", true),
        ("http://127.0.0.1:1", true),
        ("http://127.255.0.3", true),
        ("http://[::1]:8080", true),
        ("http://perata.sh", false),
        ("http://localhost.evil.test", false),
        ("http://127.0.0.1.evil.test", false),
        ("http://10.0.0.1", false),
        ("ftp://localhost", false),
        ("perata.sh", false),
        ("", false),
        ("http://[::2]", false),
    ] {
        let counted = Arc::clone(&calls);
        let client = Client::builder("k")
            .base_url(base)
            .transport(move |_: HttpRequest| -> Result<HttpResponse, BoxError> {
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(json(200, serde_json::json!({"data": product("prod_1")})))
            })
            .build();
        let answer = client.products().get("prod_1");
        assert_eq!(
            !matches!(answer, Err(Error::InsecureBaseUrl)),
            accepted,
            "{base}"
        );
    }
    // Only the accepted ones sent anything.
    assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 6);
}

#[test]
fn a_discount_goes_through_create_get_list_and_delete() {
    let discount = |id: &str| -> serde_json::Value {
        serde_json::from_str(&r#"{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}"#.replace("__ID__", id)).unwrap()
    };
    let (client, seen) = client(move |request| {
        if request.method == "POST" {
            return json(201, serde_json::json!({ "data": discount("disc_1") }));
        }
        if request.method == "DELETE" {
            return HttpResponse::new(204, "");
        }
        if request.url.contains("/api/v1/discounts?") {
            let page = query(&request.url, "page").unwrap();
            return json(
                200,
                serde_json::json!({"data": {"items": [discount(&format!("disc_{page}"))], "pagination": {"total_count": 2, "max_page": 2}}}),
            );
        }
        json(200, serde_json::json!({ "data": discount("disc_1") }))
    });
    let created = client
        .discounts()
        .create(
            &DiscountsCreateParams::new(
                DiscountsCreateParamsDuration::Once,
                "Black",
                DiscountsCreateParamsType::Percentage,
            )
            .basis_points(1000),
        )
        .unwrap();
    assert_eq!(created.id, "disc_1");
    assert_eq!(created.code, None);
    assert_eq!(created.product_ids, ["prod_1"]);
    assert_eq!(client.discounts().get("disc_1").unwrap().name, "Black");
    let ids: Vec<String> = client
        .discounts()
        .list_iter(DiscountsListParams::new().limit(1))
        .map(|each| each.unwrap().id)
        .collect();
    assert_eq!(ids, ["disc_1", "disc_2"]);
    // A 204 has no body, and the method answers nothing.
    client.discounts().delete("disc_1").unwrap();
    let seen = seen.lock().unwrap();
    let requests: Vec<String> = seen
        .iter()
        .map(|request| {
            let path = request.url.split('?').next().unwrap_or_default();
            format!(
                "{} {}",
                request.method,
                path.trim_start_matches("https://perata.test")
            )
        })
        .collect();
    assert_eq!(
        requests,
        [
            "POST /api/v1/discounts",
            "GET /api/v1/discounts/disc_1",
            "GET /api/v1/discounts",
            "GET /api/v1/discounts",
            "DELETE /api/v1/discounts/disc_1"
        ]
    );
    let body: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(
        body,
        serde_json::json!({"name": "Black", "type": "percentage", "duration": "once", "basis_points": 1000})
    );
}

#[test]
fn a_free_form_value_decodes_nested() {
    let state: serde_json::Value = serde_json::from_str(
        r#"{"id":"cus_1","showcase_id":"shw_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}"#,
    )
    .unwrap();
    let (client, _) = client(move |_| json(200, serde_json::json!({ "data": state.clone() })));
    let state = client.customers().get_state("cus_1").unwrap();
    let grant = &state.granted_benefits[0];
    assert_eq!(
        serde_json::to_value(&grant.benefit_metadata).unwrap(),
        serde_json::json!({"flags": {"beta": true, "limits": {"seats": 5, "tiers": ["a", 2, null, 1.5]}}})
    );
    assert_eq!(
        serde_json::to_value(&grant.properties).unwrap(),
        serde_json::json!({"links": [{"url": "https://example.com", "expires": null}]})
    );
}

#[test]
fn a_post_without_a_key_is_sent_with_its_own_a_get_with_none() {
    let (client, seen) = client(|_| json(201, serde_json::json!({"data": product("prod_1")})));
    let params = ProductsCreateParams::new("Curso");
    client.products().create(&params).unwrap();
    client.products().create(&params).unwrap();
    client
        .products()
        .idempotency_key("mine")
        .create(&params)
        .unwrap();
    client.products().get("prod_1").unwrap();
    let seen = seen.lock().unwrap();
    let keys: Vec<Option<&str>> = seen
        .iter()
        .map(|request| request.header("idempotency-key"))
        .collect();
    for key in &keys[..2] {
        let key = key.unwrap();
        let groups: Vec<&str> = key.split('-').collect();
        assert_eq!(
            groups.iter().map(|group| group.len()).collect::<Vec<_>>(),
            [8, 4, 4, 4, 12]
        );
        assert!(key
            .chars()
            .all(|c| c == '-' || c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert!(groups[2].starts_with('4') && "89ab".contains(&groups[3][..1]));
    }
    assert_ne!(keys[0], keys[1]);
    assert_eq!(keys[2], Some("mine"));
    assert_eq!(keys[3], None);
}

#[test]
fn iterating_walks_every_page() {
    let (client, seen) = client(|request| {
        let page = query(&request.url, "page").unwrap();
        json(
            200,
            serde_json::json!({"data": {"items": [product(&format!("prod_{page}"))], "pagination": {"total_count": 3, "max_page": 3}}}),
        )
    });
    let ids: Vec<String> = client
        .products()
        .list_iter(ProductsListParams::new().limit(1))
        .map(|product| product.unwrap().id)
        .collect();
    assert_eq!(ids, ["prod_1", "prod_2", "prod_3"]);
    assert_eq!(
        query(&seen.lock().unwrap()[0].url, "limit").as_deref(),
        Some("1")
    );
}

#[test]
fn a_metadata_filter_is_sent_as_one_pair_a_key_the_keys_sorted_and_escaped() {
    let (client, seen) = client(|_| {
        json(
            200,
            serde_json::json!({"data": {"items": [], "pagination": {"total_count": 0, "max_page": 1}}}),
        )
    });
    let metadata = [("pedido", "123"), ("camera id", "a/b")];
    client
        .orders()
        .list(
            &OrdersListParams::new()
                .client_reference_id("pedido-1")
                .metadata(metadata),
        )
        .unwrap();
    let walked = client
        .checkouts()
        .list_iter(CheckoutsListParams::new().limit(1).metadata(metadata))
        .count();
    assert_eq!(walked, 0);
    let seen = seen.lock().unwrap();
    assert_eq!(
        seen[0].url,
        "https://perata.test/api/v1/orders?client_reference_id=pedido-1&metadata%5Bcamera%20id%5D=a%2Fb&metadata%5Bpedido%5D=123"
    );
    assert_eq!(
        seen[1].url,
        "https://perata.test/api/v1/checkouts?page=1&limit=1&metadata%5Bcamera%20id%5D=a%2Fb&metadata%5Bpedido%5D=123"
    );
}

#[test]
fn customers_are_listed_by_email() {
    let (client, seen) = client(|_| {
        json(
            200,
            serde_json::json!({"data": {"items": [], "pagination": {"total_count": 0, "max_page": 1}}}),
        )
    });
    client
        .customers()
        .list(&CustomersListParams::new().email("ana@example.com"))
        .unwrap();
    assert_eq!(
        seen.lock().unwrap()[0].url,
        "https://perata.test/api/v1/customers?email=ana%40example.com"
    );
}

// A graduated price goes out with its tiers and without the fixed amount, and a
// subscription reads back the quantity it bills and the order reference it came
// from; amount_cents is the cycle's total for that quantity.
#[test]
fn a_graduated_price_carries_its_tiers_and_a_subscription_its_quantity() {
    let tiers = serde_json::json!([{"up_to": 1, "unit_amount_cents": 25000}, {"up_to": null, "unit_amount_cents": 15000}]);
    let price = serde_json::json!({"id": "price_1", "product_id": "prod_1", "type": "recurring", "interval": "month", "interval_count": 1, "currency": "BRL", "status": "active", "amount_cents": 0, "pricing_model": "graduated", "unit_amount_cents": null, "unit_label": "câmera", "unit_label_plural": "câmeras", "tiers": tiers});
    let subscription = serde_json::json!({"id": "sub_1", "label": "", "notify_customer_email": true, "renewal_mode": "manual", "amount_cents": 55000, "cancel_at_period_end": false, "client_reference_id": "pedido-9", "currency": "BRL", "current_period_end": "2026-12-20T00:00:00Z", "current_period_start": "2026-11-20T00:00:00Z", "customer_id": "cus_1", "interval": "month", "metadata": {"camera": "c1"}, "price_id": "price_1", "product_id": "prod_1", "quantity": 3, "showcase_id": "shw_1", "status": "active", "suspended_at": null, "suspension_reason": null, "trial_end": null, "trial_start": null});
    let (client, seen) = client(move |request| {
        if request.method == "POST" {
            json(201, serde_json::json!({"data": price.clone()}))
        } else {
            json(200, serde_json::json!({"data": subscription.clone()}))
        }
    });
    let created = client
        .prices()
        .create(
            &PricesCreateParams::new("prod_1", PricesCreateParamsType::Recurring)
                .interval(PricesCreateParamsInterval::Month)
                .pricing_model(PricesCreateParamsPricingModel::Graduated)
                .tiers(vec![
                    PricesCreateTier::new(25000).up_to(1),
                    PricesCreateTier::new(15000),
                ])
                .unit_label("câmera")
                .unit_label_plural("câmeras"),
        )
        .unwrap();
    let got = client.subscriptions().get("sub_1").unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].url, "https://perata.test/api/v1/prices");
    let sent: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(sent["pricing_model"], "graduated");
    assert_eq!(
        sent["tiers"],
        serde_json::json!([{"up_to": 1, "unit_amount_cents": 25000}, {"unit_amount_cents": 15000}])
    );
    assert!(sent.get("amount_cents").is_none());
    assert_eq!(created.pricing_model, PricePricingModel::Graduated);
    assert_eq!(created.amount_cents, 0);
    assert_eq!(created.unit_amount_cents, None);
    assert_eq!(created.tiers.len(), 2);
    assert_eq!(created.tiers[0].up_to, Some(1));
    assert_eq!(created.tiers[1].up_to, None);
    assert_eq!(created.tiers[1].unit_amount_cents, 15000);
    assert_eq!(
        seen[1].url,
        "https://perata.test/api/v1/subscriptions/sub_1"
    );
    assert_eq!((got.quantity, got.amount_cents), (3, 55000));
    assert_eq!(got.client_reference_id, "pedido-9");
}

// A checkout adds the buyer's remaining days to the first period, an extension
// goes out alone (no price_id), and the sale reads back what it took: the
// discount on the order and on the subscription, and the change scheduled for
// the next period.
#[test]
fn a_first_period_extension_and_the_discounts_the_sale_reads_back() {
    let (client, seen) = client(|request| {
        let route = format!(
            "{} {}",
            request.method,
            request.url.trim_start_matches("https://perata.test")
        );
        let (status, body) = match route.as_str() {
            "POST /api/v1/checkouts" => (
                201,
                r#"{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"x","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"disc_1","first_period_extra_days":30,"renewal_mode":"manual","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}"#,
            ),
            "PATCH /api/v1/subscriptions/sub_1" => (
                200,
                r#"{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":{"price_id":"price_2","quantity":5,"amount_cents":90000,"effective_at":"2026-12-20T03:00:00Z"},"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":"disc_1","discount_ends_at":"2027-03-01T03:00:00Z","first_period_extra_days":30,"renewal_mode":"manual","label":"x","notify_customer_email":false}}"#,
            ),
            "GET /api/v1/subscriptions/sub_2" => (
                200,
                r#"{"data":{"id":"sub_2","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"manual","label":"x","notify_customer_email":false}}"#,
            ),
            "GET /api/v1/orders/ord_1" => (
                200,
                r#"{"data":{"id":"ord_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","amount_cents":9000,"currency":"BRL","status":"open","paid_at":null,"order_status":null,"refunded_amount_cents":0,"installments":0,"installment_interest_cents":0,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"x","subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"discount_id":"disc_1","discount_code":"BEMVINDO","subtotal_cents":10000,"discount_cents":1000}}"#,
            ),
            "GET /api/v1/prices/price_1" => (
                200,
                r#"{"data":{"id":"price_1","product_id":"prod_1","currency":"BRL","amount_cents":9000,"type":"one_time","interval":"none","interval_count":0,"pricing_model":"fixed","unit_amount_cents":null,"tiers":[],"unit_label":"x","unit_label_plural":"x","minimum_units":null,"maximum_units":null,"status":"archived"}}"#,
            ),
            other => panic!("request {other}"),
        };
        json(status, serde_json::from_str(body).unwrap())
    });
    let checkout = client
        .checkouts()
        .create(&CheckoutsCreateParams::new("price_1", "prod_1").first_period_extra_days(30))
        .unwrap();
    assert_eq!(checkout.first_period_extra_days, Some(30));
    assert_eq!(checkout.discount_id, "disc_1");
    let subscription = client
        .subscriptions()
        .update(
            "sub_1",
            &SubscriptionsUpdateParams::new().extend_current_period_days(15),
        )
        .unwrap();
    let none = client.subscriptions().get("sub_2").unwrap();
    let order = client.orders().get("ord_1").unwrap();
    let price = client.prices().get("price_1").unwrap();
    let seen = seen.lock().unwrap();
    let created: serde_json::Value =
        serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(created["first_period_extra_days"], 30);
    assert_eq!(seen[1].method, "PATCH");
    let sent: serde_json::Value = serde_json::from_slice(seen[1].body.as_deref().unwrap()).unwrap();
    assert_eq!(sent["extend_current_period_days"], 15);
    assert!(sent.get("price_id").is_none());
    assert_eq!(subscription.first_period_extra_days, Some(30));
    assert_eq!(subscription.discount_id.as_deref(), Some("disc_1"));
    assert_eq!(
        subscription.discount_ends_at.as_deref(),
        Some("2027-03-01T03:00:00Z")
    );
    let pending = subscription.pending_update.unwrap();
    assert_eq!(
        (
            pending.price_id.as_str(),
            pending.quantity,
            pending.amount_cents,
            pending.effective_at.as_str()
        ),
        ("price_2", 5, 90000, "2026-12-20T03:00:00Z")
    );
    assert!(none.pending_update.is_none());
    assert_eq!(
        (none.first_period_extra_days, none.discount_id),
        (None, None)
    );
    assert_eq!(
        (
            order.subtotal_cents,
            order.discount_cents,
            order.discount_id.as_deref(),
            order.discount_code.as_deref()
        ),
        (10000, 1000, Some("disc_1"), Some("BEMVINDO"))
    );
    assert_eq!(seen[4].url, "https://perata.test/api/v1/prices/price_1");
    assert_eq!(price.status, PriceStatus::Archived);
}

// The payment reads back its fee, its net, its split and the payout that pays it.
#[test]
fn a_payment_reads_back_its_fee_its_split_and_its_payout() {
    let (client, _) = client(|_| {
        json(200, serde_json::from_str(r#"{"data":{"id":"pay_1","showcase_id":"x","checkout_id":"x","customer_id":"x","method":"card","state":"unknown","amount_cents":0,"captured_cents":0,"refunded_cents":0,"currency":"BRL","created_at":"2026-11-20T12:00:00Z","metadata":{},"client_reference_id":"x","installments":0,"installment_amount_cents":0,"installment_interest_cents":0,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"fee_cents":450,"net_cents":8550,"expected_payout_on":"2026-12-21","payout_deposited_on":null,"payout_id":null,"split":[{"recipient_id":"shw_2","amount_cents":9000,"fee_cents":450,"net_cents":8550}]}}"#).unwrap())
    });
    let payment = client.payments().get("pay_1").unwrap();
    assert_eq!((payment.fee_cents, payment.net_cents), (450, 8550));
    assert_eq!(payment.expected_payout_on.as_deref(), Some("2026-12-21"));
    assert_eq!(
        (payment.payout_id, payment.payout_deposited_on),
        (None, None)
    );
    assert_eq!(payment.split.len(), 1);
    let split = &payment.split[0];
    assert_eq!(split.recipient_id.as_deref(), Some("shw_2"));
    assert_eq!(
        (split.amount_cents, split.fee_cents, split.net_cents),
        (9000, 450, 8550)
    );
}

// The balance carries its period, the payouts are filtered and walked page by
// page, and a payout reads back its lines: a fee has no payment.
#[test]
fn the_balance_and_the_payouts_read_back_what_will_be_deposited() {
    let (client, seen) = client(|request| {
        let body = if request.url.contains("/api/v1/balance") {
            r#"{"data":{"total_to_receive_cents":100000,"released_cents":10000,"held_cents":5000,"scheduled_cents":60000,"later_cents":25000,"deposited_cents":42000,"period_from":"2026-11-01","period_to":"2026-11-20","currency":"BRL"}}"#
        } else if request.url.contains("/api/v1/payouts/po_20261120") {
            r#"{"data":{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2,"items":[{"kind":"sale","payment_id":"pay_1","installment":1,"status":"deposited","amount_cents":10000,"fee_cents":300,"net_cents":9700},{"kind":"fee","payment_id":null,"installment":0,"status":"deposited","amount_cents":0,"fee_cents":150,"net_cents":-150}]}}"#
        } else if query(&request.url, "page").as_deref() == Some("2") {
            r#"{"data":{"items":[{"id":"po_20261119","status":"released","expected_on":"2026-11-19","deposited_on":null,"amount_cents":5000,"fee_cents":200,"net_cents":4800,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}"#
        } else {
            r#"{"data":{"items":[{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}"#
        };
        json(200, serde_json::from_str(body).unwrap())
    });
    let balance = client
        .balance()
        .get(
            &BalanceGetParams::new()
                .date_from("2026-11-01")
                .date_to("2026-11-20"),
        )
        .unwrap();
    assert_eq!(balance.total_to_receive_cents, 100000);
    assert_eq!(
        balance.released_cents + balance.held_cents + balance.scheduled_cents + balance.later_cents,
        balance.total_to_receive_cents
    );
    assert_eq!(
        (
            balance.deposited_cents,
            balance.period_from.as_str(),
            balance.period_to.as_str(),
            balance.currency.as_str()
        ),
        (42000, "2026-11-01", "2026-11-20", "BRL")
    );
    let walked: Vec<String> = client
        .payouts()
        .list_iter(
            PayoutsListParams::new()
                .limit(1)
                .status("deposited")
                .date_from("2026-11-01")
                .sorting("-date"),
        )
        .map(|payout| {
            let payout = payout.unwrap();
            assert_eq!(payout.net_cents, payout.amount_cents - payout.fee_cents);
            assert_eq!(
                payout.status == PayoutStatus::Deposited,
                payout.deposited_on.is_some()
            );
            format!("{}:{}", payout.id, payout.status.as_str())
        })
        .collect();
    assert_eq!(walked, ["po_20261120:deposited", "po_20261119:released"]);
    let detail = client.payouts().get("po_20261120").unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(
        query(&seen[0].url, "date_from").as_deref(),
        Some("2026-11-01")
    );
    assert_eq!(
        query(&seen[0].url, "date_to").as_deref(),
        Some("2026-11-20")
    );
    assert_eq!(
        ["page", "limit", "status", "date_from", "sorting"]
            .map(|name| query(&seen[1].url, name).unwrap()),
        ["1", "1", "deposited", "2026-11-01", "-date"]
    );
    assert_eq!((detail.net_cents, detail.items.len()), (9550, 2));
    let (sale, fee) = (&detail.items[0], &detail.items[1]);
    assert_eq!(
        (
            sale.kind.as_str(),
            sale.payment_id.as_deref(),
            sale.installment,
            sale.net_cents
        ),
        ("sale", Some("pay_1"), 1, 9700)
    );
    assert_eq!(
        (fee.kind.as_str(), fee.payment_id.as_deref(), fee.net_cents),
        ("fee", None, -150)
    );
}

// A checkout says how its subscription renews, the subscription reads back the
// mode it resolved to, its label and whether the buyer is written to, an update
// changes them, and the open renewal charge is read by its own route; without
// one the API answers 404 no_open_charge.
#[test]
fn the_renewal_mode_the_label_and_the_open_charge() {
    let (client, seen) = client(|request| {
        let route = format!(
            "{} {}",
            request.method,
            request.url.trim_start_matches("https://perata.test")
        );
        let (status, body) = match route.as_str() {
            "POST /api/v1/checkouts" => (
                201,
                r#"{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"Olho de Águia · Ana","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"x","first_period_extra_days":null,"renewal_mode":"automatic","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","max_installments":0,"installment_interest":null,"interest_free_installments":0,"installment_monthly_rate_bp":0,"min_installment_cents":0,"pix_discount_bp":null,"boleto_discount_bp":null,"coupon_stacks_with_method_discount":null,"client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}"#,
            ),
            "PATCH /api/v1/subscriptions/sub_1" => (
                200,
                r#"{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"pix_automatic","label":"Olho de Águia · Ana","notify_customer_email":false}}"#,
            ),
            "GET /api/v1/subscriptions/sub_1/open-charge" => (
                200,
                r#"{"data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","reminder":null,"days_until_due":null,"notify_customer_email":true}}"#,
            ),
            _ => (
                404,
                r#"{"error":"no_open_charge","message":"A assinatura não tem cobrança de renovação em aberto."}"#,
            ),
        };
        json(status, serde_json::from_str(body).unwrap())
    });
    let label = "Olho de Águia · Ana";
    let checkout = client
        .checkouts()
        .create(
            &CheckoutsCreateParams::new("price_1", "prod_1")
                .renewal_mode("automatic")
                .notify_customer_email(false)
                .label(label),
        )
        .unwrap();
    let subscription = client
        .subscriptions()
        .update(
            "sub_1",
            &SubscriptionsUpdateParams::new()
                .renewal_mode("manual")
                .notify_customer_email(true)
                .label(label),
        )
        .unwrap();
    let charge = client.subscriptions().get_open_charge("sub_1").unwrap();
    let Err(Error::Api(refused)) = client.subscriptions().get_open_charge("sub_2") else {
        panic!("a missing open charge was read");
    };
    let seen = seen.lock().unwrap();
    let sent: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(
        (
            sent["renewal_mode"].as_str(),
            sent["notify_customer_email"].as_bool(),
            sent["label"].as_str()
        ),
        (Some("automatic"), Some(false), Some(label))
    );
    assert_eq!(
        (
            checkout.renewal_mode.as_str(),
            checkout.notify_customer_email,
            checkout.label.as_str()
        ),
        ("automatic", false, label)
    );
    let sent: serde_json::Value = serde_json::from_slice(seen[1].body.as_deref().unwrap()).unwrap();
    assert_eq!(
        (
            sent["renewal_mode"].as_str(),
            sent["notify_customer_email"].as_bool(),
            sent["label"].as_str()
        ),
        (Some("manual"), Some(true), Some(label))
    );
    assert_eq!(
        (
            subscription.renewal_mode.as_str(),
            subscription.label.as_str(),
            subscription.notify_customer_email
        ),
        ("pix_automatic", label, false)
    );
    assert_eq!(
        seen[2].url,
        "https://perata.test/api/v1/subscriptions/sub_1/open-charge"
    );
    assert_eq!(
        (
            charge.id.as_str(),
            charge.subscription_id.as_str(),
            charge.amount_cents,
            charge.renewal_mode.as_str()
        ),
        ("rc_1", "sub_1", 9000, "manual")
    );
    assert_eq!(
        (
            charge.payment_url.as_str(),
            charge.due_at.as_str(),
            charge.expires_at.as_deref()
        ),
        (
            "https://perata.sh/pagar/rc_1",
            "2026-12-20T03:00:00Z",
            Some("2026-12-27T03:00:00Z")
        )
    );
    assert!(
        charge.reminder.is_none()
            && charge.days_until_due.is_none()
            && charge.notify_customer_email
    );
    assert_eq!(
        (refused.status, refused.code.as_str()),
        (404, "no_open_charge")
    );
}

// The renewal events carry the charge: due, and the reminder with its days.
#[test]
fn the_renewal_events_carry_the_charge() {
    let now = UNIX_EPOCH + Duration::from_secs(SIGNED_AT + 120);
    let WebhookEvent::RenewalCharge(due) = verify_webhook_at(
        NEW_SECRET,
        webhook_headers("msg_7", SIGNED_AT, "v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w="),
        r#"{"id":"msg_7","type":"subscription.renewal_due","timestamp":"2026-10-22T12:00:00Z","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":null,"days_until_due":null}}"#.as_bytes(),
        now,
    )
    .unwrap() else {
        panic!("not a renewal event");
    };
    assert_eq!(due.type_, "subscription.renewal_due");
    assert_eq!(
        (due.data.id.as_str(), due.data.payment_url.as_str()),
        ("rc_1", "https://perata.sh/pagar/rc_1")
    );
    assert!(due.data.reminder.is_none());
    let WebhookEvent::RenewalCharge(reminder) = verify_webhook_at(
        NEW_SECRET,
        webhook_headers("msg_8", SIGNED_AT, "v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q="),
        r#"{"id":"msg_8","type":"subscription.renewal_reminder","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":"before_due","days_until_due":3}}"#.as_bytes(),
        now,
    )
    .unwrap() else {
        panic!("not a renewal event");
    };
    assert_eq!(
        (reminder.type_.as_str(), reminder.environment.as_str()),
        ("subscription.renewal_reminder", "live")
    );
    assert_eq!(
        reminder.data.reminder.as_ref().map(|each| each.as_str()),
        Some("before_due")
    );
    assert_eq!(reminder.data.days_until_due, Some(3));
}

#[test]
fn usage_ingestion_carries_the_source_credential_and_its_events() {
    let seen: Seen = Arc::default();
    let record = Arc::clone(&seen);
    let transport = move |request: HttpRequest| -> Result<HttpResponse, BoxError> {
        record.lock().unwrap().push(request);
        Ok(json(
            200,
            serde_json::json!({"data": {"created": 1, "replayed": 0}}),
        ))
    };
    let usage = Client::builder("pus_live_source")
        .base_url("https://perata.test/")
        .transport(transport)
        .build();
    let mut event =
        UsageIngestEvent::new("0", "cus_1", "req-1", "1200", "2026-11-13T12:00:00Z", "300");
    event._cost = Some(UsageIngestEventCost::new(
        "1.250000",
        UsageIngestEventCostCurrency::Brl,
    ));
    let receipt = usage
        .usage()
        .ingest(&UsageIngestParams::new(vec![event]))
        .unwrap();
    assert_eq!((receipt.created, receipt.replayed), (1, 0));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].url, "https://perata.test/api/v1/usage/token-events");
    assert_eq!(
        seen[0].header("authorization"),
        Some("Bearer pus_live_source")
    );
    let sent: serde_json::Value = serde_json::from_slice(seen[0].body.as_ref().unwrap()).unwrap();
    let events = sent["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["customer_id"], "cus_1");
    assert_eq!(
        events[0]["_cost"],
        serde_json::json!({"amount": "1.250000", "currency": "brl"})
    );
    assert!(events[0].get("_llm").is_none());
    assert!(events[0].get("parent_id").is_none());
}

#[test]
fn usage_ingestion_errors_are_the_flat_error_document() {
    let cases = [
        (
            401,
            serde_json::json!({"error": "invalid_credential"}),
            "invalid_credential",
            0,
            "",
        ),
        (
            409,
            serde_json::json!({"error": "conflict", "record": 2, "message": "conflict"}),
            "conflict",
            2,
            "conflict",
        ),
        (
            422,
            serde_json::json!({"error": "invalid_request", "record": 3, "message": "validation failed: customer_id", "fields": {"customer_id": ["unknown"]}}),
            "invalid_request",
            3,
            "validation failed: customer_id",
        ),
        (
            400,
            serde_json::json!({"error": "invalid_request", "message": "malformed JSON"}),
            "invalid_request",
            0,
            "malformed JSON",
        ),
        (
            415,
            serde_json::json!({"error": "unsupported_media_type"}),
            "unsupported_media_type",
            0,
            "",
        ),
        (
            500,
            serde_json::json!({"error": "unavailable"}),
            "unavailable",
            0,
            "",
        ),
    ];
    for (status, problem, code, record, message) in cases {
        let (usage, _) = client(move |_| json(status, problem.clone()));
        let event = UsageIngestEvent::new("0", "cus_1", "req-1", "1", "2026-11-13T12:00:00Z", "0");
        let Err(Error::Api(refused)) = usage.usage().ingest(&UsageIngestParams::new(vec![event]))
        else {
            panic!("a {status} was not refused");
        };
        assert_eq!(refused.status, status);
        assert_eq!(refused.code, code);
        assert_eq!(refused.record, record);
        assert_eq!(refused.message, message);
        if status == 422 {
            assert_eq!(refused.fields["customer_id"], ["unknown"]);
        }
    }
}

#[test]
fn an_error_wrapped_in_data_by_an_older_server_is_still_read() {
    let (usage, _) = client(|_| {
        json(
            409,
            serde_json::json!({"data": {"error": "event_conflict", "record": 2, "message": "conflict"}}),
        )
    });
    let event = UsageIngestEvent::new("0", "cus_1", "req-1", "1", "2026-11-13T12:00:00Z", "0");
    let Err(Error::Api(refused)) = usage.usage().ingest(&UsageIngestParams::new(vec![event]))
    else {
        panic!("a 409 was not refused");
    };
    assert_eq!(refused.status, 409);
    assert_eq!(refused.code, "event_conflict");
    assert_eq!(refused.record, 2);
}

#[test]
fn a_refusal_is_a_typed_error() {
    let (client, _) = client(|request| {
        if request.url.ends_with("/api/v1/customers") {
            return json(
                422,
                serde_json::json!({"error": "invalid_request", "fields": {"email": ["send an e-mail"]}}),
            );
        }
        HttpResponse::new(429, "").with_header("Retry-After", "7")
    });
    let Err(Error::Api(refused)) = client
        .customers()
        .create(&CustomersCreateParams::new("x", "x"))
    else {
        panic!("a 422 was not refused");
    };
    assert_eq!(
        (refused.status, refused.code.as_str()),
        (422, "invalid_request")
    );
    assert_eq!(refused.fields["email"], ["send an e-mail"]);
    let Err(Error::Api(limited)) = client.products().list(&ProductsListParams::new()) else {
        panic!("a 429 was not refused");
    };
    assert_eq!(
        (limited.status, limited.retry_after),
        (429, Some(Duration::from_secs(7)))
    );
}

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const REFERENCE_SECRET: &str = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const OLD_SECRET: &str = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
const NEW_SECRET: &str = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
const ORDER_PAID: &[u8] = br#"{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}"#;
const USAGE_RECORDED: &[u8] = br#"{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}"#;
const ORDER_PAID_LIVE: &[u8] = br#"{"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"payment_method_discount_cents":0,"payment_method_discount_bp":0,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}}"#;
const PAYOUT_SENT_TEST: &[u8] = br#"{"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","environment":"test","data":{"payout_id":"po_1","amount_cents":5000}}"#;
const PAYOUT_SENT: &[u8] = br#"{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}"#;
const SIGNED_AT: u64 = 1_792_670_400;

fn webhook_headers(id: &str, at: u64, signature: &str) -> Vec<(String, String)> {
    vec![
        ("Webhook-Id".to_owned(), id.to_owned()),
        ("webhook-timestamp".to_owned(), at.to_string()),
        ("webhook-signature".to_owned(), signature.to_owned()),
    ]
}

#[test]
fn the_standard_webhooks_vector_verifies() {
    let body: &[u8] = br#"{"test": 2432232314}"#;
    let headers = webhook_headers(
        "msg_p5jXN8AQM9LWM0D4loKWxJek",
        1_614_265_330,
        "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=",
    );
    let at = UNIX_EPOCH + Duration::from_secs(1_614_265_330);
    verify_webhook_signature_at(REFERENCE_SECRET, headers.clone(), body, at).unwrap();
    let changed = [body, b" "].concat();
    for (secret, payload, now) in [
        (REFERENCE_SECRET, changed.as_slice(), at),
        (REFERENCE_SECRET, body, at + Duration::from_secs(301)),
        (NEW_SECRET, body, at),
    ] {
        assert!(matches!(
            verify_webhook_signature_at(secret, headers.clone(), payload, now),
            Err(WebhookError::InvalidSignature)
        ));
    }
}

#[test]
fn a_timestamp_that_is_not_plain_digits_is_refused() {
    let body: &[u8] = br#"{"test": 2432232314}"#;
    let at = UNIX_EPOCH + Duration::from_secs(1_614_265_330);
    for (stamp, signature) in [
        (
            "+1614265330",
            "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8=",
        ),
        ("²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="),
        ("", "x"),
        ("1_6", "x"),
    ] {
        let headers = vec![
            (
                "Webhook-Id".to_owned(),
                "msg_p5jXN8AQM9LWM0D4loKWxJek".to_owned(),
            ),
            ("webhook-timestamp".to_owned(), stamp.to_owned()),
            ("webhook-signature".to_owned(), format!("v1,{signature}")),
        ];
        assert!(
            matches!(
                verify_webhook_signature_at(REFERENCE_SECRET, headers, body, at),
                Err(WebhookError::InvalidSignature)
            ),
            "{stamp:?} verified"
        );
    }
}

#[test]
fn a_webhook_carries_the_environment_it_happened_in() {
    let now = UNIX_EPOCH + Duration::from_secs(SIGNED_AT + 120);
    let older: [(&str, &str, &[u8]); 3] = [
        ("msg_2", "v1,F6yjAk5yoz2jK2Q70MVlMG2eFKNVM17nIhiWKfmjCzc= v1,npiewgDGHvzxB3L7ys4KBiP2hooWdiMkdW2tPNyOv/8=", ORDER_PAID),
        ("msg_3", "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=", USAGE_RECORDED),
        ("msg_4", "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=", PAYOUT_SENT),
    ];
    for (id, signature, body) in older {
        let event = verify_webhook_at(
            NEW_SECRET,
            webhook_headers(id, SIGNED_AT, signature),
            body,
            now,
        )
        .unwrap();
        assert_eq!(event.environment(), "", "{id}");
        assert_eq!(event.showcase_id(), "", "{id}");
    }
    let order = verify_webhook_at(
        NEW_SECRET,
        webhook_headers(
            "msg_5",
            SIGNED_AT,
            "v1,uz6PnD5ymh2ny+f3isuMCyoYJ/B1du6G21/9CW1HB7I=",
        ),
        ORDER_PAID_LIVE,
        now,
    )
    .unwrap();
    assert!(matches!(order, WebhookEvent::Order(_)));
    assert_eq!(order.environment(), "live");
    assert_eq!(order.showcase_id(), "shw_1");
    let WebhookEvent::Order(sale) = &order else {
        panic!("not an order event");
    };
    assert_eq!(sale.data.showcase_id, "shw_1");
    let unknown = verify_webhook_at(
        NEW_SECRET,
        webhook_headers(
            "msg_6",
            SIGNED_AT,
            "v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM=",
        ),
        PAYOUT_SENT_TEST,
        now,
    )
    .unwrap();
    assert!(matches!(unknown, WebhookEvent::Unknown(_)));
    assert_eq!(unknown.environment(), "test");
    assert_eq!(unknown.showcase_id(), "");
}

#[test]
fn a_webhook_answers_its_typed_event() {
    let now = UNIX_EPOCH + Duration::from_secs(SIGNED_AT + 120);
    let headers = webhook_headers(
        "msg_2",
        SIGNED_AT,
        "v1,F6yjAk5yoz2jK2Q70MVlMG2eFKNVM17nIhiWKfmjCzc= v1,npiewgDGHvzxB3L7ys4KBiP2hooWdiMkdW2tPNyOv/8=",
    );
    for secret in [NEW_SECRET, OLD_SECRET] {
        let WebhookEvent::Order(order) =
            verify_webhook_at(secret, headers.clone(), ORDER_PAID, now).unwrap()
        else {
            panic!("not an order event");
        };
        assert_eq!(
            (
                order.type_.as_str(),
                order.data.id.as_str(),
                order.data.installments,
                order.data.installment_interest_cents
            ),
            ("order.paid", "ord_1", 3, 360)
        );
    }
    assert!(matches!(
        verify_webhook_at(REFERENCE_SECRET, headers, ORDER_PAID, now),
        Err(WebhookError::InvalidSignature)
    ));
    let usage = verify_webhook_at(
        NEW_SECRET,
        webhook_headers(
            "msg_3",
            SIGNED_AT,
            "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=",
        ),
        USAGE_RECORDED,
        now,
    )
    .unwrap();
    assert_eq!(usage.id(), "msg_3");
    let WebhookEvent::Identifiers(usage) = usage else {
        panic!("not an identifiers event");
    };
    assert_eq!(usage.data["merchant_id"], "mer_1");
    let unknown = verify_webhook_at(
        NEW_SECRET,
        webhook_headers(
            "msg_4",
            SIGNED_AT,
            "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=",
        ),
        PAYOUT_SENT,
        now,
    )
    .unwrap();
    assert_eq!(unknown.type_(), "payout.sent");
    let WebhookEvent::Unknown(unknown) = unknown else {
        panic!("not an unknown event");
    };
    assert_eq!(
        unknown.data,
        serde_json::json!({"payout_id": "po_1", "amount_cents": 5000})
    );
}

/// Answers what it was sent, wrapped as the API wraps a resource; a request
/// without the test key is refused with a 401 and Retry-After 3.
fn echo_server() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut parts = line.split_whitespace();
            let (method, target) = (
                parts.next().unwrap_or("").to_owned(),
                parts.next().unwrap_or("").to_owned(),
            );
            let (mut length, mut authorization, mut idempotency) =
                (0, String::new(), String::new());
            loop {
                let mut header = String::new();
                reader.read_line(&mut header).unwrap();
                let header = header.trim_end();
                if header.is_empty() {
                    break;
                }
                let (name, value) = header.split_once(':').unwrap();
                match name.to_ascii_lowercase().as_str() {
                    "content-length" => length = value.trim().parse().unwrap(),
                    "authorization" => authorization = value.trim().to_owned(),
                    "idempotency-key" => idempotency = value.trim().to_owned(),
                    _ => {}
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let (status, extra, answer) = if authorization != "Bearer prk_test_key" {
                (
                    "401 Unauthorized",
                    "Retry-After: 3\r\n",
                    serde_json::json!({"error": "invalid_credential"}),
                )
            } else {
                let sent: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
                let data = serde_json::json!({
                    "id": "prod_1",
                    "name": sent["name"].as_str().unwrap_or(""),
                    "description": idempotency,
                    "status": "active",
                    "showcase_id": "shw_1",
                    "created_at": format!("{method} {target}"),
                });
                ("201 Created", "", serde_json::json!({ "data": data }))
            };
            let answer = answer.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{answer}",
                answer.len()
            );
        }
    });
    format!("http://{address}")
}

#[test]
fn the_real_http_sends_and_reads_through_ureq() {
    let base_url = echo_server();
    let client = Client::builder("prk_test_key").base_url(&base_url).build();
    let product = client
        .products()
        .idempotency_key("create-1")
        .create(&ProductsCreateParams::new("Curso"))
        .unwrap();
    assert_eq!(product.name, "Curso");
    assert_eq!(product.description, "create-1");
    assert_eq!(product.created_at, "POST /api/v1/products");
    let other = Client::builder("prk_test_other")
        .base_url(&base_url)
        .build();
    let Err(Error::Api(refused)) = other.products().get("prod_1") else {
        panic!("a 401 was not refused");
    };
    assert_eq!(refused.status, 401);
    assert_eq!(refused.code, "invalid_credential");
    assert_eq!(refused.retry_after, Some(Duration::from_secs(3)));
}

/// Answers every request with `response` and counts the connections it gets.
fn canned_server(response: String) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let count = Arc::clone(&hits);
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim_end().is_empty() {
                    break;
                }
            }
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (format!("http://{address}"), hits)
}

#[test]
fn a_redirect_is_refused_and_the_key_never_follows_it() {
    let (elsewhere, hits) = canned_server(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".to_owned(),
    );
    let (first, _) = canned_server(format!(
        "HTTP/1.1 302 Found\r\nLocation: {elsewhere}/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    ));
    let client = Client::builder("prk_test_key").base_url(&first).build();
    let Err(Error::Api(refused)) = client.products().get("prod_1") else {
        panic!("a redirect was followed");
    };
    assert_eq!(refused.status, 302);
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 0);
}
