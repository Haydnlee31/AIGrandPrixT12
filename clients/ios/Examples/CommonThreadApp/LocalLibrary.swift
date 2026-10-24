import Foundation
import CommonThreadKit

/// Frontend-only storage. It uses SDK models but makes no network requests.
/// Connecting an account later leaves these on-device finds separate from the server library.
actor LocalLibrary {
    static let shared = LocalLibrary(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MymahFinds", isDirectory: true).appendingPathComponent("local-library.json"))
    private let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func collection() throws -> [SavedItem] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try JSONDecoder().decode([SavedItem].self, from: Data(contentsOf: fileURL))
        }
        let samples = try Self.samples()
        try persist(samples)
        return samples
    }

    func capture(_ request: CaptureRequest) throws -> CaptureReceipt {
        guard request.url.count <= 2048, !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.title.count <= 300, request.note.count <= 2000, request.selectedText.count <= 12000 else {
            throw LocalError.invalidContent
        }
        let canonical = try Self.canonicalURL(request.url)
        var items = try collection()
        if let existing = items.first(where: { $0.canonicalUrl == canonical && $0.client != "sample" }) {
            return try Self.receipt(id: existing.id, duplicate: true)
        }
        let item = try Self.item(id: UUID().uuidString, request: request, canonical: canonical)
        items.insert(item, at: 0)
        try persist(items)
        return try Self.receipt(id: item.id, duplicate: false)
    }

    func delete(_ id: String) throws {
        var items = try collection()
        items.removeAll { $0.id == id }
        try persist(items)
    }

    private func persist(_ items: [SavedItem]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
    }

    private static func canonicalURL(_ value: String) throws -> String {
        guard var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), host.contains("."),
              parts.user == nil, parts.password == nil else { throw LocalError.invalidLink }
        parts.scheme = scheme; parts.host = host; parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/" }
        let filtered = (parts.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        parts.queryItems = filtered.isEmpty ? nil : filtered
        guard let url = parts.url else { throw LocalError.invalidLink }
        return url.absoluteString
    }

    private static func receipt(id: String, duplicate: Bool) throws -> CaptureReceipt {
        try JSONDecoder().decode(CaptureReceipt.self, from: JSONSerialization.data(withJSONObject: ["id": id, "status": "saved", "duplicate": duplicate]))
    }
    private static func item(id: String, request: CaptureRequest, canonical: String, sample: Bool = false, date: Date = Date()) throws -> SavedItem {
        let object: [String: Any] = [
            "id": id, "originalUrl": request.url, "canonicalUrl": canonical,
            "title": request.title, "source": request.source.rawValue, "client": sample ? "sample" : request.client.rawValue,
            "selectedText": request.selectedText, "note": request.note, "capturedAt": date.timeIntervalSince1970,
            "status": "saved", "features": [String: String](), "revision": 1,
            "suggestions": [String](), "responses": [String]()
        ]
        return try JSONDecoder().decode(SavedItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func samples() throws -> [SavedItem] {
        let content = [
            ("reading", "A softer kind of corner", "The warm wood, the soft light. This is how I want my reading corner to feel."),
            ("lamp", "A little evening glow", "Love the sculptural shape. Something small for the bedside table."),
            ("balcony", "Make room for slow mornings", "A tiny balcony can still feel like an escape. Keep it rental friendly."),
            ("ceramics", "Everyday, but a little special", "Those earthy colours. A few lovely pieces, not more clutter.")
        ]
        return try content.enumerated().map { offset, entry in
            let request = CaptureRequest(url: "https://example.com/inspiration/\(entry.0)", title: entry.1, note: entry.2)
            return try item(id: "sample-\(entry.0)", request: request, canonical: request.url, sample: true,
                            date: Date().addingTimeInterval(-Double(offset + 1) * 3600))
        }
    }
    enum LocalError: LocalizedError {
        case invalidLink, invalidContent
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Add a valid public http or https link without a username or password."
            case .invalidContent: return "Check the title and note length, then try saving again."
            }
        }
    }
}
