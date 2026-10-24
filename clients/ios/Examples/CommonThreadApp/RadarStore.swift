import Foundation

struct RadarBrief: Codable, Equatable, Sendable {
    var intention = ""
    var searchTerms = ""
    var mustHaves = ""
    var budget = ""
    var currency = "SGD"
    var smallSpace = false
    var fitNotes = ""
    var sourceIDs: [String] = []
    var product = ""
    var brand = ""
    var category = ""

    func validated() throws -> Self {
        var value = self
        value.intention = intention.trimmingCharacters(in: .whitespacesAndNewlines)
        value.searchTerms = searchTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        value.mustHaves = mustHaves.trimmingCharacters(in: .whitespacesAndNewlines)
        value.budget = budget.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fitNotes = fitNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.intention.contains(where: { $0.isLetter || $0.isNumber }), value.intention.count <= 300,
              value.searchTerms.count <= 100, value.mustHaves.count <= 500,
              value.fitNotes.count <= 300, ["SGD", "USD", "GBP", "EUR"].contains(currency),
              sourceIDs.count <= 24, sourceIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              [product, brand, category].allSatisfy({ $0.count <= 300 }) else { throw RadarStoreError.invalidBrief }
        if !value.budget.isEmpty {
            guard let amount = Decimal(string: value.budget, locale: Locale(identifier: "en_US_POSIX")),
                  amount > 0, amount <= 1_000_000_000,
                  value.budget.allSatisfy({ $0.isNumber || $0 == "." }),
                  value.budget.filter({ $0 == "." }).count <= 1 else { throw RadarStoreError.invalidBudget }
        }
        value.sourceIDs = Array(NSOrderedSet(array: sourceIDs)) as? [String] ?? sourceIDs
        return value
    }
}

enum RadarScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case product, brand, category, need
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func suggestedTarget(for brief: RadarBrief) -> String {
        switch self { case .product: brief.product; case .brand: brief.brand; case .category: brief.category; case .need: brief.intention }
    }
}

enum RadarFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case manually, daily, weekly
    var id: String { rawValue }
    var title: String {
        switch self { case .manually: "When I check"; case .daily: "Daily"; case .weekly: "Weekly" }
    }
}

struct RadarWatch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var brief: RadarBrief
    var scope = RadarScope.need
    var target: String
    var conditions = ""
    var frequency = RadarFrequency.manually
    var isPaused = false
    var createdAt = Date()
    var updatedAt = Date()
    var lastCheckedAt: Date?

    func validated() throws -> Self {
        var value = self
        value.brief = try brief.validated()
        value.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        value.conditions = conditions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.target.contains(where: { $0.isLetter || $0.isNumber }), value.target.count <= 300,
              value.conditions.count <= 500 else { throw RadarStoreError.invalidTarget }
        return value
    }
}

enum RadarStoreError: LocalizedError {
    case invalidBrief, invalidBudget, invalidTarget, full, missing, unreadable
    var errorDescription: String? {
        switch self {
        case .invalidBrief: "Add a short intention and keep your details within the limits."
        case .invalidBudget: "Enter a positive budget using numbers and a decimal point."
        case .invalidTarget: "Choose a specific product, brand, category, or need to track."
        case .full: "You can keep up to 100 needs. Remove one before adding another."
        case .missing: "This need is no longer saved."
        case .unreadable: "Your saved needs could not be opened. They have not been changed."
        }
    }
}

/// Saves review preferences only. This store never schedules jobs or notifications.
actor RadarStore {
    static let shared = RadarStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MymahFinds", isDirectory: true).appendingPathComponent("intent-radar.json"))
    private struct Document: Codable { var version = 1; var watches: [RadarWatch] = [] }
    private let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func all() throws -> [RadarWatch] { try read().watches.sorted { $0.updatedAt > $1.updatedAt } }
    @discardableResult func save(_ watch: RadarWatch) throws -> RadarWatch {
        var value = try watch.validated()
        var document = try read()
        value.updatedAt = Date()
        if let index = document.watches.firstIndex(where: { $0.id == value.id }) {
            let previous = document.watches[index]
            value.createdAt = previous.createdAt
            value.lastCheckedAt = previous.matchesSearch(value) ? previous.lastCheckedAt : nil
            document.watches[index] = value
        } else {
            guard document.watches.count < 100 else { throw RadarStoreError.full }
            document.watches.append(value)
        }
        try write(document)
        return value
    }
    func setPaused(_ id: UUID, _ paused: Bool) throws {
        var document = try read()
        guard let index = document.watches.firstIndex(where: { $0.id == id }) else { throw RadarStoreError.missing }
        document.watches[index].isPaused = paused; document.watches[index].updatedAt = Date()
        try write(document)
    }
    func recordCheck(_ checked: RadarWatch) throws {
        var document = try read()
        guard let index = document.watches.firstIndex(where: { $0.id == checked.id }),
              !document.watches[index].isPaused, document.watches[index].matchesSearch(checked) else { return }
        document.watches[index].lastCheckedAt = Date()
        try write(document)
    }
    func remove(_ id: UUID) throws {
        var document = try read()
        document.watches.removeAll { $0.id == id }
        try write(document)
    }
    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document() }
        guard let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
              let document = try? JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL)),
              document.version == 1, document.watches.count <= 100 else { throw RadarStoreError.unreadable }
        return document
    }
    private func write(_ document: Document) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private extension RadarWatch {
    func matchesSearch(_ other: RadarWatch) -> Bool {
        brief == other.brief && scope == other.scope && target == other.target && conditions == other.conditions
    }
}
