import 'dart:io';

import 'package:perata_sdk/perata_sdk.dart';

/// Creates a product and lists every product of the organization whose key
/// is in PERATA_API_KEY.
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
  } on PerataException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    perata.close();
  }
}
