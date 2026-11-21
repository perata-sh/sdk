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
    baseUrl: 'https://perata.test/',
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
  'showcase_id': 'shw_1',
  'created_at': '2026-10-17T00:00:00Z',
};

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Peráta events signed under two secrets, as while one is rotated.
const referenceSecret = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
const oldSecret = 'whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=';
const newSecret = 'whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=';
const orderPaid =
    '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00'
    'Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1'
    '","price_id":"price_1","amount_cents":12000,"currency":"BRL","stat'
    'us":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"p'
    'aid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cen'
    'ts":null,"installments":3,"installment_interest_cents":360,"items"'
    ':[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1",'
    '"subtotal_cents":12000,"discount_cents":0,"discount_id":null,'
    '"discount_code":null}}';
const usageRecorded =
    '{"id":"msg_3","type":"usage_event.recorded",'
    '"timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1",'
    '"aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1",'
    '"environment":"test"}}';
const payoutSent =
    '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z",'
    '"data":{"payout_id":"po_1","amount_cents":5000}}';
const orderPaidLive =
    '{"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00'
    'Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1"'
    ',"product_id":"prod_1","price_id":"price_1","amount_cents":12000,"'
    'currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:0'
    '0Z","order_status":"paid","refunded_amount_cents":0,"refund_id":nu'
    'll,"refund_amount_cents":null,"installments":3,"installment_intere'
    'st_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1",'
    '"subtotal_cents":12000,"discount_cents":0,"discount_id":null,'
    '"discount_code":null}}';
