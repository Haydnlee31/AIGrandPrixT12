import Foundation
import CryptoKit
import CommonThreadKit

/// A current need can stand alone. Only intentionally selected saves are sent.
@MainActor enum RadarMatchingService {
    private struct Entry { let page: LocalRecommendationPage; let createdAt: Date }
    private static var cache: [String: Entry] = [:]
    enum Failure: LocalizedError {
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Matches could not be loaded. Please try again."
            }
        }
    }

    static func fetch(brief: RadarBrief, watch: RadarWatch?, finds: [SavedItem],
                      metadata: [String: LocalFindMetadata], force: Bool = false) async throws -> LocalRecommendationPage {
        try Task.checkCancellation()
        let reviewed = try brief.validated()
        let requestedIDs = Set(reviewed.sourceIDs)
        func sourceIDs(for find: SavedItem) -> Set<String> {
            Set([find.id] + (metadata[find.id]?.sourceItems ?? []).map(\.id))
        }
        var seenGroups = Set<String>()
        let selected = finds.filter { find in
            !requestedIDs.isDisjoint(with: sourceIDs(for: find)) && seenGroups.insert(find.id).inserted
        }
        // A tracked need survives deleting its original example. Send only
        // surviving, explicitly selected groups; no replacement from Library.
        // An empty selection is an ordinary intent-only Radar request.
        let sources: [[String: Any]] = try selected.map { find in
            let context = metadata[find.id] ?? LocalFindMetadata()
            var value: [String: Any] = ["id": find.id, "title": find.title, "text": String(find.selectedText.prefix(12000)),
                "note": String(find.note.prefix(2000)), "intents": Array(context.selectedIntents.prefix(8))]
            if !find.originalUrl.isEmpty { value["original_url"] = String(find.originalUrl.prefix(4000)) }
            if let analysis = context.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
            return value
        }
        let intention = watch?.scope == .need ? watch!.target : reviewed.intention
        let preferences = [watch?.conditions ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var payload: [String: Any] = ["intention": String(intention.prefix(300)), "finds": sources,
            "preferences": preferences.map { String($0.prefix(500)) }, "query": "",
            "scope": watch?.scope.rawValue ?? "need", "target": watch?.target ?? "", "limit": 12,
            "currency": reviewed.currency]
        if !reviewed.budget.isEmpty, let amount = Decimal(string: reviewed.budget, locale: Locale(identifier: "en_US_POSIX")) {
            payload["budget"] = NSDecimalNumber(decimal: amount).doubleValue
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let configuration = try CaptureIntelligence.configuration() else { throw CaptureIntelligence.Failure.configuration }
        let namespace = Data((configuration.baseURL.absoluteString + "|" + configuration.accessToken + "|radar-amazon-v2").utf8)
        let key = SHA256.hash(data: namespace + body).map { String(format: "%02x", $0) }.joined()
        if !force, let entry = cache[key], Date().timeIntervalSince(entry.createdAt) < 60 { return entry.page }
        let data = try await CaptureIntelligence.post(path: "v1/radar", body: body)
        try Task.checkCancellation()
        let page: LocalRecommendationPage
        do { page = try JSONDecoder().decode(LocalRecommendationPage.self, from: data) }
        catch { throw Failure.invalidResponse }
        guard ["ready", "no_matches", "needs_clarification", "needs_analysis", "catalog_unavailable"].contains(page.status),
              page.items.count <= 12, Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ !$0.title.isEmpty && !$0.sourceRecordID.isEmpty }),
              page.status != "ready" || !page.items.isEmpty else { throw Failure.invalidResponse }
        // Cache only fully decoded, usable responses. Manual Retry can bypass
        // a previous empty result; errors and unclear requests never stick.
        if ["ready", "no_matches"].contains(page.status) {
            cache[key] = Entry(page: page, createdAt: Date())
            if cache.count > 24, let oldest = cache.min(by: { $0.value.createdAt < $1.value.createdAt })?.key { cache[oldest] = nil }
        }
        return page
    }
}
