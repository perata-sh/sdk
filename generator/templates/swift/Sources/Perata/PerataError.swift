import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A request the API refused.
///
/// `code` is the API's: invalid_credential, forbidden, not_found,
/// invalid_request, conflict, idempotency_conflict, body_too_large or
/// unavailable; the usage ingestion adds invalid_events and event_conflict.
/// `fields` says, for invalid_request, what is wrong with each field. `record`
/// is, for the usage ingestion, the position (from 1) in the batch of the event
/// the API refused, and 0 for any other error. `retryAfter` is how long to wait
/// on a 429.
public struct PerataError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// The HTTP status.
    public let status: Int
    /// The API's code for the refusal.
    public let code: String
    /// What went wrong, for a person to read.
    public let message: String
    /// The problems of each field of the request.
    public let fields: [String: [String]]
    /// The event of a batch the API refused, from 1, or 0.
    public let record: Int
    /// How many seconds to wait before trying again.
    public let retryAfter: TimeInterval?

    public init(status: Int, code: String, message: String = "", fields: [String: [String]] = [:], retryAfter: TimeInterval? = nil, record: Int = 0) {
        self.status = status
        self.code = code
        self.message = message
        self.fields = fields
        self.record = record
        self.retryAfter = retryAfter
    }

    /// The error a refused response carries. A refusal without a JSON body is
    /// still a refusal.
    init(response: HTTPURLResponse, body: Data) {
        // The API's errors are the problem itself; the usage ingestion's are
        // wrapped in data, as its answers are.
        let wrapped = try? JSONDecoder().decode(Wrapped.self, from: body)
        let direct = try? JSONDecoder().decode(Body.self, from: body)
        let decoded = direct?.error == nil ? (wrapped?.data ?? direct) : direct
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map(TimeInterval.init)
        self.init(
            status: response.statusCode,
            code: decoded?.error ?? "",
            message: decoded?.message ?? "",
            fields: decoded?.fields ?? [:],
            retryAfter: retryAfter,
            record: decoded?.record ?? 0
        )
    }

    public var description: String {
        message.isEmpty ? "perata: \(status) \(code)" : "perata: \(status) \(code): \(message)"
    }

    public var errorDescription: String? { description }

    private struct Body: Decodable {
        let error: String?
        let message: String?
        let fields: [String: [String]]?
        let record: Int?
    }

    private struct Wrapped: Decodable {
        let data: Body?
    }
}
