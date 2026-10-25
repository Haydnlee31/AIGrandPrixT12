// No provider keys, API services, local Library files, or microphone access are used.
import Foundation
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

private actor ProgressLog {
    private var captures: [MultimodalCapture] = []
    func append(_ capture: MultimodalCapture) { captures.append(capture) }
    func values() -> [MultimodalCapture] { captures }
}

@main
struct MultimodalSmoke {
    static func main() async throws {
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let result: [String: Any] = [
            "analysis": ["schema_version": 1, "summary": "A saved watch.", "products": [], "intent_context": [], "uncertainties": []],
            "preview": ["schema_version": 2, "product_name": "Watch", "category_path": ["Accessories", "Watches"],
                "brand": NSNull(), "style": [], "summary": "A saved watch.", "uncertainties": [], "evidence": [], "prompts": [], "analyzed_at": 100],
            "source_assets": ["image-1"]
        ]
        func capture(_ status: String = "pending", stage: String = "analyzing", revision: Int = 3) -> [String: Any] {
            ["id": "capture-1", "revision": revision, "status": status, "stage": stage, "title": "A watch", "text": "", "note": "A gift",
             "url": NSNull(), "client": "ios_app", "assets": [["id": "image-1", "media_type": "image/png", "kind": "image", "size_bytes": 23, "status": "ready", "transcript": NSNull()]],
             "result": status == "ready" ? result : NSNull(), "error_code": NSNull(), "created_at": 100, "updated_at": 101,
             "published_save_id": NSNull(), "future_optional_field": ["ignored": true]]
        }
        let ready = try data(capture("ready", stage: "ready"))
        let pending = try data(capture())
        let decoded = try CommonThreadClient.decoder().decode(MultimodalCapture.self, from: ready)
        try check(decoded.result?.preview.schemaVersion == 2 && decoded.result?.analysis.schemaVersion == 1, "both analysis contracts decode")
        try check(decoded.result?.preview.brand == nil && decoded.publishedSaveId == nil, "unknown identity and unpublished state stay nil")
        try check(decoded.assets[0].mediaType == "image/png" && decoded.result?.sourceAssets == ["image-1"], "asset metadata and evidence IDs decode")
        var future = capture("ready", stage: "ready")
        var futureResult = result
        var futureAnalysis = result["analysis"] as! [String: Any]
        futureAnalysis["schema_version"] = 2; futureResult["analysis"] = futureAnalysis; future["result"] = futureResult
        do { _ = try CommonThreadClient.decoder().decode(MultimodalCapture.self, from: data(future)); throw Failure.assertion("unsupported result version accepted") }
        catch is DecodingError {}
        print("PASS shared product analysis and native preview decode with unknown fields")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let api = try CommonThreadClient(baseURL: URL(string: "https://api.example.org")!, session: URLSession(configuration: configuration)) { "fixture-token" }
        let key = try MutationKey("retained-action")
        var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if request.url!.path.hasSuffix("/publish") { return (200, try data(["id": "save-1", "status": "ready", "duplicate": false])) }
            if request.httpMethod == "DELETE" && !request.url!.path.contains("/assets/") { return (200, try data(["deleted": true])) }
            return (200, pending)
        }
        _ = try await api.createMultimodalCapture(.init(note: "A gift", client: .iosShareExtension), key: key)
        let upload = try MultimodalAssetRequest(revision: 2, mediaType: "audio/wav", data: Data([1, 2, 3]))
        _ = try await api.uploadMultimodalAsset(to: "capture-1", request: upload, key: key)
        _ = try await api.uploadMultimodalAsset(to: "capture-1", request: upload, key: key)
        _ = try await api.updateMultimodalCapture("capture-1", edit: .init(revision: 3, note: ""), key: key)
        _ = try await api.updateMultimodalTranscript("audio-1", in: "capture-1", edit: .init(revision: 4, transcript: "A gift for Dad"), key: key)
        _ = try await api.analyzeMultimodalCapture("capture-1", revision: 4, key: key)
        _ = try await api.deleteMultimodalAsset("image-1", from: "capture-1", revision: 4, key: key)
        let published = try await api.publishMultimodalCapture("capture-1", revision: 5, key: key)
        let deleted = try await api.deleteMultimodalCapture("capture-1", key: key)
        try check(requests.count == 9 && published.id == "save-1" && deleted.deleted, "explicit publish and delete receipts")
        try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" && $0.value(forHTTPHeaderField: "Idempotency-Key") == key.rawValue }, "existing transport auth and retained keys")
        try check(requests[1].httpBody == requests[2].httpBody, "unchanged upload retries preserve exact bytes")
        let encodedUpload = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        try check(encodedUpload["media_type"] as? String == "audio/wav" && encodedUpload["data_base64"] as? String == "AQID" && encodedUpload["revision"] as? Int == 2, "upload wire fields")
        let edit = try JSONSerialization.jsonObject(with: requests[3].httpBody!) as! [String: Any]
        try check(edit["note"] as? String == "" && edit["title"] == nil, "empty string clears note while nil preserves title")
        let transcriptEdit = try JSONSerialization.jsonObject(with: requests[4].httpBody!) as! [String: Any]
        try check(requests[4].httpMethod == "PATCH" && requests[4].url!.path.hasSuffix("/assets/audio-1") && transcriptEdit["transcript"] as? String == "A gift for Dad" && transcriptEdit["revision"] as? Int == 4, "transcript review keeps explicit revision and content")
        try check(requests[6].httpMethod == "DELETE" && requests[6].url!.path.hasSuffix("/assets/image-1") && requests[6].httpBody != nil, "asset deletion carries expected revision")
        try check(requests[8].httpBody == nil, "capture deletion has no invented payload")
        print("PASS multimodal routes, revision bodies, stable retries, and explicit publication")

