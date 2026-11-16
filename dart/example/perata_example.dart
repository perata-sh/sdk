import 'dart:io';

import 'package:perata_sdk/perata_sdk.dart';

/// Creates a product and lists every product of the organization whose key
/// is in PERATA_API_KEY. With PERATA_PRODUCT_ID and PERATA_PRICE_ID set, it
/// also opens a checkout session, the server's half of the embedded checkout:
/// only the client secret goes to the buyer's browser.
Future<void> main() async {
  final perata = Perata(Platform.environment['PERATA_API_KEY']!);
  try {
    final product = await perata.products.create(
      const ProductsCreateParams(name: 'Curso'),
      idempotencyKey: 'produto-curso',
    );
    stdout.writeln('created ${product.id}');

    await for (final product in perata.products.listIter()) {
      stdout.writeln(product.name);
    }

    final productId = Platform.environment['PERATA_PRODUCT_ID'];
    final priceId = Platform.environment['PERATA_PRICE_ID'];
    if (productId != null && priceId != null) {
      final checkout = await perata.checkouts.create(
        CheckoutsCreateParams(productId: productId, priceId: priceId),
      );
      stdout.writeln('hosted checkout ${checkout.url}');
      stdout.writeln('client secret for the browser ${checkout.clientSecret}');
      stdout.writeln('status key ${checkout.statusKey}');
    }
  } on PerataException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    perata.close();
  }
}
