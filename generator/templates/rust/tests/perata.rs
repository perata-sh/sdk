use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

use perata::{
    verify_webhook_at, BoxError, Client, CustomersCreateParams, Error, HttpRequest, HttpResponse,
    ProductStatus, ProductsCreateParams, ProductsListParams, WebhookError,
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
        .base_url("http://perata.test/")
        .transport(transport)
        .build();
    (client, seen)
}

fn product(id: &str) -> serde_json::Value {
    serde_json::json!({"id": id, "name": "Curso", "description": "", "status": "active", "created_at": "2026-10-17T00:00:00Z"})
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
    assert_eq!(seen[0].url, "http://perata.test/api/v1/products/prod_1");
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

#[test]
fn a_webhook_verifies_only_when_perata_signed_it() {
    let key = b"0123456789abcdef0123456789abcdef";
    let secret = format!("whsec_{}", STANDARD.encode(key));
    let body: &[u8] = br#"{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}"#;
    let now = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
    let sign = |at: u64, payload: &[u8]| {
        let mut mac = Hmac::<Sha256>::new_from_slice(key).unwrap();
        mac.update(format!("msg_1.{at}.").as_bytes());
        mac.update(payload);
        let signature = STANDARD.encode(mac.finalize().into_bytes());
        vec![
            ("Webhook-Id".to_owned(), "msg_1".to_owned()),
            ("webhook-timestamp".to_owned(), at.to_string()),
            (
                "webhook-signature".to_owned(),
                format!("v1,bm90LXRoaXMtb25l v1,{signature}"),
            ),
        ]
    };
    let event = verify_webhook_at(&secret, sign(1_800_000_000, body), body, now).unwrap();
    assert_eq!(event.type_, "checkout_session.succeeded");
    assert_eq!(event.data["checkout_session_id"], "cs_1");
    let tampered = [body, b" "].concat();
    assert!(matches!(
        verify_webhook_at(&secret, sign(1_800_000_000, body), &tampered, now),
        Err(WebhookError::InvalidSignature)
    ));
    assert!(matches!(
        verify_webhook_at(&secret, sign(1_800_000_000 - 600, body), body, now),
        Err(WebhookError::InvalidSignature)
    ));
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