        let beforeInvalid = requests.count
        for id in ["", "..", "../capture", "a/b", "a\\b", "id\n"] {
            do { _ = try await api.multimodalCapture(id); throw Failure.assertion("invalid ID accepted") }
            catch MultimodalClientError.invalidIdentifier {}
        }
        do { _ = try await api.analyzeMultimodalCapture("capture-1", revision: 0, key: key); throw Failure.assertion("invalid revision accepted") }
        catch MultimodalClientError.invalidRevision {}
        try check(requests.count == beforeInvalid, "invalid requests never reach transport")
        print("PASS invalid ID/revision rejection before network access")

        var polls = 0
        StubProtocol.handler = { request in
            try check(request.httpMethod == "GET", "polling never publishes or mutates")
            polls += 1
            return (200, polls == 1 ? try data(capture(stage: "transcribing")) : polls == 2 ? pending : ready)
        }
        let completed = try await api.waitForMultimodalCapture("capture-1", expectedRevision: 3, interval: 0.1, timeout: 2)
        try check(completed.status == "ready" && polls == 3, "pending transcription and analysis both wait")
        StubProtocol.handler = { _ in (200, try data(capture("ready", stage: "ready", revision: 4))) }
        do { _ = try await api.waitForMultimodalCapture("capture-1", expectedRevision: 3); throw Failure.assertion("stale result accepted") }
        catch MultimodalClientError.staleRevision(let expected, let actual) { try check(expected == 3 && actual == 4, "stale revision preserved") }
        var failed = capture("enrichment_failed", stage: "failed"); failed["error_code"] = "astra_rate_limited"
        let failure = try data(failed)
        StubProtocol.handler = { _ in (200, failure) }
        do { _ = try await api.waitForMultimodalCapture("capture-1"); throw Failure.assertion("failure accepted") }
        catch MultimodalClientError.analysisFailed(let code) { try check(code == "astra_rate_limited", "terminal error retained") }
        print("PASS stage polling, edited-revision rejection, and terminal analysis failure")

