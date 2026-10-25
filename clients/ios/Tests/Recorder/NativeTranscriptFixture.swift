import Foundation

actor NativeTranscriptProgress {
    private var texts: [String] = []
    private var beforeReady = false
    func record(_ text: String, beforeReady: Bool) {
        texts.append(text); self.beforeReady = self.beforeReady || beforeReady
    }
    func snapshot() -> (texts: [String], beforeReady: Bool) { (texts, beforeReady) }
}

/// Explicit HTTP fixture, not an AI replacement in production. It accepts real
/// recorder bytes then exposes a transcript while product analysis is pending.
final class NativeTranscriptFixture: @unchecked Sendable {
    static let transcript = "Fixture transcript: a vintage digital watch for my dad."
    private let lock = NSLock()
    private let expectedAudio: Data
    private var uploaded = false
    private var deleted = false
    private var analyzing = false
    private var polls = 0
    init(expectedAudio: Data) { self.expectedAudio = expectedAudio }
    var uploadMatched: Bool { lock.withLock { uploaded } }
    var wasDeleted: Bool { lock.withLock { deleted } }
    var isStillAnalyzing: Bool { lock.withLock { analyzing && polls == 1 } }

    func response(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer native-fixture-user",
                  request.httpMethod == "GET" || request.value(forHTTPHeaderField: "Idempotency-Key") != nil else {
                throw FixtureError.invalidRequest
            }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/capabilities") {
                return try JSONSerialization.data(withJSONObject: ["enabled": true, "schema_version": 1,
                    "content_types": ["audio/mp4"], "max_assets": 5, "max_images": 4, "max_audio": 1,
                    "max_asset_bytes": 4194304, "actions_execute": false])
            }
            if request.httpMethod == "DELETE" {
                deleted = true
                return Data(#"{"deleted":true}"#.utf8)
            }
            let body = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            if path.hasSuffix("/assets") {
                guard body?["media_type"] as? String == "audio/mp4",
                      body?["revision"] as? Int == 1,
                      let encoded = body?["data_base64"] as? String,
                      Data(base64Encoded: encoded) == expectedAudio else { throw FixtureError.invalidAudio }
                uploaded = true
            }
            if path.hasSuffix("/analyze") {
                guard uploaded, body?["revision"] as? Int == 2 else { throw FixtureError.invalidRequest }
                analyzing = true
            }
            if request.httpMethod == "GET", path.hasSuffix("/native-capture"), analyzing { polls += 1 }
            let ready = polls > 1
            let assets: [[String: Any]] = uploaded ? [["id": "native-audio", "kind": "audio", "media_type": "audio/mp4",
                "size_bytes": expectedAudio.count, "status": polls > 0 ? "ready" : "pending",
                "transcript": polls > 0 ? Self.transcript as Any : NSNull()]] : []
            let result: Any = ready ? [
                "analysis": ["schema_version": 1, "summary": "Digital watch", "products": [],
                    "intent_context": [Self.transcript], "uncertainties": ["Fixture has no product photo"]],
                "preview": ["schema_version": 2, "product_name": "Digital watch", "category_path": ["Accessories", "Watches"],
                    "brand": NSNull(), "style": ["Vintage"], "summary": "A digital watch.",
                    "uncertainties": [], "evidence": ["[native-audio] fixture transcript"], "prompts": [], "analyzed_at": 100],
                "source_assets": ["native-audio"]
            ] as [String: Any] : NSNull()
            return try JSONSerialization.data(withJSONObject: ["id": "native-capture", "revision": uploaded ? 2 : 1,
                "status": ready ? "ready" : "pending", "stage": ready ? "ready" : analyzing ? "analyzing" : "draft",
                "title": "Recorded voice", "text": "", "note": "", "url": NSNull(), "client": "ios_app",
                "assets": assets, "result": result, "error_code": NSNull(), "created_at": 1, "updated_at": 2,
                "published_save_id": NSNull()])
        }
    }
    private enum FixtureError: Error { case invalidRequest, invalidAudio }
}

final class NativeTranscriptProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: NativeTranscriptFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = bytes
            }
            guard let fixture = Self.fixture, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
            let data = try fixture.response(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
