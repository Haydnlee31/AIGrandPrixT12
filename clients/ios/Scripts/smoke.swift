// Standalone equivalent of the key SDK tests for CLT installations lacking a working SwiftPM/XCTest.
// Compiled alongside Sources/CommonThreadKit/*.swift; never connects to a network service.
import Foundation

private enum SmokeFailure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))!
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
            let (status, data, headers) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main
struct Smoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func fixture(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name).appendingPathExtension("json")) }
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try CommonThreadClient.decoder().decode(type, from: fixture(name)) }
        let capabilities = try decode(Capabilities.self, "capabilities")
        try check(capabilities.features["image_upload"] == false, "capability flag")
        _ = try decode(Account.self, "account"); _ = try decode(CaptureReceipt.self, "capture")
        _ = try decode(SavedItem.self, "pending"); _ = try decode(SavedItem.self, "saved")
        _ = try decode(CollectionPage.self, "collection"); _ = try decode(AnnotationReceipt.self, "annotation")
        _ = try decode(ItemList<Hypothesis>.self, "hypotheses"); _ = try decode(DiscoverySession.self, "session")
        _ = try decode(DiscoverySession.self, "budget"); _ = try decode(ItemList<DiscoverySession>.self, "discoveries")
        let shortlist = try decode(DiscoverySession.self, "shortlist")
        try check(!shortlist.products.isEmpty && shortlist.preferences["budget_minor"] == .integer(10000), "shortlist and exact minor units")
        _ = try decode(Catalog.self, "catalog"); _ = try decode(PriceWatch.self, "watch")
        _ = try decode(PriceWatch.self, "watch_update"); _ = try decode(ItemList<PriceWatch>.self, "watches")
        _ = try decode(PriceWatch.self, "watch_detail"); _ = try decode(JobStatus.self, "job")
        _ = try decode(JobReceipt.self, "simulation")
        let notifications = try decode(ItemList<AppNotification>.self, "notifications")
        try check(notifications.items.count == 1, "notification fixture")
        print("PASS 20 actual API response fixtures")

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try CommonThreadClient(baseURL: URL(string: "https://api.example.org")!, session: URLSession(configuration: config)) { "test-token" }
        for url in ["http://api.example.org", "https://api.example.org/v1", "https://user:pass@api.example.org", "https://api.example.org?x=1"] {
            do { _ = try CommonThreadClient(baseURL: URL(string: url)!) { "token" }; throw SmokeFailure.assertion("invalid URL accepted") }
            catch ClientError.invalidBaseURL {}
        }
        _ = try CommonThreadClient(baseURL: URL(string: "http://127.0.0.1:8000")!) { "token" }
        for (interval, timeout) in [(Double.nan, 30.0), (Double.infinity, 30.0), (1.0, Double.nan), (1.0, Double.infinity), (0.0, 30.0)] {
            do { _ = try await api.waitForEnrichment("save", interval: interval, timeout: timeout); throw SmokeFailure.assertion("invalid polling options accepted") }
            catch ClientError.invalidPollingOptions {}
        }
        print("PASS HTTPS/origin validation and nonfinite polling option rejection")
        let key = MutationKey(), capture = CaptureRequest(url: "https://example.org/desk", title: "Desk", client: .iosShareExtension)
        let receipt = try fixture("capture"); var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 { throw URLError(.networkConnectionLost) }
            return (201, receipt, [:])
        }
        do { _ = try await api.capture(capture, key: key); throw SmokeFailure.assertion("transport failure expected") } catch is URLError {}
        _ = try await api.capture(capture, key: key)
        try check(requests.count == 2, "exactly two caller-driven attempts")
        try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == key.rawValue }, "stable key")
        try check(requests[0].httpBody == requests[1].httpBody && requests[0].httpBody != nil, "stable payload")
        try check(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "injected auth")
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        try check(body["client"] as? String == "ios_share_extension" && body["selected_text"] as? String == "", "wire keys")
        print("PASS lost-response retry retains key, body, auth, and client origin")

        let denied = try fixture("unauthorized")
        StubProtocol.handler = { _ in (401, denied, [:]) }
        do { _ = try await api.account(); throw SmokeFailure.assertion("401 expected") }
        catch let error as APIError { try check(error.code == "unauthorized" && error.requestId != nil && !error.retryable, "typed 401") }
        let conflict = try fixture("stale_version"); var attempts = 0
        StubProtocol.handler = { _ in attempts += 1; return (409, conflict, [:]) }
        do { _ = try await api.apply(DiscoveryEvent(expectedVersion: 1, action: .retrieve), to: "session", key: MutationKey()); throw SmokeFailure.assertion("409 expected") }
        catch let error as APIError { try check(error.isVersionConflict && error.current?.version == 2, "current session conflict") }
        try check(attempts == 1, "no automatic conflict retry")
        StubProtocol.handler = { _ in (503, Data("unavailable".utf8), ["X-Request-ID": "proxy-id"]) }
        do { _ = try await api.account(); throw SmokeFailure.assertion("503 expected") }
        catch let error as APIError { try check(error.retryable && error.requestId == "proxy-id", "non-JSON error fallback") }
        print("PASS 401, stale-version snapshot, non-JSON 503 and request IDs")

        let pending = try fixture("pending"), ready = try fixture("saved"); var polls = 0
        StubProtocol.handler = { _ in polls += 1; return (200, polls == 1 ? pending : ready, [:]) }
        let result = try await api.waitForEnrichment("save", interval: 0.01, timeout: 1)
        try check(result.status == "ready" && polls == 2, "poll terminal state")
        StubProtocol.handler = { _ in (200, pending, [:]) }
        do { _ = try await api.waitForEnrichment("save", timeout: 0); throw SmokeFailure.assertion("timeout expected") }
        catch ClientError.pollingTimedOut(let item) { try check(item.status == "pending", "retained timeout state") }
        var failure = try JSONSerialization.jsonObject(with: pending) as! [String: Any]; failure["status"] = "enrichment_failed"
        let failureData = try JSONSerialization.data(withJSONObject: failure)
        StubProtocol.handler = { _ in (200, failureData, [:]) }
        let failed = try await api.waitForEnrichment("save")
        try check(failed.status == "enrichment_failed", "enrichment failure preserves save")
        print("PASS pending-to-ready polling, timeout, and enrichment failure")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://api.example.org")!
        let draft = PendingCapture(request: capture, accountId: "alex", baseURL: url), outbox = CaptureOutbox(directory: directory)
        try await outbox.enqueue(draft); try await outbox.enqueue(draft)
        let own = try await outbox.pending(accountId: "alex", baseURL: url)
        let otherUser = try await outbox.pending(accountId: "sam", baseURL: url)
        let otherServer = try await outbox.pending(accountId: "alex", baseURL: URL(string: "https://other.example.org")!)
        try check(own.count == 1 && own[0].key == draft.key && own[0].request == capture, "persist immutable intent")
        try check(otherUser.isEmpty && otherServer.isEmpty, "account and backend isolation")
        try await outbox.remove(draft)
        let removed = try await outbox.pending(accountId: "alex", baseURL: url)
        try check(removed.isEmpty, "remove on acknowledgment")
        print("PASS durable outbox, duplicate enqueue, account/backend isolation, removal")
        print("All standalone Swift checks passed.")
    }
}
