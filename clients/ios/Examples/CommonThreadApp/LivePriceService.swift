import Foundation
import Combine

@MainActor enum LivePriceService {
    enum Failure: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "The price check couldn’t be verified. Please try again." }
    }
    private static var ownerID: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "finds.priceTrackerOwner"), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: "finds.priceTrackerOwner")
        return value
    }
    private static var decoder: JSONDecoder {
        let value = JSONDecoder(); value.keyDecodingStrategy = .convertFromSnakeCase; return value
    }
    static func check(_ url: URL) async throws -> LivePriceSnapshot {
        let body = try JSONSerialization.data(withJSONObject: ["product_url": url.absoluteString])
        let data = try await CaptureIntelligence.post(path: "v1/price-check", body: body)
        try Task.checkCancellation()
        let result = try decoder.decode(LivePriceSnapshot.self, from: data)
        guard ["available", "unavailable"].contains(result.status), result.checkedAt.isFinite,
              let actual = result.productUrl, PriceMoney.sameListing(actual, url.absoluteString),
              result.status != "available" || result.isAvailable else { throw Failure.invalidResponse }
        return result
    }
    static func watches(action: String = "list", watch: TrackedPrice? = nil, url: URL? = nil,
                        title: String? = nil, target: Int? = nil, currency: String? = nil) async throws -> [TrackedPrice] {
        var payload: [String: Any] = ["action": action, "owner_id": ownerID]
        if let watch { payload["watch_id"] = watch.id }
        if let url { payload["product_url"] = url.absoluteString }
        if let title { payload["title"] = String(title.prefix(300)) }
        if let target { payload["target_minor"] = target }
        if let currency { payload["currency"] = currency }
        let data = try await CaptureIntelligence.post(path: "v1/price-watch", body: JSONSerialization.data(withJSONObject: payload))
        try Task.checkCancellation()
        struct Envelope: Decodable { let watches: [TrackedPrice] }
        let result = try decoder.decode(Envelope.self, from: data).watches
        guard result.count <= 50, Set(result.map(\.id)).count == result.count else { throw Failure.invalidResponse }
        return result
    }
}

@MainActor final class PriceTrackingController: ObservableObject {
    static let shared = PriceTrackingController()
    @Published private(set) var watches: [TrackedPrice] = []
    @Published private(set) var updating = false
    @Published var errorMessage: String?
    func watch(for url: URL) -> TrackedPrice? { watches.first { PriceMoney.sameListing($0.productUrl, url.absoluteString) } }
    func refresh() async {
        guard !updating, CaptureIntelligence.isConfigured else { return }
        _ = await perform { try await LivePriceService.watches() }
    }
    func save(url: URL, title: String, target: Int?, currency: String?) async -> Bool {
        await perform { try await LivePriceService.watches(action: "save", watch: self.watch(for: url), url: url, title: title, target: target, currency: currency) }
    }
    func check(_ watch: TrackedPrice) async { _ = await perform { try await LivePriceService.watches(action: "check", watch: watch) } }
    func remove(_ watch: TrackedPrice) async { _ = await perform { try await LivePriceService.watches(action: "delete", watch: watch) } }
    private func perform(_ action: () async throws -> [TrackedPrice]) async -> Bool {
        guard !updating else { return false }
        updating = true; errorMessage = nil
        defer { updating = false }
        do { watches = try await action(); return true }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }
}
