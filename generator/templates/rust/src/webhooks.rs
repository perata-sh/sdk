use std::collections::HashMap;
use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

/// How far from now a webhook's timestamp may be.
pub const WEBHOOK_TOLERANCE: Duration = Duration::from_secs(300);

/// What Peráta posts to an endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebhookEvent {
    /// The message's id, the same as the webhook-id header.
    pub id: String,
    /// What happened: checkout_session.succeeded, payment.refunded…
    #[serde(rename = "type")]
    pub type_: String,
    /// When it happened.
    pub timestamp: String,
    /// The ids of what it happened to.
    #[serde(default)]
    pub data: HashMap<String, String>,
}

/// Why a webhook was not accepted.
#[derive(Debug)]
#[non_exhaustive]
pub enum WebhookError {
    /// The secret is not `whsec_` and a base64 key.
    InvalidSecret,
    /// Peráta did not sign the request, or signed it too long ago.
    InvalidSignature,
    /// The body is signed but is not an event.
    InvalidPayload(serde_json::Error),
}

impl fmt::Display for WebhookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WebhookError::InvalidSecret => {
                f.write_str("perata: the webhook secret is whsec_ and a base64 key")
            }
            WebhookError::InvalidSignature => {
                f.write_str("perata: webhook signature does not verify")
            }
            WebhookError::InvalidPayload(error) => write!(f, "perata: webhook payload: {error}"),
        }
    }
}

impl std::error::Error for WebhookError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            WebhookError::InvalidPayload(error) => Some(error),
            _ => None,
        }
    }
}

/// Checks a webhook Peráta sent, as Standard Webhooks signs it — an
/// HMAC-SHA256 of `{webhook-id}.{webhook-timestamp}.{body}` under the key the
/// endpoint's `whsec_` secret encodes — and answers its event. Pass the body
/// exactly as it arrived, before parsing it.
///
/// `headers` are the request's, their names in any case: a `HashMap`, a list
/// of pairs or an `http::HeaderMap` by reference.
pub fn verify_webhook<I, K, V>(
    secret: &str,
    headers: I,
    body: &[u8],
) -> Result<WebhookEvent, WebhookError>
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<str>,
    V: AsRef<[u8]>,
{
    verify_webhook_at(secret, headers, body, SystemTime::now())
}

/// [`verify_webhook`] as if it were `now`.
pub fn verify_webhook_at<I, K, V>(
    secret: &str,
    headers: I,
    body: &[u8],
    now: SystemTime,
) -> Result<WebhookEvent, WebhookError>
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<str>,
    V: AsRef<[u8]>,
{
    let key = STANDARD
        .decode(secret.strip_prefix("whsec_").unwrap_or(secret))
        .ok()
        .filter(|key| !key.is_empty())
        .ok_or(WebhookError::InvalidSecret)?;
    let (mut id, mut stamp, mut signatures) = (None, None, None);
    for (name, value) in headers {
        let Ok(value) = std::str::from_utf8(value.as_ref()) else {
            continue;
        };
        let name = name.as_ref();
        if name.eq_ignore_ascii_case("webhook-id") {
            id = id.or(Some(value.to_owned()));
        } else if name.eq_ignore_ascii_case("webhook-timestamp") {
            stamp = stamp.or(Some(value.to_owned()));
        } else if name.eq_ignore_ascii_case("webhook-signature") {
            signatures = signatures.or(Some(value.to_owned()));
        }
    }
    let id = id
        .filter(|id| !id.is_empty())
        .ok_or(WebhookError::InvalidSignature)?;
    let stamp = stamp.ok_or(WebhookError::InvalidSignature)?;
    let seconds: i64 = stamp.parse().map_err(|_| WebhookError::InvalidSignature)?;
    let now = match now.duration_since(UNIX_EPOCH) {
        Ok(since) => i64::try_from(since.as_secs()).unwrap_or(i64::MAX),
        Err(before) => -i64::try_from(before.duration().as_secs()).unwrap_or(i64::MAX),
    };
    if now.abs_diff(seconds) > WEBHOOK_TOLERANCE.as_secs() {
        return Err(WebhookError::InvalidSignature);
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).map_err(|_| WebhookError::InvalidSecret)?;
    mac.update(format!("{id}.{stamp}.").as_bytes());
    mac.update(body);
    for signature in signatures.unwrap_or_default().split_whitespace() {
        let Some(("v1", encoded)) = signature.split_once(',') else {
            continue;
        };
        let Ok(decoded) = STANDARD.decode(encoded) else {
            continue;
        };
        // verify_slice compares in constant time.
        if mac.clone().verify_slice(&decoded).is_ok() {
            return serde_json::from_slice(body).map_err(WebhookError::InvalidPayload);
        }
    }
    Err(WebhookError::InvalidSignature)
}
