import Foundation
import CryptoKit

/// Exact-context cache. Edits, deletion, search, selected details, and connection
/// changes create a different key. A canceled view cancels its network request.
@MainActor enum RecommendationCache {
    private struct Entry { let data: Data; let savedAt: Date }
    private static var entries: [String: Entry] = [:]
    private static func key(_ body: Data) throws -> String {
        guard let configuration = try CaptureIntelligence.configuration() else { throw CaptureIntelligence.Failure.configuration }
        let namespace = Data((configuration.baseURL.absoluteString + "|" + configuration.accessToken).utf8)
        return SHA256.hash(data: namespace + body).map { String(format: "%02x", $0) }.joined()
    }
    static func cached(_ body: Data) throws -> Data? {
        let value = try key(body)
        guard let entry = entries[value], Date().timeIntervalSince(entry.savedAt) < 60 else { return nil }
        return entry.data
    }
    static func fetch(_ body: Data, force: Bool = false) async throws -> Data {
        let value = try key(body)
        if !force, let data = try cached(body) { return data }
        // Await directly so SwiftUI task cancellation stops obsolete searches.
        // The server coalesces identical SQL requests within its bounded cache.
        let data = try await CaptureIntelligence.post(path: "v1/recommendations", body: body)
        try Task.checkCancellation()
        // Do not freeze a temporary unavailable/unanalyzed state in the cache.
        if let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String,
           ["ready", "no_matches"].contains(status) {
            entries[value] = Entry(data: data, savedAt: Date())
            if entries.count > 24, let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key { entries[oldest] = nil }
        }
        return data
    }
}
