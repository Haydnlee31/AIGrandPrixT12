import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CommonThreadKit

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            let (status, data, headers) = try Self.handler!(captured)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json")))
    }
    private func client() throws -> CommonThreadClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return try CommonThreadClient(baseURL: URL(string: "https://api.example.org")!, session: URLSession(configuration: config)) { "unit-test-token" }
    }
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    func testActualAPIResponsesDecode() throws {
        let decoder = CommonThreadClient.decoder()
        XCTAssertEqual(try decoder.decode(Capabilities.self, from: fixture("capabilities")).features["image_upload"], false)
        XCTAssertEqual(try decoder.decode(Account.self, from: fixture("account")).userId, "fixture-user")
        XCTAssertEqual(try decoder.decode(CaptureReceipt.self, from: fixture("capture")).status, "pending")
        XCTAssertTrue(try decoder.decode(SavedItem.self, from: fixture("pending")).isEnriching)
        XCTAssertEqual(try decoder.decode(SavedItem.self, from: fixture("saved")).suggestions.count, 4)
        XCTAssertFalse(try decoder.decode(CollectionPage.self, from: fixture("collection")).items.isEmpty)
        XCTAssertNotNil(try decoder.decode(AnnotationReceipt.self, from: fixture("annotation")).hypothesis)
        XCTAssertEqual(try decoder.decode(ItemList<Hypothesis>.self, from: fixture("hypotheses")).items.count, 1)
        XCTAssertEqual(try decoder.decode(DiscoverySession.self, from: fixture("session")).version, 1)
        XCTAssertEqual(try decoder.decode(DiscoverySession.self, from: fixture("budget")).preferences["budget_minor"], .integer(10000))
        XCTAssertFalse(try decoder.decode(DiscoverySession.self, from: fixture("shortlist")).products.isEmpty)
        XCTAssertEqual(try decoder.decode(ItemList<DiscoverySession>.self, from: fixture("discoveries")).items.count, 1)
        XCTAssertEqual(try decoder.decode(Catalog.self, from: fixture("catalog")).items.count, 4)
        XCTAssertEqual(try decoder.decode(PriceWatch.self, from: fixture("watch")).targetMinor, 7000)
        XCTAssertEqual(try decoder.decode(PriceWatch.self, from: fixture("watch_update")).targetMinor, 7100)
        XCTAssertEqual(try decoder.decode(ItemList<PriceWatch>.self, from: fixture("watches")).items.count, 1)
        XCTAssertEqual(try decoder.decode(PriceWatch.self, from: fixture("watch_detail")).targetMinor, 7100)
        XCTAssertEqual(try decoder.decode(JobReceipt.self, from: fixture("simulation")).dataMode, "simulated")
        XCTAssertEqual(try decoder.decode(JobStatus.self, from: fixture("job")).status, "done")
        XCTAssertEqual(try decoder.decode(ItemList<AppNotification>.self, from: fixture("notifications")).items.count, 1)
    }
    func testCaptureRetryRetainsPayloadAndKeyAfterTransportFailure() async throws {
        let response = try fixture("capture")
        let api = try client(); let key = MutationKey()
        let capture = CaptureRequest(url: "https://example.org/desk", title: "Desk", note: "Warm lighting", client: .iosShareExtension)
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 { throw URLError(.networkConnectionLost) }
            return (201, response, [:])
        }
        do { _ = try await api.capture(capture, key: key); XCTFail("Expected lost connection") } catch is URLError {}
        _ = try await api.capture(capture, key: key)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), key.rawValue)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), key.rawValue)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertNotNil(requests[1].httpBody)
        XCTAssertEqual(requests[1].url?.path, "/v1/saves")
        let encoded = try JSONSerialization.jsonObject(with: CommonThreadClient.encoder().encode(capture)) as! [String: Any]
        XCTAssertEqual(encoded["client"] as? String, "ios_share_extension")
        XCTAssertEqual(encoded["selected_text"] as? String, "")
    }
    func testUnauthorizedPreservesErrorRequestID() async throws {
        let data = try fixture("unauthorized"); let api = try client()
        MockURLProtocol.handler = { _ in (401, data, [:]) }
        do { _ = try await api.account(); XCTFail("Expected unauthorized") }
        catch let error as APIError {
            XCTAssertEqual(error.status, 401); XCTAssertEqual(error.code, "unauthorized")
            XCTAssertFalse(error.retryable); XCTAssertNotNil(error.requestId)
        }
    }
    func testStaleVersionReturnsCurrentSessionWithoutRetrying() async throws {
        let data = try fixture("stale_version"); let api = try client(); var count = 0
        MockURLProtocol.handler = { _ in count += 1; return (409, data, [:]) }
        do { _ = try await api.apply(DiscoveryEvent(expectedVersion: 1, action: .direction, value: .text("warm")), to: "session", key: MutationKey()); XCTFail("Expected conflict") }
        catch let error as APIError {
            XCTAssertTrue(error.isVersionConflict); XCTAssertEqual(error.current?.version, 2)
            XCTAssertEqual(error.current?.preferences["budget_minor"], .integer(10000))
        }
        XCTAssertEqual(count, 1)
    }
    func testNonJSONErrorUsesHeaderRequestID() async throws {
        let api = try client()
        MockURLProtocol.handler = { _ in (503, Data("temporarily unavailable".utf8), ["X-Request-ID": "proxy-id"]) }
        do { _ = try await api.account(); XCTFail("Expected unavailable") }
        catch let error as APIError { XCTAssertTrue(error.retryable); XCTAssertEqual(error.requestId, "proxy-id") }
    }
    func testPollingStopsWhenReadyAndRetainsPendingOnTimeout() async throws {
        let pending = try fixture("pending"), ready = try fixture("saved"), api = try client()
        var count = 0
        MockURLProtocol.handler = { _ in count += 1; return (200, count == 1 ? pending : ready, [:]) }
        let result = try await api.waitForEnrichment("save", interval: 0.01, timeout: 1)
        XCTAssertEqual(result.status, "ready"); XCTAssertEqual(count, 2)
        MockURLProtocol.handler = { _ in (200, pending, [:]) }
        do { _ = try await api.waitForEnrichment("save", timeout: 0); XCTFail("Expected pending timeout") }
        catch ClientError.pollingTimedOut(let lastKnown) { XCTAssertEqual(lastKnown.status, "pending") }
    }
    func testEnrichmentFailureIsReturnedAsStoredSave() async throws {
        let api = try client()
        var payload = try JSONSerialization.jsonObject(with: fixture("pending")) as! [String: Any]
        payload["status"] = "enrichment_failed"
        let data = try JSONSerialization.data(withJSONObject: payload)
        MockURLProtocol.handler = { _ in (200, data, [:]) }
        let result = try await api.waitForEnrichment("save")
        XCTAssertEqual(result.status, "enrichment_failed")
    }
    func testOutboxRoundTripScopesAccountAndRetainsKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://api.example.org")!
        let draft = PendingCapture(request: CaptureRequest(url: "https://example.org/desk", title: "Desk"), accountId: "alex", baseURL: url)
        let outbox = CaptureOutbox(directory: directory)
        try await outbox.enqueue(draft); try await outbox.enqueue(draft)
        let sameAccount = try await outbox.pending(accountId: "alex", baseURL: url)
        XCTAssertEqual(sameAccount.count, 1); XCTAssertEqual(sameAccount.first?.key, draft.key); XCTAssertEqual(sameAccount.first?.request, draft.request)
        let otherAccount = try await outbox.pending(accountId: "sam", baseURL: url)
        XCTAssertTrue(otherAccount.isEmpty)
        let otherServer = try await outbox.pending(accountId: "alex", baseURL: URL(string: "https://other.example.org")!)
        XCTAssertTrue(otherServer.isEmpty)
        try await outbox.remove(draft)
        let removed = try await outbox.pending(accountId: "alex", baseURL: url)
        XCTAssertTrue(removed.isEmpty)
    }
    func testConfigurationAndPollingRejectInvalidValues() async throws {
        for url in ["http://api.example.org", "https://api.example.org/v1", "https://user:pass@api.example.org", "https://api.example.org?x=1"] {
            XCTAssertThrowsError(try CommonThreadClient(baseURL: URL(string: url)!) { "token" })
        }
        _ = try CommonThreadClient(baseURL: URL(string: "http://127.0.0.1:8000")!) { "token" }
        let api = try client()
        for (interval, timeout) in [(Double.nan, 30.0), (Double.infinity, 30.0), (1.0, Double.nan), (1.0, Double.infinity), (0.0, 30.0)] {
            do { _ = try await api.waitForEnrichment("save", interval: interval, timeout: timeout); XCTFail("Expected invalid poll options") }
            catch ClientError.invalidPollingOptions {}
        }
    }
}
