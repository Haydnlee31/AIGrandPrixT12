import Foundation
import CommonThreadKit
import UniformTypeIdentifiers
import CryptoKit

struct LocalAttachment: Codable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let typeIdentifier: String
    let relativePath: String
    let byteCount: Int
    var isImage: Bool { ["public.jpeg", "public.png", "org.webmproject.webp", "public.heic", "public.image"].contains(typeIdentifier) }
    var isAudio: Bool {
        if let type = UTType(typeIdentifier) ?? UTType(mimeType: typeIdentifier), type.conforms(to: .audio) { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) { return true }
        return ["m4a", "aac", "mp3", "wav", "aif", "aiff", "caf", "flac", "ogg", "oga", "opus", "amr"].contains(ext)
    }
}
struct LocalFindMetadata: Codable, Sendable {
    var isFavorite = false
    var isArchived = false
    var isPinned: Bool? = nil
    var pinned: Bool { isPinned ?? false }
    var attachments: [LocalAttachment] = []
    var intent: String? = nil
    var intents: [String]? = nil
    var analysis: CaptureIntelligenceResult? = nil
    var userEditedTitle: Bool? = nil
    var hasVoiceNote: Bool? = nil
    // Read-only provenance for an exact-duplicate group. Original rows stay on disk.
    var sourceItems: [SavedItem]? = nil
    var sourceAnalyses: [CaptureIntelligenceResult]? = nil
    var selectedIntents: [String] {
        if let intents { return intents }
        let legacy = intent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacy.isEmpty ? [] : [legacy]
    }
}
struct LocalCaptureAttachment: Sendable {
    let filename: String
    let typeIdentifier: String
    let data: Data
}
private struct LocalFindGroupEdits: Codable {
    var title: String? = nil
    var note: String? = nil
    var text: String? = nil
    var intents: [String]? = nil
    var analysis: CaptureIntelligenceResult? = nil
    var analysisInvalidated = false
    var isFavorite: Bool? = nil
    var isPinned: Bool? = nil
    var isArchived: Bool? = nil
    var hasVoiceNote: Bool? = nil
    var revision = 0
}
private struct LocalLibraryDocument: Codable {
    var version = 3
    var items: [SavedItem]
    var metadata: [String: LocalFindMetadata] = [:]
    var groupEdits: [String: LocalFindGroupEdits]? = nil
}

