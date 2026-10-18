import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Sends one request and answers its body and response, whatever the status.
/// The SDK sends through `URLSession.shared`; a test, or a program with its
/// own HTTP stack, gives another one to `PerataClient`.
public typealias PerataTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// What a service calls the API through.
struct Requester: Sendable {
    let apiKey: String
    let baseURL: String
    let timeout: TimeInterval
    let transport: PerataTransport

    /// Calls the API and answers what it wrapped in `data`; a refusal throws
    /// `PerataError`.
    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [(String, String?)] = [],
        body: (any Encodable & Sendable)? = nil,
        idempotencyKey: String? = nil,
        apiKey: String? = nil
    ) async throws -> T {
        var address = baseURL + path
        let pairs = query.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(escape(name))=\(escape(value))"
        }
        if !pairs.isEmpty {
            address += "?" + pairs.joined(separator: "&")
        }
        guard let url = URL(string: address) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 } ?? self.apiKey
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("perata-swift/\(PerataClient.version)", forHTTPHeaderField: "User-Agent")
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await transport(request)
        if response.statusCode >= 300 {
            throw PerataError(response: response, body: data)
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    /// Sends through `URLSession.shared`.
    static let urlSession: PerataTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let data: T
}

private let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// A path parameter or a query value, escaped: everything but letters, digits
/// and `-._~`.
func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}
