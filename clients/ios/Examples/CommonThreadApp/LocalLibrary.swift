import Foundation
import CommonThreadKit

struct LocalAttachment: Codable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let typeIdentifier: String
    let relativePath: String
    let byteCount: Int
    var isImage: Bool { ["public.jpeg", "public.png", "org.webmproject.webp", "public.heic", "public.image"].contains(typeIdentifier) }
}
struct LocalFindMetadata: Codable, Sendable {
    var isFavorite = false
    var isArchived = false
    var attachments: [LocalAttachment] = []
    var intent: String? = nil
}
struct LocalCaptureAttachment: Sendable {
    let filename: String
    let typeIdentifier: String
    let data: Data
}
private struct LocalLibraryDocument: Codable {
    var version = 2
    var items: [SavedItem]
    var metadata: [String: LocalFindMetadata] = [:]
}

/// Local content never leaves the phone. SDK records stay compatible with the server.
actor LocalLibrary {
    static let shared = LocalLibrary(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MymahFinds", isDirectory: true).appendingPathComponent("local-library.json"))
    private let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }
    private var root: URL { fileURL.deletingLastPathComponent() }

    private func document() throws -> LocalLibraryDocument {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if let document = try? JSONDecoder().decode(LocalLibraryDocument.self, from: data) { return document }
            // Migrate the original array without deleting any existing saves.
            return LocalLibraryDocument(items: try JSONDecoder().decode([SavedItem].self, from: data))
        }
        let document = LocalLibraryDocument(items: try Self.samples())
        try persist(document)
        return document
    }
    func collection() throws -> [SavedItem] { try document().items }
    func metadata() throws -> [String: LocalFindMetadata] { try document().metadata }
    func storageBytes() -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func attachmentURL(_ attachment: LocalAttachment) -> URL { root.appendingPathComponent(attachment.relativePath) }
    func attachmentData(_ attachment: LocalAttachment) throws -> Data { try Data(contentsOf: attachmentURL(attachment)) }

    func capture(_ request: CaptureRequest) throws -> CaptureReceipt {
        var attachments: [LocalCaptureAttachment] = []
        if let value = request.imageDataUrl {
            guard let comma = value.firstIndex(of: ","), value[..<comma].hasSuffix(";base64"),
                  let bytes = Data(base64Encoded: String(value[value.index(after: comma)...])), !bytes.isEmpty else { throw LocalError.invalidMedia }
            let header = String(value[..<comma])
            let type: String
            let ext: String
            if header == "data:image/jpeg;base64", bytes.starts(with: [0xff, 0xd8, 0xff]) { type = "public.jpeg"; ext = "jpg" }
            else if header == "data:image/png;base64", bytes.starts(with: [137,80,78,71,13,10,26,10]) { type = "public.png"; ext = "png" }
            else if header == "data:image/webp;base64", bytes.count > 12, String(data: bytes.prefix(4), encoding: .ascii) == "RIFF", String(data: bytes[8..<12], encoding: .ascii) == "WEBP" { type = "org.webmproject.webp"; ext = "webp" }
            else { throw LocalError.invalidMedia }
            guard bytes.count <= 4 * 1024 * 1024 else { throw LocalError.mediaTooLarge }
            attachments.append(LocalCaptureAttachment(filename: "Photo.\(ext)", typeIdentifier: type, data: bytes))
        }
        return try captureContent(url: request.url, title: request.title, text: request.selectedText, note: request.note,
                                  source: request.source, client: request.client, attachments: attachments)
    }

    func captureContent(url: String? = nil, title: String, text: String = "", note: String = "",
                        source: CaptureSource = .web, client: CaptureClient = .iosApp,
                        attachments: [LocalCaptureAttachment] = [], id: String = UUID().uuidString,
                        deduplicateLink: Bool = true, capturedAt: Date = Date()) throws -> CaptureReceipt {
        let link = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              note.count <= 2000, text.count <= 12000 else { throw LocalError.invalidContent }
        guard (link?.isEmpty == false) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { throw LocalError.invalidLink }
        guard attachments.count <= 10, attachments.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 12 * 1024 * 1024 }),
              attachments.reduce(0, { $0 + $1.data.count }) <= 24 * 1024 * 1024 else { throw LocalError.mediaTooLarge }
        let canonical = try link.flatMap { $0.isEmpty ? nil : try Self.canonicalURL($0) } ?? "local:\(id)"
        var document = try document()
        if document.items.contains(where: { $0.id == id }) { return try Self.receipt(id: id, duplicate: true) }
        if deduplicateLink, attachments.isEmpty, text.isEmpty,
           let existing = document.items.first(where: { $0.canonicalUrl == canonical && $0.client != "sample" }) {
            return try Self.receipt(id: existing.id, duplicate: true)
        }
        let request = CaptureRequest(url: link, title: title, source: source, selectedText: text, note: note, client: client)
        let item = try Self.item(id: id, request: request, canonical: canonical, date: capturedAt, hasImage: attachments.contains { $0.typeIdentifier.contains("image") || ["public.jpeg", "public.png", "org.webmproject.webp"].contains($0.typeIdentifier) })
        var stored: [LocalAttachment] = []
        do {
            for attachment in attachments {
                let attachmentID = UUID()
                let safeExtension = (attachment.filename as NSString).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10)
                let path = "Attachments/\(attachmentID.uuidString)" + (safeExtension.isEmpty ? "" : ".\(safeExtension)")
                let destination = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try attachment.data.write(to: destination, options: .atomic)
                stored.append(LocalAttachment(id: attachmentID, filename: String(attachment.filename.prefix(200)), typeIdentifier: attachment.typeIdentifier, relativePath: path, byteCount: attachment.data.count))
            }
            document.items.insert(item, at: 0)
            document.metadata[id] = LocalFindMetadata(attachments: stored)
            try persist(document)
        } catch {
            for attachment in stored { try? FileManager.default.removeItem(at: attachmentURL(attachment)) }
            throw error
        }
        return try Self.receipt(id: id, duplicate: false)
    }

    func update(_ id: String, title: String, note: String, text: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300, note.count <= 2000, text.count <= 12000 else { throw LocalError.invalidContent }
        var document = try document()
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw LocalError.missingItem }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.items[index])) as! [String: Any]
        value["title"] = title; value["note"] = note; value["selectedText"] = text
        value["revision"] = document.items[index].revision + 1
        document.items[index] = try JSONDecoder().decode(SavedItem.self, from: JSONSerialization.data(withJSONObject: value))
        try persist(document)
    }
    func setIntent(_ id: String, _ text: String?) throws {
        guard (text?.count ?? 0) <= 2000 else { throw LocalError.invalidContent }
        var document = try document(); guard document.items.contains(where: { $0.id == id }) else { throw LocalError.missingItem }
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        document.metadata[id, default: LocalFindMetadata()].intent = value?.isEmpty == false ? value : nil
        try persist(document)
    }
    func setFavorite(_ id: String, _ value: Bool) throws {
        var document = try document(); guard document.items.contains(where: { $0.id == id }) else { throw LocalError.missingItem }
        document.metadata[id, default: LocalFindMetadata()].isFavorite = value; try persist(document)
    }
    func setArchived(_ id: String, _ value: Bool) throws {
        var document = try document(); guard document.items.contains(where: { $0.id == id }) else { throw LocalError.missingItem }
        document.metadata[id, default: LocalFindMetadata()].isArchived = value; try persist(document)
    }
    func delete(_ id: String) throws {
        var document = try document()
        let attachments = document.metadata.removeValue(forKey: id)?.attachments ?? []
        document.items.removeAll { $0.id == id }
        try persist(document)
        for attachment in attachments { try? FileManager.default.removeItem(at: attachmentURL(attachment)) }
    }

    private func persist(_ document: LocalLibraryDocument) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: fileURL, options: .atomic)
    }
    private static func canonicalURL(_ value: String) throws -> String {
        guard value.count <= 2048, var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
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
    private static func item(id: String, request: CaptureRequest, canonical: String, sample: Bool = false, date: Date = Date(), hasImage: Bool = false) throws -> SavedItem {
        let object: [String: Any] = [
            "id": id, "originalUrl": request.url ?? "", "canonicalUrl": canonical,
            "title": request.title, "source": request.source.rawValue, "client": sample ? "sample" : request.client.rawValue,
            "selectedText": request.selectedText, "note": request.note, "capturedAt": date.timeIntervalSince1970,
            "status": "saved", "features": [String: String](), "revision": 1,
            "suggestions": [String](), "responses": [String](), "hasImage": hasImage, "analysisStatus": "unavailable"
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
            let sourceURL = "https://example.com/inspiration/\(entry.0)"
            let request = CaptureRequest(url: sourceURL, title: entry.1, note: entry.2)
            return try item(id: "sample-\(entry.0)", request: request, canonical: sourceURL, sample: true,
                            date: Date().addingTimeInterval(-Double(offset + 1) * 3600))
        }
    }
    enum LocalError: LocalizedError {
        case invalidLink, invalidContent, invalidMedia, mediaTooLarge, missingItem
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Add a valid public link, a photo, a file, or some text. Links must use http or https without a username or password."
            case .invalidContent: return "Use a title up to 300 characters, a note up to 2,000, and text up to 12,000."
            case .invalidMedia: return "This image could not be read. Choose a JPEG, PNG, or WebP image."
            case .mediaTooLarge: return "Choose up to 10 attachments, under 12 MB each and 24 MB in total."
            case .missingItem: return "This find is no longer in your library."
            }
        }
    }
}