/// Durable on-device storage. Optional intelligence is separate from this store.
actor LocalLibrary {
    static let shared = LocalLibrary(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MymahFinds", isDirectory: true).appendingPathComponent("local-library.json"))
    private let fileURL: URL
    private var attachmentDigests: [String: String] = [:]
    init(fileURL: URL) { self.fileURL = fileURL }
    private var root: URL { fileURL.deletingLastPathComponent() }

    private func document() throws -> LocalLibraryDocument {
        var document: LocalLibraryDocument
        var needsMigration = false
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if let stored = try? JSONDecoder().decode(LocalLibraryDocument.self, from: data) {
                document = stored; needsMigration = stored.version < 3
            } else {
                // Migrate the original array without deleting any user-created save.
                document = LocalLibraryDocument(items: try JSONDecoder().decode([SavedItem].self, from: data))
                needsMigration = true
            }
        } else {
            document = LocalLibraryDocument(items: []); needsMigration = true
        }
        let starterIDs: Set<String> = ["sample-reading", "sample-lamp", "sample-balcony", "sample-ceramics"]
        let removed = document.items.filter { $0.client == "sample" && starterIDs.contains($0.id) }.map(\.id)
        if !removed.isEmpty {
            document.items.removeAll { $0.client == "sample" && starterIDs.contains($0.id) }
            for id in removed { document.metadata.removeValue(forKey: id) }
            needsMigration = true
        }
        // Earlier versions saved hostname/photo-filename titles even after analysis.
        // Upgrade those once; a resolved or explicitly edited title never changes here.
        for index in document.items.indices {
            let item = document.items[index]
            guard let metadata = document.metadata[item.id], metadata.userEditedTitle != true, let analysis = metadata.analysis else { continue }
            let title = Self.analysisTitle(analysis, replacing: item.title, originalURL: item.originalUrl,
                imageFilenames: metadata.attachments.filter(\.isImage).map(\.filename))
            if title != item.title {
                document.items[index] = try Self.revised(item, title: title)
                needsMigration = true
            }
        }
        if needsMigration { document.version = 3; try persist(document) }
        return document
    }
    func collection() throws -> [SavedItem] { try grouped(document()).items }
    func metadata() throws -> [String: LocalFindMetadata] { try grouped(document()).metadata }
    /// Old share IDs and saved Radar sources continue to resolve after grouping.
    func item(_ id: String) throws -> SavedItem? {
        let view = try grouped(document())
        return view.items.first { $0.id == (view.aliases[id] ?? id) }
    }

    private struct GroupedLibrary {
        var items: [SavedItem] = []
        var metadata: [String: LocalFindMetadata] = [:]
        var aliases: [String: String] = [:]
        var members: [String: [String]] = [:]
    }

    private func grouped(_ document: LocalLibraryDocument) throws -> GroupedLibrary {
        var groups: [String: [SavedItem]] = [:]
        for item in document.items {
            let details = document.metadata[item.id] ?? LocalFindMetadata()
            let key: String
            if item.client == "sample" { key = "id:\(item.id)" }
            else if !item.originalUrl.isEmpty, let canonical = try? Self.canonicalURL(item.originalUrl) {
                key = "url:\(canonical)"
            } else if item.originalUrl.isEmpty, !details.attachments.isEmpty, details.attachments.allSatisfy(\.isImage),
                      let fingerprints = photoFingerprints(details.attachments) {
                // Match the complete photo set, byte-for-byte. No name or visual similarity.
                key = "photos:" + fingerprints.sorted().joined(separator: ":")
            } else { key = "id:\(item.id)" }
            groups[key, default: []].append(item)
        }
        var result = GroupedLibrary()
        for sources in groups.values {
            let sources = sources.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
            guard let first = sources.first else { continue }
            let ids = sources.map(\.id)
            let edits = document.groupEdits?[first.id]
            var metadata = document.metadata[first.id] ?? LocalFindMetadata()
            var displayed = first
            if sources.count > 1 || edits != nil {
                let sourceMetadata = sources.map { document.metadata[$0.id] ?? LocalFindMetadata() }
                let customSource = sources.last { document.metadata[$0.id]?.userEditedTitle == true }
                let analyzedSource = sources.filter { document.metadata[$0.id]?.analysis != nil }.max { (document.metadata[$0.id]?.analysis?.analyzedAt ?? 0) < (document.metadata[$1.id]?.analysis?.analyzedAt ?? 0) }
                var analyses = sourceMetadata.compactMap(\.analysis)
                if let analysis = edits?.analysis { analyses.append(analysis) }
                analyses.sort { $0.analyzedAt > $1.analyzedAt }
                var seenAnalyses = Set<Data>()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                analyses = analyses.filter { analysis in
                    guard let bytes = try? encoder.encode(analysis) else { return false }
                    return seenAnalyses.insert(bytes).inserted
                }
                metadata.sourceItems = sources
                metadata.sourceAnalyses = analyses
                metadata.attachments = sourceMetadata.flatMap(\.attachments)
                metadata.intents = edits?.intents ?? Self.unique(sourceMetadata.flatMap(\.selectedIntents))
                metadata.intent = metadata.intents?.first
                metadata.isFavorite = edits?.isFavorite ?? sourceMetadata.contains(where: \.isFavorite)
                metadata.isPinned = edits?.isPinned ?? sourceMetadata.contains(where: \.pinned)
                metadata.isArchived = edits?.isArchived ?? sourceMetadata.allSatisfy(\.isArchived)
                metadata.hasVoiceNote = edits?.hasVoiceNote == true || sourceMetadata.contains(where: { $0.hasVoiceNote == true }) ? true : nil
                metadata.userEditedTitle = edits?.title != nil || customSource != nil
                metadata.analysis = edits?.analysisInvalidated == true ? nil : analyses.first
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
                var title = edits?.title ?? customSource?.title ?? analyzedSource?.title ?? first.title
                if metadata.userEditedTitle != true {
                    if let source = analyzedSource, title == document.metadata[source.id]?.analysis?.productName,
                       let name = metadata.analysis?.productName, !name.isEmpty, name.count <= 300 { title = name }
                    else { title = Self.analysisTitle(metadata.analysis, replacing: title, originalURL: first.originalUrl,
                                                     imageFilenames: metadata.attachments.filter(\.isImage).map(\.filename)) }
                }
                object["title"] = title
                object["note"] = edits?.note ?? Self.unique(sources.map(\.note)).joined(separator: "\n\n")
                object["selectedText"] = edits?.text ?? Self.unique(sources.map(\.selectedText)).joined(separator: "\n\n")
                object["capturedAt"] = sources.last!.capturedAt
                object["revision"] = sources.reduce(0) { $0 + $1.revision } + (edits?.revision ?? 0)
                object["hasImage"] = sourceMetadata.flatMap(\.attachments).contains(where: \.isImage) || sources.contains(where: \.hasImage)
                displayed = try JSONDecoder().decode(SavedItem.self, from: JSONSerialization.data(withJSONObject: object))
            }
            result.items.append(displayed)
            result.members[first.id] = ids
            for id in ids { result.aliases[id] = first.id; result.metadata[id] = metadata }
        }
        result.items.sort { ($0.capturedAt, $0.id) > ($1.capturedAt, $1.id) }
        return result
    }

    private func photoFingerprints(_ attachments: [LocalAttachment]) -> [String]? {
        var values: [String] = []
        for attachment in attachments {
            if let digest = attachmentDigests[attachment.relativePath] { values.append(digest); continue }
            guard let bytes = try? attachmentData(attachment) else { return nil }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            attachmentDigests[attachment.relativePath] = digest; values.append(digest)
        }
        return values
    }

    private static func unique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !result.contains(value) { result.append(value) }
        return result
    }

    private func group(_ id: String, in document: LocalLibraryDocument) throws -> (id: String, item: SavedItem, metadata: LocalFindMetadata, members: [String]) {
        let view = try grouped(document)
        let primary = view.aliases[id] ?? id
        guard let item = view.items.first(where: { $0.id == primary }), let metadata = view.metadata[primary], let members = view.members[primary] else { throw LocalError.missingItem }
        return (primary, item, metadata, members)
    }

    private func saveGroupEdit(_ id: String, in document: inout LocalLibraryDocument, change: (inout LocalFindGroupEdits) -> Void) {
        var edit = document.groupEdits?[id] ?? LocalFindGroupEdits()
        change(&edit); edit.revision += 1
        if document.groupEdits == nil { document.groupEdits = [:] }
        document.groupEdits?[id] = edit
    }
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
                        deduplicateLink: Bool = true, capturedAt: Date = Date(),
                        intents: [String]? = nil, analysis: CaptureIntelligenceResult? = nil,
                        userEditedTitle: Bool? = nil, hasVoiceNote: Bool = false) throws -> CaptureReceipt {
        let link = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              note.count <= 2000, text.count <= 12000 else { throw LocalError.invalidContent }
        guard (link?.isEmpty == false) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { throw LocalError.invalidLink }
        guard attachments.count <= 10, attachments.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 12 * 1024 * 1024 }),
              attachments.reduce(0, { $0 + $1.data.count }) <= 24 * 1024 * 1024 else { throw LocalError.mediaTooLarge }
        let cleanedIntents = try intents.map { try Self.validatedIntents($0) }
        let canonical = try link.flatMap { $0.isEmpty ? nil : try Self.canonicalURL($0) } ?? "local:\(id)"
        var document = try document()
        if document.items.contains(where: { $0.id == id }) {
            return try Self.receipt(id: group(id, in: document).id, duplicate: true)
        }
        // Every distinct save is durable, even when its URL already exists. Grouping
        // combines the read view instead of throwing away the new note or attachments.
        let resolvedTitle = userEditedTitle == true ? title : Self.analysisTitle(analysis, replacing: title, originalURL: link ?? "", imageFilenames: attachments.filter { $0.typeIdentifier.contains("image") || ["public.jpeg", "public.png", "org.webmproject.webp", "public.heic"].contains($0.typeIdentifier) }.map(\.filename))
        let request = CaptureRequest(url: link, title: resolvedTitle, source: source, selectedText: text, note: note, client: client)
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
            document.metadata[id] = LocalFindMetadata(attachments: stored, intent: cleanedIntents?.first,
                intents: cleanedIntents, analysis: analysis, userEditedTitle: userEditedTitle,
                hasVoiceNote: hasVoiceNote ? true : nil)
            let joined = try group(id, in: document)
            if let priorID = joined.members.first(where: { document.groupEdits?[$0] != nil }),
               var edit = document.groupEdits?[priorID] {
                // Explicit edits stay authoritative, while a later save still contributes
                // its new context. Replaying the same source ID returns before this point.
                if let previous = edit.note { edit.note = Self.unique([previous, note]).joined(separator: "\n\n") }
                if let previous = edit.text { edit.text = Self.unique([previous, text]).joined(separator: "\n\n") }
                if let previous = edit.intents { edit.intents = Self.unique(previous + (cleanedIntents ?? [])) }
                if userEditedTitle == true { edit.title = resolvedTitle }
                if analysis != nil { edit.analysisInvalidated = false }
                edit.revision += 1
                document.groupEdits?.removeValue(forKey: priorID)
                document.groupEdits?[joined.id] = edit
            }
            try persist(document)
        } catch {
            for attachment in stored { try? FileManager.default.removeItem(at: attachmentURL(attachment)) }
            throw error
        }
        let savedGroup = try group(id, in: document)
        return try Self.receipt(id: savedGroup.id, duplicate: savedGroup.members.count > 1)
    }

    func update(_ id: String, title: String, note: String, text: String, hasVoiceNote: Bool = false) throws {
        var document = try document()
        let group = try group(id, in: document)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              note.count <= max(2000, group.item.note.count), text.count <= max(12000, group.item.selectedText.count) else { throw LocalError.invalidContent }
        if group.members.count > 1 || document.groupEdits?[group.id] != nil {
            saveGroupEdit(group.id, in: &document) { edit in
                if title != group.item.title || edit.title != nil { edit.title = title }
                edit.note = note; edit.text = text; edit.analysis = nil; edit.analysisInvalidated = true
                if hasVoiceNote { edit.hasVoiceNote = true }
            }
            try persist(document); return
        }
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw LocalError.missingItem }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.items[index])) as! [String: Any]
        if title != document.items[index].title { document.metadata[id, default: LocalFindMetadata()].userEditedTitle = true }
        value["title"] = title; value["note"] = note; value["selectedText"] = text
        value["revision"] = document.items[index].revision + 1
        document.items[index] = try JSONDecoder().decode(SavedItem.self, from: JSONSerialization.data(withJSONObject: value))
        document.metadata[id, default: LocalFindMetadata()].analysis = nil
        if hasVoiceNote { document.metadata[id, default: LocalFindMetadata()].hasVoiceNote = true }
        try persist(document)
    }
    func setAnalysis(_ id: String, _ analysis: CaptureIntelligenceResult) throws {
        var document = try document()
        let group = try group(id, in: document)
        if group.members.count > 1 || document.groupEdits?[group.id] != nil {
            saveGroupEdit(group.id, in: &document) { edit in
                edit.analysis = analysis; edit.analysisInvalidated = false
            }
            try persist(document); return
        }
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw LocalError.missingItem }
        let metadata = document.metadata[id] ?? LocalFindMetadata()
        let current = document.items[index]
        var title = current.title
        if metadata.userEditedTitle != true {
            let generatedName = analysis.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if metadata.userEditedTitle == false, current.title == metadata.analysis?.productName,
               !generatedName.isEmpty, generatedName.count <= 300 {
                title = generatedName
            } else {
                title = Self.analysisTitle(analysis, replacing: current.title, originalURL: current.originalUrl,
                    imageFilenames: metadata.attachments.filter(\.isImage).map(\.filename))
            }
        }
        document.items[index] = try Self.revised(current, title: title)
        document.metadata[id, default: LocalFindMetadata()].analysis = analysis
        try persist(document)
    }
    func setIntent(_ id: String, _ text: String?) throws {
        try setIntents(id, text.map { [$0] } ?? [])
    }
    func setIntents(_ id: String, _ values: [String], hasVoiceNote: Bool = false) throws {
        var document = try document()
        let group = try group(id, in: document)
        let values = try Self.validatedIntents(values, maximumCount: max(8, group.metadata.selectedIntents.count),
                                              maximumLength: max(4000, group.metadata.selectedIntents.reduce(0) { $0 + $1.count }))
        if group.members.count > 1 || document.groupEdits?[group.id] != nil {
            saveGroupEdit(group.id, in: &document) { edit in
                edit.intents = values
                if hasVoiceNote { edit.hasVoiceNote = true }
            }
            try persist(document); return
        }
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw LocalError.missingItem }
        document.metadata[id, default: LocalFindMetadata()].intents = values
        document.metadata[id, default: LocalFindMetadata()].intent = values.first
        if hasVoiceNote { document.metadata[id, default: LocalFindMetadata()].hasVoiceNote = true }
        document.items[index] = try Self.revised(document.items[index])
        try persist(document)
    }
    private static func validatedIntents(_ input: [String], maximumCount: Int = 8, maximumLength: Int = 4000) throws -> [String] {
        var values: [String] = []
        for value in input.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty && !values.contains(value) {
            values.append(value)
        }
        guard values.count <= maximumCount, values.allSatisfy({ $0.count <= 500 }), values.reduce(0, { $0 + $1.count }) <= maximumLength else { throw LocalError.invalidIntents }
        return values
    }
    private static func revised(_ item: SavedItem, title: String? = nil) throws -> SavedItem {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        if let title { value["title"] = title }
        value["revision"] = item.revision + 1
        return try JSONDecoder().decode(SavedItem.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private static func analysisTitle(_ analysis: CaptureIntelligenceResult?, replacing title: String,
                                      originalURL: String, imageFilenames: [String]) -> String {
        guard let name = analysis?.productName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 300 else { return title }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let host = URL(string: originalURL)?.host?.lowercased()
        let hostWithoutWWW = host?.hasPrefix("www.") == true ? String(host!.dropFirst(4)) : host
        let urlTitle = URLComponents(string: cleaned).map { ["http", "https"].contains($0.scheme ?? "") && $0.host != nil } ?? false
        let filename = (cleaned as NSString).lastPathComponent
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "tiff", "tif"]
        let imageFilename = imageFilenames.contains { $0.lowercased() == cleaned } || imageExtensions.contains((filename as NSString).pathExtension)
        let placeholder = ["a new find", "a photo worth saving", "untitled find"].contains(cleaned)
        if placeholder || urlTitle || cleaned == originalURL.lowercased() || normalized == host || normalized == hostWithoutWWW || imageFilename { return name }
        return title
    }
    func setFavorite(_ id: String, _ value: Bool) throws {
        var document = try document()
        let group = try group(id, in: document)
        if group.members.count > 1 || document.groupEdits?[group.id] != nil {
            saveGroupEdit(group.id, in: &document) { $0.isFavorite = value }; try persist(document); return
        }
        document.metadata[id, default: LocalFindMetadata()].isFavorite = value; try persist(document)
    }
    func setPinned(_ id: String, _ value: Bool) throws {
        var document = try document()
        let group = try group(id, in: document)
        if group.members.count > 1 || document.groupEdits?[group.id] != nil {
            saveGroupEdit(group.id, in: &document) { $0.isPinned = value }; try persist(document); return
        }
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw LocalError.missingItem }
        guard document.metadata[id, default: LocalFindMetadata()].pinned != value else { return }
        document.metadata[id, default: LocalFindMetadata()].isPinned = value
        document.items[index] = try Self.revised(document.items[index])
        try persist(document)
    }
    func setArchived(_ id: String, _ value: Bool) throws {
        var document = try document()
        let group = try group(id, in: document)
        if group.members.count > 1 || document.groupEdits?[group.id] != nil {
            saveGroupEdit(group.id, in: &document) { $0.isArchived = value }; try persist(document); return
        }
        document.metadata[id, default: LocalFindMetadata()].isArchived = value; try persist(document)
    }
    func delete(_ id: String) throws {
        var document = try document()
        let group = try group(id, in: document)
        let attachments = group.members.flatMap { document.metadata.removeValue(forKey: $0)?.attachments ?? [] }
        document.items.removeAll { group.members.contains($0.id) }
        document.groupEdits?.removeValue(forKey: group.id)
        try persist(document)
        for attachment in attachments {
            attachmentDigests.removeValue(forKey: attachment.relativePath)
            try? FileManager.default.removeItem(at: attachmentURL(attachment))
        }
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
    enum LocalError: LocalizedError {
        case invalidLink, invalidContent, invalidIntents, invalidMedia, mediaTooLarge, missingItem
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Add a valid public link, a photo, a file, or some text. Links must use http or https without a username or password."
            case .invalidContent: return "Use a title up to 300 characters, a note up to 2,000, and text up to 12,000."
            case .invalidIntents: return "Choose up to 8 details, with up to 500 characters each."
            case .invalidMedia: return "This image could not be read. Choose a JPEG, PNG, or WebP image."
            case .mediaTooLarge: return "Choose up to 10 attachments, under 12 MB each and 24 MB in total."
            case .missingItem: return "This find is no longer in your library."
            }
        }
    }
}
