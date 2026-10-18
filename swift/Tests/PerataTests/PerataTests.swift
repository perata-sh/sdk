import Foundation
import Perata
import XCTest

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(Network)
    import Network
#endif

/// The requests a fake transport was sent.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var seen: [URLRequest] {
        lock.withLock { requests }
    }
}

typealias Answer = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Any?)

func client(_ answer: @escaping Answer) -> (PerataClient, Recorder) {
    let recorder = Recorder()
    let transport: PerataTransport = { request in
        recorder.append(request)
        let (status, headers, body) = answer(request)
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }
    let perata = PerataClient(apiKey: "prk_test_key", baseURL: URL(string: "http://perata.test/")!, transport: transport)
    return (perata, recorder)
}

func product(_ id: String) -> [String: Any] {
    ["id": id, "name": "Curso", "description": "", "status": "active", "created_at": "2026-10-17T00:00:00Z"]
}

func queryItem(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

final class PerataTests: XCTestCase {
    func testACallCarriesTheKeyAndUnwrapsTheData() async throws {
        let (perata, recorder) = client { _ in (200, [:], ["data": product("prod_1")]) }
        let got = try await perata.products.get("prod_1")
        XCTAssertEqual(got.id, "prod_1")
        XCTAssertEqual(got.status, .active)
        XCTAssertEqual(got.createdAt, "2026-10-17T00:00:00Z")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertEqual(seen.url?.path, "/api/v1/products/prod_1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer prk_test_key")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "User-Agent"), "perata-swift/\(PerataClient.version)")
    }

    func testAWriteSendsItsBodyAndIdempotencyKey() async throws {
        let (perata, recorder) = client { _ in (201, [:], ["data": product("prod_1")]) }
        let created = try await perata.products.create(ProductsCreateParams(name: "Curso"), idempotencyKey: "create-1")
        XCTAssertEqual(created.name, "Curso")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Idempotency-Key"), "create-1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(seen.httpBody)) as? [String: String])
        // The optional description, left nil, is not sent.
        XCTAssertEqual(body, ["name": "Curso"])
    }

    func testIteratingWalksEveryPage() async throws {
        let (perata, recorder) = client { request in
            let page = queryItem(request, "page") ?? ""
            return (200, [:], ["data": ["items": [product("prod_\(page)")], "pagination": ["total_count": 3, "max_page": 3]]])
        }
        var ids: [String] = []
        for try await item in perata.products.listIter(limit: 1) {
            ids.append(item.id)
        }
        XCTAssertEqual(ids, ["prod_1", "prod_2", "prod_3"])
        XCTAssertEqual(queryItem(recorder.seen[0], "limit"), "1")
    }

    func testARefusalIsATypedError() async throws {
        let (perata, _) = client { request in
            if request.url?.path == "/api/v1/customers" {
                return (422, [:], ["error": "invalid_request", "fields": ["email": ["send an e-mail"]]])
            }
            return (429, ["Retry-After": "7"], nil)
        }
        do {
            _ = try await perata.customers.create(CustomersCreateParams(email: "x", name: "x"))
            XCTFail("a 422 was not refused")
        } catch let refused as PerataError {
            XCTAssertEqual(refused.status, 422)
            XCTAssertEqual(refused.code, "invalid_request")
            XCTAssertEqual(refused.fields["email"], ["send an e-mail"])
        }
        do {
            _ = try await perata.products.list()
            XCTFail("a 429 was not refused")
        } catch let limited as PerataError {
            XCTAssertEqual(limited.status, 429)
            XCTAssertEqual(limited.retryAfter, 7)
        }
    }

    #if canImport(CryptoKit)
        func testAWebhookVerifiesOnlyWhenPerataSignedIt() throws {
            let key = Data("0123456789abcdef0123456789abcdef".utf8)
            let secret = "whsec_" + key.base64EncodedString()
            let body = Data(#"{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}"#.utf8)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            func sign(_ at: Int, _ payload: Data) -> [String: String] {
                let mac = HMAC<SHA256>.authenticationCode(for: Data("msg_1.\(at).".utf8) + payload, using: SymmetricKey(data: key))
                return [
                    "Webhook-Id": "msg_1",
                    "webhook-timestamp": String(at),
                    "webhook-signature": "v1,bm90LXRoaXMtb25l v1," + Data(mac).base64EncodedString(),
                ]
            }
            let event = try verifyWebhook(secret: secret, headers: sign(1_800_000_000, body), body: body, now: now)
            XCTAssertEqual(event.type, "checkout_session.succeeded")
            XCTAssertEqual(event.data["checkout_session_id"], "cs_1")
            XCTAssertThrowsError(try verifyWebhook(secret: secret, headers: sign(1_800_000_000, body), body: body + Data(" ".utf8), now: now)) {
                XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
            }
            XCTAssertThrowsError(try verifyWebhook(secret: secret, headers: sign(1_800_000_000 - 600, body), body: body, now: now)) {
                XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
            }
        }
    #endif

    #if canImport(Network)
        func testTheRealHTTPSendsAndReadsThroughURLSession() async throws {
            let server = try EchoServer()
            let port = try await server.start()
            defer { server.stop() }
            let base = URL(string: "http://127.0.0.1:\(port)")!
            let perata = PerataClient(apiKey: "prk_test_key", baseURL: base)
            let created = try await perata.products.create(ProductsCreateParams(name: "Curso"), idempotencyKey: "create-1")
            XCTAssertEqual(created.name, "Curso")
            XCTAssertEqual(created.description, "create-1")
            XCTAssertEqual(created.createdAt, "POST /api/v1/products")
            do {
                _ = try await PerataClient(apiKey: "prk_test_other", baseURL: base).products.get("prod_1")
                XCTFail("a 401 was not refused")
            } catch let refused as PerataError {
                XCTAssertEqual(refused.status, 401)
                XCTAssertEqual(refused.code, "invalid_credential")
                XCTAssertEqual(refused.retryAfter, 3)
            }
        }
    #endif
}

#if canImport(Network)
    /// Answers what it was sent, wrapped as the API wraps a resource; a request
    /// without the test key is refused with a 401 and Retry-After 3.
    final class EchoServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "perata.echo")
        private var started = false

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.read(connection, Data())
            }
            return try await withCheckedThrowingContinuation { continuation in
                // The handler runs on the server's serial queue only.
                listener.stateUpdateHandler = { [self] state in
                    guard !started else { return }
                    switch state {
                    case .ready:
                        started = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        started = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }

        private static func read(_ connection: NWConnection, _ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if let answer = answer(buffer) {
                    connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, buffer)
                }
            }
        }

        /// The answer to a whole request, or nil while it has not all arrived.
        private static func answer(_ buffer: Data) -> Data? {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return nil
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else {
                return nil
            }
            let line = head[0].split(separator: " ")
            var status = "201 Created"
            var extra = ""
            var payload: [String: Any]
            if headers["authorization"] != "Bearer prk_test_key" {
                status = "401 Unauthorized"
                extra = "Retry-After: 3\r\n"
                payload = ["error": "invalid_credential"]
            } else {
                let sent = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any]
                payload = ["data": [
                    "id": "prod_1",
                    "name": sent?["name"] as? String ?? "",
                    "description": headers["idempotency-key"] ?? "",
                    "status": "active",
                    "created_at": "\(line[0]) \(line.count > 1 ? line[1] : "")",
                ]]
            }
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
            return Data(header.utf8) + json
        }
    }
#endif