        func withTranscript(_ value: [String: Any]) -> [String: Any] {
            var item = value
            item["assets"] = [["id": "audio-1", "media_type": "audio/mp4", "kind": "audio", "size_bytes": 123,
                               "status": "ready", "transcript": "A birthday gift for Dad", "transcript_origin": "provider"]]
            return item
        }
        let transcribedPending = try data(withTranscript(capture(stage: "analyzing")))
        let transcribedReady = try data(withTranscript(capture("ready", stage: "ready")))
        let progress = ProgressLog()
        polls = 0
        StubProtocol.handler = { _ in polls += 1; return (200, polls == 1 ? transcribedPending : transcribedReady) }
        _ = try await api.waitForMultimodalCapture("capture-1", expectedRevision: 3, interval: 0.1, timeout: 2,
                                                  onProgress: { await progress.append($0) })
        let stages = await progress.values()
        try check(stages.map(\.status) == ["pending", "ready"], "transcript progress is delivered while product analysis is still pending")
        try check(stages.first?.assets.first?.transcript == "A birthday gift for Dad", "early progress retains transcribed speech")
        let failedProgress = ProgressLog()
        polls = 0
        StubProtocol.handler = { _ in polls += 1; return (200, polls == 1 ? transcribedPending : failure) }
        do { _ = try await api.waitForMultimodalCapture("capture-1", expectedRevision: 3, interval: 0.1, timeout: 2,
                                                       onProgress: { await failedProgress.append($0) }); throw Failure.assertion("analysis failure expected") }
        catch MultimodalClientError.analysisFailed { }
        let retained = await failedProgress.values()
        try check(retained.first?.assets.first?.transcript == "A birthday gift for Dad", "a later product-analysis failure does not erase previously delivered speech")
        let rejectedProgress = ProgressLog()
        StubProtocol.handler = { _ in (200, try data(withTranscript(capture(stage: "analyzing", revision: 4)))) }
        do { _ = try await api.waitForMultimodalCapture("capture-1", expectedRevision: 3,
                                                       onProgress: { await rejectedProgress.append($0) }); throw Failure.assertion("stale transcript accepted") }
        catch MultimodalClientError.staleRevision { }
        let staleValues = await rejectedProgress.values()
        try check(staleValues.isEmpty, "stale revisions cannot emit transcript progress")
        StubProtocol.handler = { _ in Thread.sleep(forTimeInterval: 0.05); return (200, transcribedPending) }
        let cancelledProgress = ProgressLog()
        let cancelled = Task { try await api.waitForMultimodalCapture("capture-1", expectedRevision: 3,
                                                                     onProgress: { await cancelledProgress.append($0) }) }
        try await Task.sleep(nanoseconds: 10_000_000); cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure.assertion("cancelled transcript accepted") }
        catch is CancellationError { }
        catch let error as URLError { try check(error.code == .cancelled, "cancelled polling propagates cancellation") }
        let cancelledValues = await cancelledProgress.values()
        try check(cancelledValues.isEmpty, "cancelling an in-flight response prevents progress delivery")
        try check(MultimodalClientError.analysisFailed(code: "multimodal_invalid_transcript").localizedDescription.contains("Record again or type"), "transcription errors explain recovery without assuming silence")
        print("PASS early speech progress, retention after analysis failure, and stale/cancelled progress rejection")

        StubProtocol.handler = { _ in (200, pending) }
        do { _ = try await api.waitForMultimodalCapture("capture-1", interval: 0.1, timeout: 0.02); throw Failure.assertion("timeout expected") }
        catch MultimodalClientError.pollingTimedOut {}
        let task = Task { try await api.waitForMultimodalCapture("capture-1", interval: 1, timeout: 2) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { _ = try await task.value; throw Failure.assertion("cancellation expected") }
        catch is CancellationError {}
        catch let error as URLError { try check(error.code == .cancelled, "URLSession cancellation propagated") }
        print("PASS bounded polling and task cancellation")
        print("All multimodal Swift SDK checks passed.")
    }
}
