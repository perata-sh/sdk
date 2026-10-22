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
        // The webhook vectors every SDK checks: Standard Webhooks' own example,
        // and Peráta events signed under two secrets, as while one is rotated.
        static let referenceSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
        static let oldSecret = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
        static let newSecret = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
        static let orderPaid = Data(#"{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}"#.utf8)
        static let usageRecorded = Data(#"{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}"#.utf8)
        static let payoutSent = Data(#"{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}"#.utf8)
        static let signedAt = 1_792_670_400

        func webhookHeaders(_ id: String, _ at: Int, _ signature: String) -> [String: String] {
            ["Webhook-Id": id, "webhook-timestamp": String(at), "webhook-signature": signature]
        }

        func testTheStandardWebhooksVectorVerifies() throws {
            let body = Data(#"{"test": 2432232314}"#.utf8)
            let headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1_614_265_330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
            let at = Date(timeIntervalSince1970: 1_614_265_330)
            try verifyWebhookSignature(secret: Self.referenceSecret, headers: headers, body: body, now: at)
            for (secret, payload, now) in [
                (Self.referenceSecret, body + Data(" ".utf8), at),
                (Self.referenceSecret, body, at.addingTimeInterval(301)),
                (Self.newSecret, body, at),
            ] {
                XCTAssertThrowsError(try verifyWebhookSignature(secret: secret, headers: headers, body: payload, now: now)) {
                    XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
                }
            }
        }

        func testAWebhookAnswersItsTypedEvent() throws {
            let now = Date(timeIntervalSince1970: TimeInterval(Self.signedAt + 120))
            let headers = webhookHeaders("msg_2", Self.signedAt, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
            for secret in [Self.newSecret, Self.oldSecret] {
                guard case let .order(order) = try verifyWebhook(secret: secret, headers: headers, body: Self.orderPaid, now: now) else {
                    return XCTFail("not an order event")
                }
                XCTAssertEqual(order.type, "order.paid")
                XCTAssertEqual(order.data.id, "ord_1")
                XCTAssertEqual(order.data.installments, 3)
                XCTAssertEqual(order.data.installmentInterestCents, 360)
            }
            XCTAssertThrowsError(try verifyWebhook(secret: Self.referenceSecret, headers: headers, body: Self.orderPaid, now: now))
            let usage = try verifyWebhook(secret: Self.newSecret, headers: webhookHeaders("msg_3", Self.signedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), body: Self.usageRecorded, now: now)
            XCTAssertEqual(usage.id, "msg_3")
            guard case let .identifiers(identifiers) = usage else {
                return XCTFail("not an identifiers event")
            }
            XCTAssertEqual(identifiers.data["merchant_id"], "mer_1")
            let unknown = try verifyWebhook(secret: Self.newSecret, headers: webhookHeaders("msg_4", Self.signedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), body: Self.payoutSent, now: now)
            guard case let .unknown(event) = unknown else {
                return XCTFail("not an unknown event")
            }
            XCTAssertEqual(event.type, "payout.sent")
            XCTAssertEqual(event.body, Self.payoutSent)
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
