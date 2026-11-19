/// What a service calls the API through: [Perata], or a fake in a test.
abstract interface class Requester {
  /// Calls the API and answers the object it wrapped in `data`.
  ///
  /// A null or empty value in [query] is left out, and a [Map] in it is sent
  /// as one `name[key]=value` pair a key. [idempotencyKey] makes a write safe
  /// to repeat: a 2xx answer stays under the key, and a 4xx or 5xx frees it, so
  /// the same key can be sent again; [apiKey] sends this call with another
  /// organization's key.
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?> query,
    Map<String, Object?>? body,
    String? idempotencyKey,
    String? apiKey,
  });
}
