import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// How far from now, in seconds, a webhook's timestamp may be.
public let webhookTolerance: TimeInterval = 300

/// What Peráta posts to an endpoint.
public struct WebhookEvent: Codable, Sendable, Hashable {
    /// The message's id, the same as the webhook-id header.
    public let id: String
    /// What happened: checkout_session.succeeded, payment.refunded…
    public let type: String
    /// When it happened.
    public let timestamp: String
    /// The ids of what it happened to.
    public let data: [String: String]

    public init(id: String, type: String, timestamp: String, data: [String: String] = [:]) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        data = try container.decodeIfPresent([String: String].self, forKey: .data) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case timestamp
        case data
    }
}

/// Why a webhook was not accepted.
public enum WebhookVerificationError: Error, Sendable, Equatable {
    /// The secret is not `whsec_` and a base64 key.
    case invalidSecret
    /// Peráta did not sign the request, or signed it too long ago.
    case invalidSignature
}

#if canImport(CryptoKit)
    /// Checks a webhook Peráta sent, as Standard Webhooks signs it — an
    /// HMAC-SHA256 of `{webhook-id}.{webhook-timestamp}.{body}` under the key
    /// the endpoint's `whsec_` secret encodes — and answers its event. Pass the
    /// body exactly as it arrived, before parsing it.
    ///
    /// - Parameters:
    ///   - headers: the request's headers, their names in any case.
    ///   - now: the moment to check the timestamp against.
    public func verifyWebhook(secret: String, headers: [String: String], body: Data, now: Date = Date()) throws -> WebhookEvent {
        let encoded = secret.hasPrefix("whsec_") ? String(secret.dropFirst("whsec_".count)) : secret
        guard let key = Data(base64Encoded: encoded), !key.isEmpty else {
            throw WebhookVerificationError.invalidSecret
        }
        func header(_ name: String) -> String {
            headers.first { $0.key.lowercased() == name }?.value ?? ""
        }
        let id = header("webhook-id")
        let stamp = header("webhook-timestamp")
        guard !id.isEmpty, let seconds = Int64(stamp) else {
            throw WebhookVerificationError.invalidSignature
        }
        guard abs(now.timeIntervalSince1970 - TimeInterval(seconds)) <= webhookTolerance else {
            throw WebhookVerificationError.invalidSignature
        }
        let signed = Data("\(id).\(stamp).".utf8) + body
        let symmetric = SymmetricKey(data: key)
        for signature in header("webhook-signature").split(whereSeparator: \.isWhitespace) {
            let parts = signature.split(separator: ",", maxSplits: 1)
            guard parts.count == 2, parts[0] == "v1", let decoded = Data(base64Encoded: String(parts[1])) else {
                continue
            }
            // isValidAuthenticationCode compares in constant time.
            if HMAC<SHA256>.isValidAuthenticationCode(decoded, authenticating: signed, using: symmetric) {
                return try JSONDecoder().decode(WebhookEvent.self, from: body)
            }
        }
        throw WebhookVerificationError.invalidSignature
    }
#endif
