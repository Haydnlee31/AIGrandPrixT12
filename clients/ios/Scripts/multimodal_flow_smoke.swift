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
struct NativeMultimodalFlowSmoke {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let origin = URL(string: "https://api.example.org")!
        let client = try CommonThreadClient(baseURL: origin, session: URLSession(configuration: config)) { "fixture-user" }
        var revision = 1, deleted = 0, corrections = 0
        var assets: [[String: Any]] = []
        var uploaded: [String] = []
        var analyzing = false
        var transcript = "A gift for my dad"
        var requests: [String] = []
        let product: [String: Any] = ["product_type": "Digital watch", "category_path": ["Accessories", "Watches", "Digital"],
            "brand": NSNull(), "model": NSNull(), "attributes": [["name": "shape", "value": "rectangular", "basis": "image", "evidence": "[image-1] rectangle", "certainty": "observed"]],
            "search_terms": ["LCD watch"], "use_cases": []]
        func capture() -> [String: Any] {
            let result: Any = analyzing ? [
                "analysis": ["schema_version": 1, "summary": "Watch", "products": [product], "intent_context": [transcript], "uncertainties": ["Brand unknown"]],
                "preview": ["schema_version": 2, "product_name": "Digital watch", "category_path": ["Accessories", "Watches", "Digital"],
                    "brand": NSNull(), "style": ["Vintage"], "summary": "A rectangular digital watch.", "uncertainties": ["Brand unknown"], "evidence": ["[image-1] rectangle"],
                    "prompts": [], "analyzed_at": 100], "source_assets": assets.map { $0["id"] as! String }
            ] as [String: Any] : NSNull()
            return ["id": "capture-1", "revision": revision, "status": analyzing ? "ready" : "pending", "stage": analyzing ? "ready" : "draft",
                "title": "Watch", "text": "", "note": "A gift", "url": NSNull(), "client": "ios_app", "assets": assets, "result": result,
                "error_code": NSNull(), "created_at": 1, "updated_at": 2, "published_save_id": NSNull()]
        }
        StubProtocol.handler = { request in
            let path = request.url!.path; requests.append(request.httpMethod! + " " + path)
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-user", "all native operations keep account auth")
            if path.hasSuffix("/capabilities") {
                return (200, try JSONSerialization.data(withJSONObject: ["enabled": true, "schema_version": 1,
                    "content_types": ["image/jpeg", "audio/mp4"], "max_assets": 5, "max_images": 4, "max_audio": 1, "max_asset_bytes": 4194304, "actions_execute": false]))
            }
            if request.httpMethod != "GET" { try check(request.value(forHTTPHeaderField: "Idempotency-Key") != nil, "every mutation has a key") }
            let body = (try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            if request.httpMethod == "DELETE" { deleted += 1; return (200, Data(#"{"deleted":true}"#.utf8)) }
            if path.hasSuffix("/assets") {
                let media = body["media_type"] as! String; uploaded.append(media)
                try check(body["revision"] as? Int == revision, "upload advances revision")
                let audio = media == "audio/mp4"
                assets.append(["id": audio ? "audio-1" : "image-\(assets.count + 1)", "kind": audio ? "audio" : "image",
                    "media_type": media, "size_bytes": 3, "status": "ready", "transcript": audio ? transcript as Any : NSNull()])
                revision += 1
            }
            if request.httpMethod == "PATCH" {
                corrections += 1; try check(body["revision"] as? Int == revision, "transcript update uses current revision")
                transcript = body["transcript"] as! String; assets[assets.count - 1]["transcript"] = transcript; revision += 1
            }
            if path.hasSuffix("/analyze") { try check(body["revision"] as? Int == revision, "analysis uses latest transcript revision"); analyzing = true }
            return (200, try JSONSerialization.data(withJSONObject: capture()))
        }
        let audio = try MultimodalDraftAnalysis.Audio(data: Data([1, 2, 3]), filename: "voice.m4a")
        let result = try await MultimodalDraftAnalysis.analyze(origin: origin, token: "unused", title: "Watch", text: "", note: "A gift", url: nil,
            images: [Data([1, 2, 3]), Data([4, 5, 6])], audio: audio, reviewedTranscript: "A gift for my mum", client: client)
        for _ in 0..<30 where deleted == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try check(uploaded == ["image/jpeg", "image/jpeg", "audio/mp4"], "all selected photos and voice reach the pipeline")
        try check(corrections == 1 && result.transcript == "A gift for my mum", "correction reaches asset before analysis and returns to local store")
        try check(result.productAnalysis?.products.first?.attributes.first?.value == "rectangular", "fine product attributes are retained")
        try check(result.searchableText.contains("LCD watch") && result.searchableText.contains("gift for my mum"), "local search includes detailed categories and speech")
        try check(deleted == 1 && !requests.contains(where: { $0.contains("/publish") }), "local analysis cleans temporary media and never silently publishes")
        let restored = try JSONDecoder().decode(CaptureIntelligenceResult.self, from: JSONEncoder().encode(result))
        try check(restored.transcript == result.transcript && restored.productAnalysis?.schemaVersion == 1, "rich result round-trips through real local metadata format")
        print("PASS native multi-image + voice upload, transcript correction, product facets, local search projection and cleanup")
        for bad in ["recording.mp3", "recording.webm"] {
            do { _ = try MultimodalDraftAnalysis.Audio(data: Data([1]), filename: bad); throw Failure.assertion("unsupported audio accepted") }
            catch MultimodalDraftAnalysis.Failure.unsupportedAudio {}
        }
        print("PASS unsupported recordings rejected before upload")
    }
}