const payoutSentTest =
    '{"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:0'
    '0Z","environment":"test","data":{"payout_id":"po_1","amount_cents"'
    ':5000}}';
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

  test(
    'a checkout session hands back the client secret for the browser',
    () async {
      Map<String, Object?> session(String clientSecret) => {
        'id': 'pcl_1',
        'url': 'https://perata.sh/pagamento/pcl_1',
        'product_id': 'prod_1',
        'price_id': 'price_1',
        'status': 'active',
        'label': '',
        'notify_customer_email': true,
        'renewal_mode': '',
        'quantity': 1,
        'success_url': 'https://loja.example/obrigado',
        'cancel_url': '',
        'expires_at': null,
        'created_at': '2026-11-16T12:00:00Z',
        'session_id': 'cs_1',
        'client_secret': clientSecret,
        'client_secret_expires_at': '2026-11-16T12:30:00Z',
        'status_key': 'sk_1',
        'amount_cents': null,
        'items': <dynamic>[],
        'metadata': <String, dynamic>{},
        'client_reference_id': '',
        'discount_id': '',
        'showcase_id': 'shw_1',
        'subscription_start_at': null,
      };
      var calls = 0;
      final (perata, seen) = client(
        (_) => calls++ == 0
            ? json(201, {'data': session('cs_secret_1')})
            : json(201, {'data': session('')}, {'idempotent-replayed': 'true'}),
      );
      const params = CheckoutsCreateParams(
        productId: 'prod_1',
        priceId: 'price_1',
        successUrl: 'https://loja.example/obrigado',
      );
      final checkout = await perata.checkouts.create(
        params,
        idempotencyKey: 'pedido-1',
      );
      expect(checkout.clientSecret, 'cs_secret_1');
      expect(checkout.sessionId, 'cs_1');
      expect(checkout.statusKey, 'sk_1');
      expect(checkout.clientSecretExpiresAt, '2026-11-16T12:30:00Z');
      expect(checkout.url, 'https://perata.sh/pagamento/pcl_1');
      expect(checkout.expiresAt, isNull);
      expect(seen.first.method, 'POST');
      expect(seen.first.url.path, '/api/v1/checkouts');
      expect(seen.first.headers['idempotency-key'], 'pedido-1');
      expect(jsonDecode(seen.first.body), {
        'product_id': 'prod_1',
        'price_id': 'price_1',
        'success_url': 'https://loja.example/obrigado',
      });
      final again = await perata.checkouts.create(
        params,
        idempotencyKey: 'pedido-1',
      );
      expect(again.clientSecret, '');
      expect(again.sessionId, 'cs_1');
    },
  );

  test('a model that may be null decodes both ways', () {
    final payment = CheckoutClientPayment.fromJson({
      'id': 'pay_1',
      'method': 'pix',
      'state': 'pending',
      'unresolved': false,
      'card_brand': '',
      'card_kind': '',
      'installments': 1,
      'pix': {
        'copia_e_cola': '000201',
        'qr_code_svg': '<svg/>',
        'expires_at': null,
      },
      'boleto': null,
    });
    expect(payment.boleto, isNull);
    expect(payment.pix!.copiaECola, '000201');
    expect(payment.pix!.expiresAt, isNull);
  });

  test('a base URL must be https unless it is loopback', () {
    for (final baseUrl in [
      'https://perata.sh',
      'http://localhost:8080',
      'http://LOCALHOST',
      'http://127.0.0.1:1',
      'http://127.255.0.3',
      'http://[::1]:8080',
    ]) {
      Perata('k', baseUrl: baseUrl).close();
    }
    for (final baseUrl in [
      'http://perata.sh',
      'http://localhost.evil.test',
      'http://127.0.0.1.evil.test',
      'http://10.0.0.1',
      'ftp://localhost',
      'perata.sh',
      '',
      'http://[::2]',
    ]) {
      expect(
        () => Perata('k', baseUrl: baseUrl),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('must be https'),
          ),
        ),
        reason: baseUrl,
      );
    }
  });

  test('a discount goes through create, get, list and delete', () async {
    Map<String, Object?> discount(String id) =>
        jsonDecode(
              '''{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}'''
                  .replaceFirst('__ID__', id),
            )
            as Map<String, Object?>;
    final (perata, seen) = client((request) {
      if (request.method == 'POST') {
        return json(201, {'data': discount('disc_1')});
      }
      if (request.method == 'DELETE') {
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/discounts') {
        final page = request.url.queryParameters['page'];
        return json(200, {
          'data': {
            'items': [discount('disc_$page')],
            'pagination': {'total_count': 2, 'max_page': 2},
          },
        });
      }
      return json(200, {'data': discount('disc_1')});
    });
    final created = await perata.discounts.create(
      const DiscountsCreateParams(
        duration: 'once',
        name: 'Black',
        type: 'percentage',
        basisPoints: 1000,
      ),
    );
    expect(created.id, 'disc_1');
    expect(created.code, isNull);
    expect(created.productIds, ['prod_1']);
    expect((await perata.discounts.get('disc_1')).name, 'Black');
    expect(
      [
        await for (final each in perata.discounts.listIter(limit: 1)) each.id,
      ],
      ['disc_1', 'disc_2'],
    );
    await perata.discounts.delete('disc_1');
    expect(
      [for (final each in seen) '${each.method} ${each.url.path}'],
      [
        'POST /api/v1/discounts',
        'GET /api/v1/discounts/disc_1',
        'GET /api/v1/discounts',
        'GET /api/v1/discounts',
        'DELETE /api/v1/discounts/disc_1',
      ],
    );
    expect(jsonDecode(seen.first.body), {
      'name': 'Black',
      'type': 'percentage',
      'duration': 'once',
      'basis_points': 1000,
    });
  });

  test('a free-form value decodes nested', () async {
    final state = jsonDecode(
      '''{"id":"cus_1","showcase_id":"shw_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}''',
    );
    final (perata, _) = client((_) => json(200, {'data': state}));
    final grant = (await perata.customers.getState('cus_1')).grantedBenefits[0];
    expect(grant.benefitMetadata, {
      'flags': {
        'beta': true,
        'limits': {
          'seats': 5,
          'tiers': ['a', 2, null, 1.5],
        },
      },
    });
    expect(grant.properties, {
      'links': [
        {'url': 'https://example.com', 'expires': null},
      ],
    });
  });

  test('a POST without a key is sent with its own, a GET with none', () async {
    final (perata, seen) = client(
      (_) => json(201, {'data': product('prod_1')}),
    );
    const params = ProductsCreateParams(name: 'Curso');
    await perata.products.create(params);
    await perata.products.create(params);
    await perata.products.create(params, idempotencyKey: 'mine');
    await perata.products.get('prod_1');
    final keys = [for (final each in seen) each.headers['idempotency-key']];
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(keys[0], matches(uuid));
    expect(keys[1], matches(uuid));
    expect(keys[0], isNot(keys[1]));
    expect(keys[2], 'mine');
    expect(keys[3], isNull);
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

  test(
    'a metadata filter is sent as one pair a key, the keys sorted and escaped',
    () async {
      final (perata, seen) = client(
        (request) => json(200, {
          'data': {
            'items': <Object?>[],
            'pagination': {'total_count': 0, 'max_page': 1},
          },
        }),
      );
      final metadata = {'pedido': '123', 'camera id': 'a/b'};
      await perata.orders.list(
        clientReferenceId: 'pedido-1',
        metadata: metadata,
      );
      expect(
        seen[0].url.query,
        'client_reference_id=pedido-1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123',
      );
      expect(seen[0].url.queryParameters['metadata[camera id]'], 'a/b');
      final walked = await perata.checkouts
          .listIter(limit: 1, metadata: metadata)
          .toList();
      expect(walked, isEmpty);
      expect(
        seen[1].url.query,
        'page=1&limit=1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123',
      );
    },
  );

  test('customers are listed by e-mail', () async {
    final (perata, seen) = client(
      (request) => json(200, {
        'data': {
          'items': <Object?>[],
          'pagination': {'total_count': 0, 'max_page': 1},
        },
      }),
    );
    await perata.customers.list(email: 'ana@example.com');
    expect(seen.single.url.path, '/api/v1/customers');
    expect(seen.single.url.query, 'email=ana%40example.com');
  });

  // A graduated price goes out with its tiers and without the fixed amount, and
  // a subscription reads back the quantity it bills and the order reference it
  // came from; amountCents is the cycle's total for that quantity.
  test(
    'a graduated price carries its tiers and a subscription its quantity',
    () async {
      final tiers = [
        {'up_to': 1, 'unit_amount_cents': 25000},
        {'up_to': null, 'unit_amount_cents': 15000},
      ];
      final price = {
        'id': 'price_1',
        'product_id': 'prod_1',
        'type': 'recurring',
        'interval': 'month',
        'interval_count': 1,
        'currency': 'BRL',
        'status': 'active',
        'amount_cents': 0,
        'pricing_model': 'graduated',
        'unit_amount_cents': null,
        'unit_label': 'câmera',
        'unit_label_plural': 'câmeras',
        'tiers': tiers,
      };
      final subscription = {
        'id': 'sub_1',
        'label': '',
        'notify_customer_email': true,
        'renewal_mode': 'manual',
        'amount_cents': 55000,
        'cancel_at_period_end': false,
        'client_reference_id': 'pedido-9',
        'currency': 'BRL',
        'current_period_end': '2026-12-20T00:00:00Z',
        'current_period_start': '2026-11-20T00:00:00Z',
        'customer_id': 'cus_1',
        'interval': 'month',
        'metadata': {'camera': 'c1'},
        'price_id': 'price_1',
        'product_id': 'prod_1',
        'quantity': 3,
        'showcase_id': 'shw_1',
        'status': 'active',
        'suspended_at': null,
        'suspension_reason': null,
        'trial_end': null,
        'trial_start': null,
      };
      final (perata, seen) = client(
        (request) => request.method == 'POST'
            ? json(201, {'data': price})
            : json(200, {'data': subscription}),
      );
      final created = await perata.prices.create(
        const PricesCreateParams(
          productId: 'prod_1',
          type: 'recurring',
          interval: 'month',
          pricingModel: 'graduated',
          tiers: [
            PricesCreateTier(upTo: 1, unitAmountCents: 25000),
            PricesCreateTier(unitAmountCents: 15000),
          ],
          unitLabel: 'câmera',
          unitLabelPlural: 'câmeras',
        ),
      );
      expect(seen[0].url.path, '/api/v1/prices');
      final sent = jsonDecode(seen[0].body) as Map<String, Object?>;
      expect(sent['pricing_model'], 'graduated');
      expect(sent['tiers'], [
        {'up_to': 1, 'unit_amount_cents': 25000},
        {'unit_amount_cents': 15000},
      ]);
      expect(sent.containsKey('amount_cents'), isFalse);
      expect(created.pricingModel, 'graduated');
      expect(created.amountCents, 0);
      expect(created.unitAmountCents, isNull);
      expect(created.tiers.map((tier) => (tier.upTo, tier.unitAmountCents)), [
        (1, 25000),
        (null, 15000),
      ]);
      final got = await perata.subscriptions.get('sub_1');
      expect(seen[1].url.path, '/api/v1/subscriptions/sub_1');
      expect(got.quantity, 3);
      expect(got.amountCents, 55000);
      expect(got.clientReferenceId, 'pedido-9');
    },
  );

  // A checkout adds the buyer's remaining days to the first period, an
  // extension goes out alone (no price_id), and the sale reads back what it
  // took: the discount on the order and on the subscription, and the change
  // scheduled for the next period.
  test('a first period extension and the discounts the sale reads back', () async {
    final answers = <String, (int, String)>{
      'POST /api/v1/checkouts': (
        201,
        r'''{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"x","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"disc_1","first_period_extra_days":30,"renewal_mode":"manual","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}''',
      ),
      'PATCH /api/v1/subscriptions/sub_1': (
        200,
        r'''{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":{"price_id":"price_2","quantity":5,"amount_cents":90000,"effective_at":"2026-12-20T03:00:00Z"},"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":"disc_1","discount_ends_at":"2027-03-01T03:00:00Z","first_period_extra_days":30,"renewal_mode":"manual","label":"x","notify_customer_email":false}}''',
      ),
      'GET /api/v1/subscriptions/sub_2': (
        200,
        r'''{"data":{"id":"sub_2","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"manual","label":"x","notify_customer_email":false}}''',
      ),
      'GET /api/v1/orders/ord_1': (
        200,
        r'''{"data":{"id":"ord_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","amount_cents":9000,"currency":"BRL","status":"open","paid_at":null,"order_status":null,"refunded_amount_cents":0,"installments":0,"installment_interest_cents":0,"items":[],"metadata":{},"client_reference_id":"x","subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"discount_id":"disc_1","discount_code":"BEMVINDO","subtotal_cents":10000,"discount_cents":1000}}''',
      ),
      'GET /api/v1/prices/price_1': (
        200,
        r'''{"data":{"id":"price_1","product_id":"prod_1","currency":"BRL","amount_cents":9000,"type":"one_time","interval":"none","interval_count":0,"pricing_model":"fixed","unit_amount_cents":null,"tiers":[],"unit_label":"x","unit_label_plural":"x","minimum_units":null,"maximum_units":null,"status":"archived"}}''',
      ),
    };
    final (perata, seen) = client((request) {
      final (status, body) = answers['${request.method} ${request.url.path}']!;
      return json(status, jsonDecode(body));
    });
    final checkout = await perata.checkouts.create(
      const CheckoutsCreateParams(
        productId: 'prod_1',
        priceId: 'price_1',
        firstPeriodExtraDays: 30,
      ),
    );
    expect(
      (jsonDecode(seen[0].body)
          as Map<String, Object?>)['first_period_extra_days'],
      30,
    );
    expect(checkout.firstPeriodExtraDays, 30);
    expect(checkout.discountId, 'disc_1');
    final subscription = await perata.subscriptions.update(
      'sub_1',
      const SubscriptionsUpdateParams(extendCurrentPeriodDays: 15),
    );
    final sent = jsonDecode(seen[1].body) as Map<String, Object?>;
    expect(seen[1].method, 'PATCH');
    expect(sent['extend_current_period_days'], 15);
    expect(sent.containsKey('price_id'), isFalse);
    expect(subscription.firstPeriodExtraDays, 30);
    expect(subscription.discountId, 'disc_1');
    expect(subscription.discountEndsAt, '2027-03-01T03:00:00Z');
    final pending = subscription.pendingUpdate!;
    expect(
      (
        pending.priceId,
        pending.quantity,
        pending.amountCents,
        pending.effectiveAt,
      ),
      ('price_2', 5, 90000, '2026-12-20T03:00:00Z'),
    );
    final none = await perata.subscriptions.get('sub_2');
    expect(none.pendingUpdate, isNull);
    expect(none.firstPeriodExtraDays, isNull);
    expect(none.discountId, isNull);
    final order = await perata.orders.get('ord_1');
    expect(
      (
        order.subtotalCents,
        order.discountCents,
        order.discountId,
        order.discountCode,
      ),
      (10000, 1000, 'disc_1', 'BEMVINDO'),
    );
    final price = await perata.prices.get('price_1');
    expect(seen[4].url.path, '/api/v1/prices/price_1');
    expect(price.status, 'archived');
  });

  // The payment reads back its fee, its net, its split and the payout that pays
  // it.
  test('a payment reads back its fee, its split and its payout', () async {
    final (perata, _) = client(
      (_) => json(
        200,
        jsonDecode(
          r'''{"data":{"id":"pay_1","showcase_id":"x","checkout_id":"x","customer_id":"x","method":"card","state":"unknown","amount_cents":0,"captured_cents":0,"refunded_cents":0,"currency":"BRL","created_at":"2026-11-20T12:00:00Z","metadata":{},"client_reference_id":"x","installments":0,"installment_amount_cents":0,"installment_interest_cents":0,"subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"fee_cents":450,"net_cents":8550,"expected_payout_on":"2026-12-21","payout_deposited_on":null,"payout_id":null,"split":[{"recipient_id":"shw_2","amount_cents":9000,"fee_cents":450,"net_cents":8550}]}}''',
        ),
      ),
    );
    final payment = await perata.payments.get('pay_1');
    expect(payment.feeCents, 450);
    expect(payment.netCents, 8550);
    expect(payment.expectedPayoutOn, '2026-12-21');
    expect(payment.payoutId, isNull);
    expect(payment.payoutDepositedOn, isNull);
    expect(payment.split.length, 1);
    final split = payment.split[0];
    expect(
      (split.recipientId, split.amountCents, split.feeCents, split.netCents),
      ('shw_2', 9000, 450, 8550),
    );
  });

  // The balance carries its period, the payouts are filtered and walked page by
  // page, and a payout reads back its lines: a fee has no payment.
  test('the balance and the payouts read back what will be deposited', () async {
    final (perata, seen) = client((request) {
      final body = switch (request.url.path) {
        '/api/v1/balance' =>
          r'''{"data":{"total_to_receive_cents":100000,"released_cents":10000,"held_cents":5000,"scheduled_cents":60000,"later_cents":25000,"deposited_cents":42000,"period_from":"2026-11-01","period_to":"2026-11-20","currency":"BRL"}}''',
        '/api/v1/payouts/po_20261120' =>
          r'''{"data":{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2,"items":[{"kind":"sale","payment_id":"pay_1","installment":1,"status":"deposited","amount_cents":10000,"fee_cents":300,"net_cents":9700},{"kind":"fee","payment_id":null,"installment":0,"status":"deposited","amount_cents":0,"fee_cents":150,"net_cents":-150}]}}''',
        _ =>
          request.url.queryParameters['page'] == '2'
              ? r'''{"data":{"items":[{"id":"po_20261119","status":"released","expected_on":"2026-11-19","deposited_on":null,"amount_cents":5000,"fee_cents":200,"net_cents":4800,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}'''
              : r'''{"data":{"items":[{"id":"po_20261120","status":"deposited","expected_on":"2026-11-20","deposited_on":"2026-11-20","amount_cents":10000,"fee_cents":450,"net_cents":9550,"currency":"BRL","item_count":2}],"pagination":{"total_count":2,"max_page":2}}}''',
      };
      return json(200, jsonDecode(body));
    });
    final balance = await perata.balance.get(
      dateFrom: '2026-11-01',
      dateTo: '2026-11-20',
    );
    expect(seen[0].url.queryParameters, {
      'date_from': '2026-11-01',
      'date_to': '2026-11-20',
    });
    expect(balance.totalToReceiveCents, 100000);
    expect(
      balance.releasedCents +
          balance.heldCents +
          balance.scheduledCents +
          balance.laterCents,
      balance.totalToReceiveCents,
    );
    expect(
      (
        balance.depositedCents,
        balance.periodFrom,
        balance.periodTo,
        balance.currency,
      ),
      (42000, '2026-11-01', '2026-11-20', 'BRL'),
    );
    final walked = <String>[];
    await for (final payout in perata.payouts.listIter(
      status: 'deposited',
      dateFrom: '2026-11-01',
      sorting: '-date',
      limit: 1,
    )) {
      walked.add('${payout.id}:${payout.status}');
      expect(payout.netCents, payout.amountCents - payout.feeCents);
      expect(payout.status == 'deposited', payout.depositedOn != null);
    }
    expect(walked, ['po_20261120:deposited', 'po_20261119:released']);
    expect(seen[1].url.queryParameters, {
      'page': '1',
      'limit': '1',
      'status': 'deposited',
      'date_from': '2026-11-01',
      'sorting': '-date',
    });
    final payout = await perata.payouts.get('po_20261120');
    expect(payout.netCents, 9550);
    expect(payout.items.length, 2);
    final sale = payout.items[0];
    final fee = payout.items[1];
    expect(
      (sale.kind, sale.paymentId, sale.installment, sale.netCents),
      ('sale', 'pay_1', 1, 9700),
    );
    expect((fee.kind, fee.paymentId, fee.netCents), ('fee', null, -150));
  });

  // A checkout says how its subscription renews, the subscription reads back the
  // mode it resolved to, its label and whether the buyer is written to, an
  // update changes them, and the open renewal charge is read by its own route;
  // without one the API answers 404 no_open_charge.
  test('the renewal mode, the label and the open charge', () async {
    final answers = <String, (int, String)>{
      'POST /api/v1/checkouts': (
        201,
        r'''{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"Olho de Águia · Ana","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"x","first_period_extra_days":null,"renewal_mode":"automatic","notify_customer_email":false,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}''',
      ),
      'PATCH /api/v1/subscriptions/sub_1': (
        200,
        r'''{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null,"renewal_mode":"pix_automatic","label":"Olho de Águia · Ana","notify_customer_email":false}}''',
      ),
      'GET /api/v1/subscriptions/sub_1/open-charge': (
        200,
        r'''{"data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","reminder":null,"days_until_due":null,"notify_customer_email":true}}''',
      ),
    };
    final (perata, seen) = client((request) {
      final found = answers['${request.method} ${request.url.path}'];
      if (found == null) {
        return json(404, {
          'error': 'no_open_charge',
          'message': 'A assinatura não tem cobrança de renovação em aberto.',
        });
      }
      return json(found.$1, jsonDecode(found.$2));
    });
    const label = 'Olho de Águia · Ana';
    final checkout = await perata.checkouts.create(
      const CheckoutsCreateParams(
        productId: 'prod_1',
        priceId: 'price_1',
        renewalMode: 'automatic',
        notifyCustomerEmail: false,
        label: label,
      ),
    );
    var sent = jsonDecode(seen[0].body) as Map<String, Object?>;
    expect(
      (sent['renewal_mode'], sent['notify_customer_email'], sent['label']),
      ('automatic', false, label),
    );
    expect(
      (checkout.renewalMode, checkout.notifyCustomerEmail, checkout.label),
      ('automatic', false, label),
    );
    final subscription = await perata.subscriptions.update(
      'sub_1',
      const SubscriptionsUpdateParams(
        renewalMode: 'manual',
        notifyCustomerEmail: true,
        label: label,
      ),
    );
    sent = jsonDecode(seen[1].body) as Map<String, Object?>;
    expect(
      (sent['renewal_mode'], sent['notify_customer_email'], sent['label']),
      ('manual', true, label),
    );
    expect(
      (
        subscription.renewalMode,
        subscription.label,
        subscription.notifyCustomerEmail,
      ),
      ('pix_automatic', label, false),
    );
    final charge = await perata.subscriptions.getOpenCharge('sub_1');
    expect(seen[2].url.path, '/api/v1/subscriptions/sub_1/open-charge');
    expect(
      (
        charge.id,
        charge.subscriptionId,
        charge.amountCents,
        charge.renewalMode,
      ),
      ('rc_1', 'sub_1', 9000, 'manual'),
    );
    expect(
      (charge.paymentUrl, charge.dueAt, charge.expiresAt),
      (
        'https://perata.sh/pagar/rc_1',
        '2026-12-20T03:00:00Z',
        '2026-12-27T03:00:00Z',
      ),
    );
    expect(charge.reminder, isNull);
    expect(charge.daysUntilDue, isNull);
    expect(charge.notifyCustomerEmail, isTrue);
    await expectLater(
      perata.subscriptions.getOpenCharge('sub_2'),
      throwsA(
        isA<PerataException>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.code, 'code', 'no_open_charge'),
      ),
    );
  });

  // The renewal events carry the charge: due, and the reminder with its days.
  test('the renewal events carry the charge', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      (signedAt + 120) * 1000,
      isUtc: true,
    );
    final due = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_7',
        signedAt,
        'v1,BKbvaeGeiiLKhXAhfIIqaaxztbvGy5+Lj3u3m+Zec9w=',
      ),
      r'''{"id":"msg_7","type":"subscription.renewal_due","timestamp":"2026-10-22T12:00:00Z","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":null,"days_until_due":null}}''',
      now: now,
    );
    if (due is! RenewalChargeWebhookEvent) {
      fail('not a renewal event: $due');
    }
    expect(due.type, 'subscription.renewal_due');
    expect(due.data.id, 'rc_1');
    expect(due.data.paymentUrl, 'https://perata.sh/pagar/rc_1');
    expect(due.data.reminder, isNull);
    final reminder = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_8',
        signedAt,
        'v1,D1dd09VwdIBIDIq3Tp/yC+mhhlORnZyN/P/KU4sxX2Q=',
      ),
      r'''{"id":"msg_8","type":"subscription.renewal_reminder","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"rc_1","subscription_id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","cycle_sequence":2,"amount_cents":9000,"currency":"BRL","label":"Olho de Águia · Ana","renewal_mode":"manual","period_start":"2026-11-20T12:00:00Z","period_end":"2026-11-20T12:00:00Z","due_at":"2026-12-20T03:00:00Z","expires_at":"2026-12-27T03:00:00Z","payment_url":"https://perata.sh/pagar/rc_1","metadata":{},"client_reference_id":"x","notify_customer_email":true,"reminder":"before_due","days_until_due":3}}''',
      now: now,
    );
    if (reminder is! RenewalChargeWebhookEvent) {
      fail('not a renewal event: $reminder');
    }
    expect(reminder.type, 'subscription.renewal_reminder');
    expect(reminder.environment, 'live');
    expect(reminder.data.reminder, 'before_due');
    expect(reminder.data.daysUntilDue, 3);
  });

  test(
    'usage ingestion carries the source credential and its events',
    () async {
      final seen = <http.Request>[];
      final usage = Perata(
        'pus_live_source',
        baseUrl: 'https://perata.test/',
        httpClient: MockClient((request) async {
          seen.add(request);
          return json(200, {
            'data': {'created': 1, 'replayed': 0},
          });
        }),
      );
      final receipt = await usage.usage.ingest(
        const UsageIngestParams(
          events: [
            UsageIngestEvent(
              customerId: 'cus_1',
              externalEventId: 'req-1',
              inputTokens: '1200',
              outputTokens: '300',
              cachedTokens: '0',
              occurredAt: '2026-11-13T12:00:00Z',
              cost: UsageIngestEventCost(amount: '1.250000', currency: 'brl'),
            ),
          ],
        ),
      );
      expect(receipt.created, 1);
      expect(receipt.replayed, 0);
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/v1/usage/token-events');
      expect(seen.single.headers['authorization'], 'Bearer pus_live_source');
      final sent = jsonDecode(seen.single.body) as Map<String, Object?>;
      final events = sent['events'] as List<Object?>;
      expect(events, hasLength(1));
      final event = events.single as Map<String, Object?>;
      expect(event['customer_id'], 'cus_1');
      expect(event['_cost'], {'amount': '1.250000', 'currency': 'brl'});
      expect(event.containsKey('_llm'), isFalse);
      expect(event.containsKey('parent_id'), isFalse);
    },
  );

  test('usage ingestion errors are the flat error document', () async {
    const event = UsageIngestEvent(
      customerId: 'cus_1',
      externalEventId: 'req-1',
      inputTokens: '1',
      outputTokens: '0',
      cachedTokens: '0',
      occurredAt: '2026-11-13T12:00:00Z',
    );
    final cases = <(int, Map<String, Object?>, String, int, String)>[
      (401, {'error': 'invalid_credential'}, 'invalid_credential', 0, ''),
      (
        409,
        {'error': 'conflict', 'record': 2, 'message': 'conflict'},
        'conflict',
        2,
        'conflict',
      ),
      (
        422,
        {
          'error': 'invalid_request',
          'record': 3,
          'message': 'validation failed: customer_id',
          'fields': {
            'customer_id': ['unknown'],
          },
        },
        'invalid_request',
        3,
        'validation failed: customer_id',
      ),
      (
        400,
        {'error': 'invalid_request', 'message': 'malformed JSON'},
        'invalid_request',
        0,
        'malformed JSON',
      ),
      (
        415,
        {'error': 'unsupported_media_type'},
        'unsupported_media_type',
        0,
        '',
      ),
      (500, {'error': 'unavailable'}, 'unavailable', 0, ''),
    ];
    for (final (status, problem, code, record, message) in cases) {
      final (usage, _) = client((request) => json(status, problem));
      await expectLater(
        usage.usage.ingest(const UsageIngestParams(events: [event])),
        throwsA(
          isA<PerataException>()
              .having((error) => error.status, 'status', status)
              .having((error) => error.code, 'code', code)
              .having((error) => error.record, 'record', record)
              .having((error) => error.message, 'message', message)
              .having(
                (error) => error.fields['customer_id'],
                'fields',
                status == 422 ? ['unknown'] : isNull,
              ),
        ),
      );
    }
  });

  test('an error wrapped in data by an older server is still read', () async {
    const event = UsageIngestEvent(
      customerId: 'cus_1',
      externalEventId: 'req-1',
      inputTokens: '1',
      outputTokens: '0',
      cachedTokens: '0',
      occurredAt: '2026-11-13T12:00:00Z',
    );
    final (usage, _) = client(
      (request) => json(409, {
        'data': {'error': 'event_conflict', 'record': 2, 'message': 'conflict'},
      }),
    );
    await expectLater(
      usage.usage.ingest(const UsageIngestParams(events: [event])),
      throwsA(
        isA<PerataException>()
            .having((error) => error.code, 'code', 'event_conflict')
            .having((error) => error.record, 'record', 2),
      ),
    );
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

  test('a timestamp that is not plain digits is refused', () {
    for (final (stamp, signature) in [
      ('+1614265330', 'JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8='),
      ('²', 'PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY='),
      ('', 'x'),
      ('1_6', 'x'),
    ]) {
      final headers = {
        ...webhookHeaders(
          'msg_p5jXN8AQM9LWM0D4loKWxJek',
          0,
          'v1,$signature',
        ),
        'Webhook-Timestamp': stamp,
      };
      expect(
        () => verifyWebhookSignature(
          referenceSecret,
          headers,
          '{"test": 2432232314}',
          now: DateTime.fromMillisecondsSinceEpoch(1614265330000, isUtc: true),
        ),
        throwsA(isA<WebhookVerificationException>()),
        reason: stamp,
      );
    }
  });

  test('a webhook carries the environment it happened in', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      (signedAt + 120) * 1000,
      isUtc: true,
    );
    final older = [
      (
        'msg_2',
        'v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=',
        orderPaid,
      ),
      (
        'msg_3',
        'v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=',
        usageRecorded,
      ),
      ('msg_4', 'v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=', payoutSent),
    ];
    for (final (id, signature, body) in older) {
      final event = verifyWebhook(
        newSecret,
        webhookHeaders(id, signedAt, signature),
        body,
        now: now,
      );
      expect(event.environment, '', reason: id);
      expect(event.showcaseId, '', reason: id);
    }
    final order = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_5',
        signedAt,
        'v1,vJOO2qPe9Vzlr42VPwCuIO+a6Sg8ZVfl9z4WuLJItwg=',
      ),
      orderPaidLive,
      now: now,
    );
    expect(order, isA<OrderWebhookEvent>());
    expect(order.environment, 'live');
    expect(order.showcaseId, 'shw_1');
    expect((order as OrderWebhookEvent).data.showcaseId, 'shw_1');
    final unknown = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_6',
        signedAt,
        'v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM=',
      ),
      payoutSentTest,
      now: now,
    );
    expect(unknown, isA<UnknownWebhookEvent>());
    expect(unknown.environment, 'test');
    expect(unknown.showcaseId, '');
  });

  test('a webhook answers its typed event', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      (signedAt + 120) * 1000,
      isUtc: true,
    );
    final headers = webhookHeaders(
      'msg_2',
      signedAt,
      'v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= '
          'v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=',
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

  test('a redirect is refused and the key never follows it', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    var elsewhere = 0;
    other.listen((request) async {
      elsewhere++;
      await request.response.close();
    });
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => first.close(force: true));
    first.listen((request) async {
      request.response
        ..statusCode = 302
        ..headers.set('location', 'http://127.0.0.1:${other.port}/steal');
      await request.response.close();
    });
    final perata = Perata(
      'prk_test_key',
      baseUrl: 'http://${first.address.host}:${first.port}',
    );
    addTearDown(perata.close);

    await expectLater(
      perata.products.get('prod_1'),
      throwsA(
        isA<PerataException>().having((error) => error.status, 'status', 302),
      ),
    );
    expect(elsewhere, 0);
  });
}
