import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What Peráta posts to an endpoint.
final class WebhookEvent {
  const WebhookEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.data,
  });

  /// The message's id, the same as the `webhook-id` header.
  final String id;

  /// What happened, such as `checkout_session.succeeded`.
  final String type;

  /// When it happened, in RFC 3339.
  final String timestamp;

  /// The ids of what it happened to.
  final Map<String, String> data;
}

/// A request Peráta did not sign, or signed too long ago.
class WebhookVerificationException implements Exception {
  const WebhookVerificationException([
    this.message = 'perata: webhook signature does not verify',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// How far from now a webhook's timestamp may be.
const webhookTolerance = Duration(minutes: 5);

final _digits = RegExp(r'^\d+$');
final _spaces = RegExp(r'\s+');

/// Checks a webhook Peráta sent, as Standard Webhooks signs it, and answers
/// its event.
///
/// The signature is an HMAC-SHA256 of `{webhook-id}.{webhook-timestamp}.{body}`
/// under the key the endpoint's `whsec_` [secret] encodes. [headers] are the
/// request's, in any case; [body] is a `String` or the bytes (`List<int>`),
/// exactly as they arrived, before parsing them. Throws
/// [WebhookVerificationException] when the signature does not verify.
WebhookEvent verifyWebhook(
  String secret,
  Map<String, String> headers,
  Object body, {
  DateTime? now,
}) {
  final key = _base64(
    secret.startsWith('whsec_') ? secret.substring(6) : secret,
  );
  if (key == null || key.isEmpty) {
    throw ArgumentError.value(
      secret,
      'secret',
      'perata: the webhook secret is whsec_ and a base64 key',
    );
  }
  final List<int> raw = switch (body) {
    String text => utf8.encode(text),
    List<int> bytes => bytes,
    _ => throw ArgumentError.value(body, 'body', 'a String or a List<int>'),
  };
  final id = _header(headers, 'webhook-id');
  final stamp = _header(headers, 'webhook-timestamp');
  final seconds = _digits.hasMatch(stamp) ? int.tryParse(stamp) : null;
  if (id.isEmpty || seconds == null) {
    throw const WebhookVerificationException();
  }
  final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  if ((now ?? DateTime.now()).difference(at).abs() > webhookTolerance) {
    throw const WebhookVerificationException();
  }
  final expected = Hmac(
    sha256,
    key,
  ).convert([...utf8.encode('$id.$stamp.'), ...raw]).bytes;
  final signatures = _header(headers, 'webhook-signature').split(_spaces);
  for (final signature in signatures) {
    final comma = signature.indexOf(',');
    if (comma < 0 || signature.substring(0, comma) != 'v1') {
      continue;
    }
    final decoded = _base64(signature.substring(comma + 1));
    if (decoded != null && _equal(decoded, expected)) {
      return _event(raw);
    }
  }
  throw const WebhookVerificationException();
}

WebhookEvent _event(List<int> raw) {
  final json = jsonDecode(utf8.decode(raw));
  if (json case {
    'id': final String id,
    'type': final String type,
    'timestamp': final String timestamp,
  }) {
    final data = json['data'];
    return WebhookEvent(
      id: id,
      type: type,
      timestamp: timestamp,
      data: data is Map<String, Object?>
          ? Map.unmodifiable(data.map((key, value) => MapEntry(key, '$value')))
          : const {},
    );
  }
  throw const FormatException('perata: the webhook body is not an event');
}

String _header(Map<String, String> headers, String name) {
  for (final MapEntry(:key, :value) in headers.entries) {
    if (key.toLowerCase() == name) {
      return value.trim();
    }
  }
  return '';
}

List<int>? _base64(String text) {
  try {
    return base64.decode(text);
  } on FormatException {
    return null;
  }
}

/// Compares two digests in constant time.
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
