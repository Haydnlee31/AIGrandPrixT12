// No provider keys, API services, local Library files, or microphone access are used.
import Foundation
import CommonThreadKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum Failure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.assertion(message) }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = data
            }
            let (status, data) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct SharedMultimodalSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mymah-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let origin = URL(string: "https://api.example.org")!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let client = try CommonThreadClient(baseURL: origin, session: URLSession(configuration: config)) { "user-alice" }
        var revision = 1, uploaded = 0, published = 0, dropped = false, ready = false, deleted = false
        var replays: [String: Data] = [:]
        var keys: [String] = []
        func capture() -> [String: Any] {
            var assets: [[String: Any]] = []
            for index in 0..<uploaded {
                assets.append(["id": "asset-\(index)", "kind": index == 2 ? "audio" : "image", "media_type": index == 2 ? "audio/mp4" : "image/jpeg", "size_bytes": 3,
                    "status": "ready", "transcript": index == 2 ? "A gift for my mum" as Any : NSNull()])
            }
            let result: Any = ready ? [
                "analysis": ["schema_version": 1, "summary": "Watch", "products": [], "intent_context": [], "uncertainties": []],
                "preview": ["schema_version": 2, "product_name": "Watch", "category_path": ["Accessories", "Watches"], "brand": NSNull(), "style": [],
                    "summary": "Watch", "uncertainties": [], "evidence": [], "prompts": [], "analyzed_at": 1], "source_assets": []
            ] as [String: Any] : NSNull()
            return ["id": "capture-1", "revision": revision, "status": ready ? "ready" : "pending", "stage": ready ? "ready" : "draft", "title": "Watch",
                "text": "", "note": "", "url": NSNull(), "client": "ios_app", "assets": assets, "result": result, "error_code": NSNull(),
                "created_at": 1, "updated_at": 2, "published_save_id": published > 0 ? "shared-watch" as Any : NSNull()]
        }
        StubProtocol.handler = { request in
            let path = request.url!.path
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-alice", "shared mutation keeps current account")
            if path == "/v1/me" || path == "/v1/account" {
                return (200, Data(#"{"user_id":"alice","demo_mode":false,"inference_provider":"astra"}"#.utf8))
            }
            let key = request.value(forHTTPHeaderField: "Idempotency-Key")
            if let key {
                keys.append(key)
                if let receipt = replays[key] { return (200, receipt) }
            }
            let body = (try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            if path.hasSuffix("/assets") { try check(body["revision"] as? Int == revision, "shared upload uses checkpointed revision"); uploaded += 1; revision += 1 }
            if request.httpMethod == "PATCH" { try check(body["transcript"] as? String == "A gift for my mum", "reviewed transcript survives queue storage"); revision += 1 }
            if path.hasSuffix("/analyze") { ready = true }
            let response: Data
            if path.hasSuffix("/publish") { published += 1; response = Data(#"{"id":"shared-watch","status":"ready","duplicate":false}"#.utf8) }
            else if request.httpMethod == "DELETE" { deleted = true; response = Data(#"{"deleted":true}"#.utf8) }
            else { response = try JSONSerialization.data(withJSONObject: capture()) }
            if let key { replays[key] = response }
            if uploaded == 2 && !dropped { dropped = true; throw URLError(.networkConnectionLost) }
            return (200, response)
        }
        let entry = PendingSharedMultimodal(id: "stable-save", accountID: "alice", origin: origin, localID: "local-recovery",
            request: .init(title: "Watch", text: "A watch"), attachments: [
                .init(filename: "one.jpg", typeIdentifier: "public.jpeg", data: Data([1, 2, 3])),
                .init(filename: "two.jpg", typeIdentifier: "public.jpeg", data: Data([4, 5, 6])),
                .init(filename: "voice.m4a", typeIdentifier: "com.apple.m4a-audio", data: Data([7, 8, 9]))], reviewedTranscript: "A gift for my mum")
        let first = SharedMultimodalOutbox(file: file)
        try await first.enqueue(entry)
        do { _ = try await first.send(entry.id, client: client, accountID: "alice", origin: origin); throw Failure.assertion("expected interrupted response") }
        catch is URLError {}
        let checkpoint = try await first.pending(accountID: "alice", origin: origin)
        try check(checkpoint.count == 1 && checkpoint[0].uploaded == 1, "acknowledged progress survives response loss")
        let reopened = SharedMultimodalOutbox(file: file)
        do { _ = try await reopened.send(entry.id, client: client, accountID: "bob", origin: origin); throw Failure.assertion("another account used queue") }
        catch SharedMultimodalOutbox.Failure.missing {}
        let receipt = try await reopened.send(entry.id, client: client, accountID: "alice", origin: origin)
        let remaining = try await reopened.pending(accountID: "alice", origin: origin)
        try check(receipt.id == "shared-watch" && remaining.isEmpty && published == 1 && uploaded == 3, "restart retries lost response without duplicate assets or publication")
        try check(keys.filter { $0 == "stable-save-asset-1" }.count == 2, "exact failed operation reuses its durable idempotency key")
        try check(!deleted, "successful shared publication retains its server media")
        let persisted = try String(contentsOf: file, encoding: .utf8)
        try check(!persisted.contains("user-alice"), "queue never persists bearer credentials")
        print("PASS shared multi-image + voice publication, interrupted upload replay, restart, account isolation and credential exclusion")
    }
}
