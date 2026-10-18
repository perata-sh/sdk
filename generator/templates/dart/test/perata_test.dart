import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perata_sh_sdk/perata_sh_sdk.dart';
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

  test('a webhook verifies only when Peráta signed it', () {
    final key = utf8.encode('0123456789abcdef0123456789abcdef');
    final secret = 'whsec_${base64.encode(key)}';
    const body =
        '{"id":"msg_1","type":"checkout_session.succeeded",'
        '"timestamp":"2026-10-17T00:00:00Z",'
        '"data":{"checkout_session_id":"cs_1"}}';
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000000, isUtc: true);
    Map<String, String> sign(DateTime at, String payload) {
      final stamp = at.millisecondsSinceEpoch ~/ 1000;
      final mac = Hmac(
        sha256,
        key,
      ).convert(utf8.encode('msg_1.$stamp.$payload'));
      return {
        'Webhook-Id': 'msg_1',
        'Webhook-Timestamp': '$stamp',
        'Webhook-Signature':
            'v1,bm90LXRoaXMtb25l v1,${base64.encode(mac.bytes)}',
      };
    }

    final event = verifyWebhook(secret, sign(now, body), body, now: now);
    expect(event.id, 'msg_1');
    expect(event.type, 'checkout_session.succeeded');
    expect(event.data['checkout_session_id'], 'cs_1');
    expect(
      verifyWebhook(secret, sign(now, body), utf8.encode(body), now: now).type,
      'checkout_session.succeeded',
    );
    expect(
      () => verifyWebhook(secret, sign(now, body), '$body ', now: now),
      throwsA(isA<WebhookVerificationException>()),
    );
    final stale = now.subtract(const Duration(minutes: 10));
    expect(
      () => verifyWebhook(secret, sign(stale, body), body, now: now),
      throwsA(isA<WebhookVerificationException>()),
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
