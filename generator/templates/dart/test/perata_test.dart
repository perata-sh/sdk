import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perata_sdk/perata_sdk.dart';
import 'package:test/test.dart';

typedef Answer = http.Response Function(http.Request request);

(Perata, List<http.Request>) client(Answer answer) {
  final seen = <http.Request>[];
  final fake = MockClient((request) async {
    seen.add(request);
    return answer(request);
  });
  final perata = Perata(
    'prk_test_key',
    baseUrl: 'http://perata.test/',
    httpClient: fake,
  );
  return (perata, seen);
}

http.Response json(
  int status,
  Object? body, [
  Map<String, String> headers = const {},
]) => http.Response(
  body == null ? '' : jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

Map<String, Object?> product(String id) => {
  'id': id,
  'name': 'Curso',
  'description': '',
  'status': 'active',
  'created_at': '2026-10-17T00:00:00Z',
};

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const referenceSecret = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
const oldSecret = 'whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=';
const newSecret = 'whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=';
const orderPaid =
    '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z",'
    '"data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1",'
    '"price_id":"price_1","amount_cents":12000,"currency":"BRL",'
    '"status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,'
    '"installment_interest_cents":360}}';
const usageRecorded =
    '{"id":"msg_3","type":"usage_event.recorded",'
    '"timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1",'
    '"aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1",'
    '"environment":"test"}}';
const payoutSent =
    '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z",'
    '"data":{"payout_id":"po_1","amount_cents":5000}}';
const signedAt = 1792670400;

Map<String, String> webhookHeaders(String id, int at, String signature) => {
  'Webhook-Id': id,
  'Webhook-Timestamp': '$at',
  'Webhook-Signature': signature,
};

void main() {
  test('a call carries the key and unwraps the data', () async {
    final (perata, seen) = client(
      (_) => json(200, {'data': product('prod_1')}),
    );
    final got = await perata.products.get('prod_1');
    expect(got.id, 'prod_1');
    expect(got.status, 'active');
    expect(got.createdAt, '2026-10-17T00:00:00Z');
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/v1/products/prod_1');
    expect(seen.single.headers['authorization'], 'Bearer prk_test_key');
    expect(seen.single.headers['accept'], 'application/json');
  });

  test('a write sends its body and idempotency key', () async {
    final (perata, seen) = client(
      (_) => json(201, {'data': product('prod_1')}),
    );
    await perata.products.create(
      const ProductsCreateParams(name: 'Curso'),
      idempotencyKey: 'create-1',
    );
    expect(seen.single.method, 'POST');
    expect(seen.single.headers['idempotency-key'], 'create-1');
    expect(seen.single.headers['content-type'], 'application/json');
    expect(jsonDecode(seen.single.body), {'name': 'Curso'});
  });

  test('iterating walks every page', () async {
    final (perata, seen) = client(
      (request) => json(200, {
        'data': {
          'items': [product('prod_${request.url.queryParameters['page']}')],
          'pagination': {'total_count': 3, 'max_page': 3},
        },
      }),
    );
    final ids = await perata.products
        .listIter(limit: 1)
        .map((item) => item.id)
        .toList();
    expect(ids, ['prod_1', 'prod_2', 'prod_3']);
    expect(seen.first.url.queryParameters['limit'], '1');
  });

  test('a refusal is a typed error', () async {
    final (perata, _) = client(
      (request) => request.url.path == '/api/v1/customers'
          ? json(422, {
              'error': 'invalid_request',
              'fields': {
                'email': ['send an e-mail'],
              },
            })
          : json(429, null, {'retry-after': '7'}),
    );
    await expectLater(
      perata.customers.create(
        const CustomersCreateParams(name: 'x', email: 'x'),
      ),
      throwsA(
        isA<PerataException>()
            .having((error) => error.status, 'status', 422)
            .having((error) => error.code, 'code', 'invalid_request')
            .having((error) => error.fields['email'], 'fields', [
              'send an e-mail',
            ]),
      ),
    );
    await expectLater(
      perata.products.list(),
      throwsA(
        isA<PerataException>()
            .having((error) => error.status, 'status', 429)
            .having((error) => error.retryAfter, 'retryAfter', 7),
      ),
    );
  });

  test('the Standard Webhooks vector verifies', () {
    const body = '{"test": 2432232314}';
    final headers = webhookHeaders(
      'msg_p5jXN8AQM9LWM0D4loKWxJek',
      1614265330,
      'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=',
    );
    final at = DateTime.fromMillisecondsSinceEpoch(1614265330000, isUtc: true);
    verifyWebhookSignature(referenceSecret, headers, body, now: at);
    for (final (secret, payload, now) in [
      (referenceSecret, '$body ', at),
      (referenceSecret, body, at.add(const Duration(seconds: 301))),
      (newSecret, body, at),
    ]) {
      expect(
        () => verifyWebhookSignature(secret, headers, payload, now: now),
        throwsA(isA<WebhookVerificationException>()),
      );
    }
  });

  test('a webhook answers its typed event', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      (signedAt + 120) * 1000,
      isUtc: true,
    );
    final headers = webhookHeaders(
      'msg_2',
      signedAt,
      'v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= '
          'v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=',
    );
    for (final secret in [newSecret, oldSecret]) {
      final event = verifyWebhook(secret, headers, orderPaid, now: now);
      if (event is! OrderWebhookEvent) {
        fail('not an order event: $event');
      }
      expect(event.type, 'order.paid');
      expect(event.data.id, 'ord_1');
      expect(event.data.installments, 3);
      expect(event.data.installmentInterestCents, 360);
    }
    expect(
      () => verifyWebhook(referenceSecret, headers, orderPaid, now: now),
      throwsA(isA<WebhookVerificationException>()),
    );
    final usage = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_3',
        signedAt,
        'v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=',
      ),
      utf8.encode(usageRecorded),
      now: now,
    );
    expect(
      usage,
      isA<IdentifiersWebhookEvent>()
          .having((event) => event.id, 'id', 'msg_3')
          .having((event) => event.data['merchant_id'], 'merchant', 'mer_1'),
    );
    final unknown = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_4',
        signedAt,
        'v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=',
      ),
      payoutSent,
      now: now,
    );
    expect(
      unknown,
      isA<UnknownWebhookEvent>()
          .having((event) => event.type, 'type', 'payout.sent')
          .having((event) => event.data, 'data', {
            'payout_id': 'po_1',
            'amount_cents': 5000,
          }),
    );
  });

  test('a call goes over real HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String, String>{};
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      seen['method'] = request.method;
      seen['path'] = request.uri.path;
      seen['authorization'] = request.headers.value('authorization') ?? '';
      seen['user-agent'] = request.headers.value('user-agent') ?? '';
      seen['content-type'] = request.headers.value('content-type') ?? '';
      seen['idempotency-key'] = request.headers.value('idempotency-key') ?? '';
      seen['body'] = body;
      final created = request.uri.path == '/api/v1/products';
      request.response
        ..statusCode = created ? 201 : 404
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(
            created
                ? {'data': product('prod_1')}
                : {'error': 'not_found', 'message': 'no such product'},
          ),
        );
      await request.response.close();
    });
    final perata = Perata(
      'prk_test_key',
      baseUrl: 'http://${server.address.host}:${server.port}',
    );
    addTearDown(perata.close);

    final created = await perata.products.create(
      const ProductsCreateParams(name: 'Curso', description: 'Um curso'),
      idempotencyKey: 'create-1',
      apiKey: 'prk_test_other',
    );
    expect(created.id, 'prod_1');
    expect(seen['method'], 'POST');
    expect(seen['path'], '/api/v1/products');
    expect(seen['authorization'], 'Bearer prk_test_other');
    expect(seen['user-agent'], 'perata-dart/$sdkVersion');
    expect(seen['content-type'], 'application/json');
    expect(seen['idempotency-key'], 'create-1');
    expect(jsonDecode(seen['body']!), {
      'name': 'Curso',
      'description': 'Um curso',
    });

    await expectLater(
      perata.products.get('a b/c'),
      throwsA(
        isA<PerataException>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.code, 'code', 'not_found')
            .having((error) => error.message, 'message', 'no such product'),
      ),
    );
    expect(seen['path'], '/api/v1/products/a%20b%2Fc');
  });
}
