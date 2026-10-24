import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "RadarMatchingSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
struct TestAnalysis: Encodable { var product_name = "Watch" }
struct LocalFindMetadata {
    var sourceItems: [SavedItem]? = nil
    var selectedIntents: [String] = []
    var analysis: TestAnalysis? = nil
}
struct LocalRecommendationPage: Decodable {
    let status: String
    let items: [LocalRecommendation]
}
struct LocalRecommendation: Decodable {
    let id: String
    let title: String
    let sourceRecordID: String
}
@MainActor enum CaptureIntelligence {
    struct Configuration { let baseURL: URL; let accessToken: String }
    enum Failure: Error { case configuration }
    static var requests: [[String: Any]] = []
    static var reply = Data(#"{"status":"no_matches","items":[]}"#.utf8)
    static func configuration() throws -> Configuration? {
        Configuration(baseURL: URL(string: "https://example.invalid")!, accessToken: "isolated-fixture")
    }
    static func post(path: String, body: Data) async throws -> Data {
        try check(path == "v1/radar", "Radar must use its intent-aware endpoint")
        requests.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        return reply
    }
}

@main struct RadarMatchingSmoke {
    @MainActor static func main() async throws {
        func saved(_ id: String) throws -> SavedItem {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "originalUrl": "https://example.invalid/" + id,
                "canonicalUrl": "https://example.invalid/" + id, "title": id, "source": "product", "selectedText": "",
                "note": "", "capturedAt": 1, "status": "ready", "features": [:], "revision": 1, "suggestions": [], "responses": []])
            return try JSONDecoder().decode(SavedItem.self, from: data)
        }
        let group = try saved("current-group"), alias = try saved("older-alias"), unrelated = try saved("unrelated-save")
        var brief = RadarBrief(); brief.intention = "I want a retro watch"; brief.sourceIDs = ["deleted"]
        _ = try await RadarMatchingService.fetch(brief: brief, watch: nil, finds: [unrelated], metadata: [:], force: true)
        try check((CaptureIntelligence.requests.last?["finds"] as? [[String: Any]])?.isEmpty == true,
                  "Deleting every old source must fall back to intent-only, never use an unrelated save")
        brief.sourceIDs = ["deleted", "older-alias", "current-group"]
        brief.searchTerms = "retired filter"; brief.mustHaves = "retired constraint"; brief.fitNotes = "retired fit"; brief.smallSpace = true
        let context = [group.id: LocalFindMetadata(sourceItems: [group, alias], analysis: TestAnalysis())]
        let watch = RadarWatch(brief: brief, scope: .category, target: "Desk lamps", conditions: "Warm light")
        _ = try await RadarMatchingService.fetch(brief: brief, watch: watch, finds: [group, unrelated], metadata: context, force: true)
        let payload = CaptureIntelligence.requests.last!
        let sources = payload["finds"] as! [[String: Any]]
        try check(sources.count == 1 && sources[0]["id"] as? String == group.id,
                  "Surviving selected aliases must resolve once; deleted and unrelated sources stay excluded")
        try check(sources[0]["original_url"] as? String == group.originalUrl,
                  "Original product identity must reach matching without guessing a different listing")
        try check(payload["target"] as? String == "Desk lamps" && payload["scope"] as? String == "category",
                  "The explicitly edited tracking target must reach the backend")
        try check(payload["query"] as? String == "" && payload["preferences"] as? [String] == ["Warm light"],
                  "Removed controls must not become hidden retrieval constraints")
        let calls = CaptureIntelligence.requests.count
        _ = try await RadarMatchingService.fetch(brief: brief, watch: watch, finds: [group, unrelated], metadata: context)
        try check(CaptureIntelligence.requests.count == calls, "Valid results may be cached briefly")
        _ = try await RadarMatchingService.fetch(brief: brief, watch: watch, finds: [group, unrelated], metadata: context, force: true)
        try check(CaptureIntelligence.requests.count == calls + 1, "An explicit check must bypass an empty-result cache")
        print("Radar matching smoke passed: deleted-source fallback, selected-alias grouping, no unrelated context, target propagation, retired controls, cache and retry")
    }
}
