/// Peráta's SDK for Dart and Flutter.
///
/// ```dart
/// final perata = Perata(apiKey);
/// final product = await perata.products.create(
///   const ProductsCreateParams(name: 'Curso'),
/// );
/// await for (final product in perata.products.listIter()) { … }
/// ```
library;

export 'src/client.dart' show Perata;
export 'src/core.dart' show Requester;
export 'src/errors.dart' show PerataException;
export 'src/models.dart';
export 'src/pagination.dart' show Page;
export 'src/services.dart';
export 'src/version.dart' show apiVersion, defaultBaseUrl, sdkVersion;
export 'src/webhooks.dart';
