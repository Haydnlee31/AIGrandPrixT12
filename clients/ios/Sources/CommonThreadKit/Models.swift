import Foundation

/// Preserves evolving JSON metadata without converting money into floating point values.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), integer(Int), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public enum CaptureSource: String, Codable, Sendable { case web, pinterest, instagram, article, product }
public enum CaptureClient: String, Codable, Sendable {
    case iosApp = "ios_app", iosShareExtension = "ios_share_extension", chromeExtension = "chrome_extension", web
}
public struct CaptureRequest: Codable, Sendable, Equatable {
    public var url: String?
    public var title: String
    public var source: CaptureSource
    public var selectedText: String
    public var note: String
    public var client: CaptureClient
    /// Base64 JPEG, PNG, or WebP data URL. Send a URL, an image, or both.
    public var imageDataUrl: String?
    /// Compatibility with the Chrome image-capture wire format. Prefer imageDataUrl for new callers.
    public var imageData: String?
    public init(url: String? = nil, title: String, source: CaptureSource = .web, selectedText: String = "", note: String = "", client: CaptureClient = .iosApp, imageDataUrl: String? = nil, imageData: String? = nil) {
        self.url = url; self.title = title; self.source = source; self.selectedText = selectedText; self.note = note; self.client = client; self.imageDataUrl = imageDataUrl; self.imageData = imageData
    }
}
public struct CaptureReceipt: Codable, Sendable { public let id: String; public let status: String; public let duplicate: Bool }
public struct SavedMedia: Codable, Sendable { public let imageData: String }
public struct CollectionPage: Codable, Sendable { public let items: [SavedItem]; public let nextOffset: Int? }
public struct LibrarySearchPage: Codable, Sendable {
    public let items: [SavedItem]
    public let nextOffset: Int?
    public let total: Int
    public let query: String
    public let category: String?
}
public struct AnalysisQueued: Codable, Sendable {
    public let id: String
    public let status: String
    public let revision: Int
    public let jobId: String?
    public let queued: Bool
}
public struct ItemList<Item: Codable & Sendable>: Codable, Sendable { public let items: [Item]; public let nextOffset: Int? }
public enum AnalysisStatus: String, Codable, Sendable { case pending, ready, unavailable, failed }
public enum ProductFactBasis: String, Codable, Sendable { case image, capturedText = "captured_text", userNote = "user_note" }
/// Observed is the model's evidence classification, not an external product verification.
public enum ProductFactCertainty: String, Codable, Sendable { case observed, inferred }
public struct ProductFact: Codable, Sendable {
    public let value: String
    public let basis: ProductFactBasis
    public let evidence: String
    public let certainty: ProductFactCertainty
}
public struct ProductAttribute: Codable, Sendable {
    public let name: String
    public let value: String
    public let basis: ProductFactBasis
    public let evidence: String
    public let certainty: ProductFactCertainty
}
public struct ProductObservation: Codable, Sendable {
    public let productType: String
    /// Ordered from broad category to the finest defensible subcategory.
    public let categoryPath: [String]
    /// Nil means unrecognized; do not infer a brand or model from style.
    public let brand: ProductFact?
    public let model: ProductFact?
    public let attributes: [ProductAttribute]
    public let useCases: [String]
    public let searchTerms: [String]
}
public struct ProductAnalysis: Codable, Sendable {
    public let schemaVersion: Int
    public let summary: String
    public let products: [ProductObservation]
    public let intentContext: [String]
    public let uncertainties: [String]
}
public struct SavedItem: Codable, Sendable, Identifiable {
    public let id: String
    public let originalUrl: String
    public let canonicalUrl: String
    public let title: String
    public let source: String
    public let client: String?
    public let selectedText: String
    public let note: String
    public let capturedAt: Double
    public let status: String
    public let features: [String: JSONValue]
    public let revision: Int
    public let suggestions: [Suggestion]
    public let responses: [UserEvent]
    public let hasImage: Bool
    /// An authenticated API-relative resource; never put an access token in its query string.
    public let imagePath: String?
    public let analysis: ProductAnalysis?
    public let analysisStatus: AnalysisStatus
    public var isEnriching: Bool { status == "pending" || status == "processing" }
    public var capturedDate: Date { Date(timeIntervalSince1970: capturedAt) }
    private enum CodingKeys: String, CodingKey {
        case id, originalUrl, canonicalUrl, title, source, client, selectedText, note, capturedAt, status, features, revision, suggestions, responses, hasImage, imagePath, analysis, analysisStatus
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); originalUrl = try c.decode(String.self, forKey: .originalUrl)
        canonicalUrl = try c.decode(String.self, forKey: .canonicalUrl); title = try c.decode(String.self, forKey: .title)
        source = try c.decode(String.self, forKey: .source); client = try c.decodeIfPresent(String.self, forKey: .client)
        selectedText = try c.decode(String.self, forKey: .selectedText); note = try c.decode(String.self, forKey: .note)
        capturedAt = try c.decode(Double.self, forKey: .capturedAt); status = try c.decode(String.self, forKey: .status)
        features = try c.decode([String: JSONValue].self, forKey: .features); revision = try c.decode(Int.self, forKey: .revision)
        suggestions = try c.decode([Suggestion].self, forKey: .suggestions); responses = try c.decode([UserEvent].self, forKey: .responses)
        hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        analysis = try c.decodeIfPresent(ProductAnalysis.self, forKey: .analysis)
        analysisStatus = try c.decodeIfPresent(AnalysisStatus.self, forKey: .analysisStatus)
            ?? (status == "pending" ? .pending : status == "enrichment_failed" ? .failed : analysis == nil ? .unavailable : .ready)
    }
}
public enum AnnotationIntent: String, Codable, Sendable {
    case buy = "buy_intent", trackDiscount = "track_discount", remindLater = "remind_later"
    case saveInspiration = "save_inspiration", compareOptions = "compare_options"
}
public struct Suggestion: Codable, Sendable, Identifiable {
    public let id: String; public let itemId: String; public let kind: String; public let text: String
    public let claim: String; public let modelVersion: String; public let status: String
    public let intent: AnnotationIntent?
    public let requiresConfirmation: Bool
    public let nextStep: String?
    private enum CodingKeys: String, CodingKey { case id, itemId, kind, text, claim, modelVersion, status, intent, requiresConfirmation, nextStep }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); itemId = try c.decode(String.self, forKey: .itemId)
        kind = try c.decode(String.self, forKey: .kind); text = try c.decode(String.self, forKey: .text)
        claim = try c.decode(String.self, forKey: .claim); modelVersion = try c.decode(String.self, forKey: .modelVersion)
        status = try c.decode(String.self, forKey: .status); intent = try c.decodeIfPresent(AnnotationIntent.self, forKey: .intent)
        requiresConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? true
        nextStep = try c.decodeIfPresent(String.self, forKey: .nextStep)
    }
}
public struct UserEvent: Codable, Sendable, Identifiable {
    public let id: String; public let itemId: String?; public let eventType: String
    public let payload: [String: JSONValue]; public let occurredAt: Double
}
public struct Evidence: Codable, Sendable, Identifiable {
    public let id: String; public let itemId: String; public let claim: String; public let text: String
    public let origin: String; public let relation: String
}
public struct NextAction: Codable, Sendable {
    public let actionType: String; public let evidenceIds: [String]; public let reasonCodes: [String]
    public let missingInformation: [String]; public let contextVersion: Int?
}
public struct Hypothesis: Codable, Sendable, Identifiable {
    public let id: String; public let goal: String; public let supportScore: Double; public let scoreKind: String
    public let independentSaves: Int; public let readiness: String; public let confirmedPreferences: [String]
    public let evidence: [Evidence]; public let contextVersion: Int; public let status: String; public let decision: NextAction
}
public struct AnnotationRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case select, edit, reject, skip }
    public let action: Action; public let suggestionId: String?; public let text: String
    public init(action: Action, suggestionId: String? = nil, text: String = "") { self.action = action; self.suggestionId = suggestionId; self.text = text }
}
public struct AnnotationReceipt: Codable, Sendable {
    public let eventId: String; public let hypothesis: Hypothesis
    public let intent: AnnotationIntent?
    /// "annotation_only" records the choice; it does not purchase, monitor, or schedule.
    public let executionStatus: String
    public let analysisJobId: String?
    public let savedRevision: Int?
    private enum CodingKeys: String, CodingKey { case eventId, hypothesis, intent, executionStatus, analysisJobId, savedRevision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(String.self, forKey: .eventId); hypothesis = try c.decode(Hypothesis.self, forKey: .hypothesis)
        intent = try c.decodeIfPresent(AnnotationIntent.self, forKey: .intent)
        executionStatus = try c.decodeIfPresent(String.self, forKey: .executionStatus) ?? "annotation_only"
        analysisJobId = try c.decodeIfPresent(String.self, forKey: .analysisJobId)
        savedRevision = try c.decodeIfPresent(Int.self, forKey: .savedRevision)
    }
}
public enum HypothesisFeedback: String, Codable, Sendable { case confirm, dismiss, keepCollecting = "keep_collecting", misunderstood }
public struct DiscoverySession: Codable, Sendable, Identifiable {
    public let id: String; public let version: Int; public let stage: String; public let preferences: [String: JSONValue]
    public let evidenceIds: [String]; public let contextVersion: Int; public let createdAt: Double
    public let contextStale: Bool; public let products: [Product]; public let nextAction: NextAction
}
public struct DiscoveryEvent: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case direction, lessClutter = "less_clutter", budget, maxWidth = "max_width", retrieve, choose, pause, dismiss, resume
        case alreadyOwn = "already_own", tooExpensive = "too_expensive", handoff
    }
    public enum Value: Codable, Sendable {
        case text(String), integer(Int)
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let value = try? c.decode(Int.self) { self = .integer(value) } else { self = .text(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .text(let value): try c.encode(value); case .integer(let value): try c.encode(value) }
        }
    }
    public let expectedVersion: Int; public let action: Action; public let value: Value?
    public init(expectedVersion: Int, action: Action, value: Value? = nil) { self.expectedVersion = expectedVersion; self.action = action; self.value = value }
}
public struct Product: Codable, Sendable, Identifiable {
    public var id: String { variantId }
    public let variantId: String; public let name: String; public let variant: String; public let merchant: String
    public let priceMinor: Int; public let currency: String; public let widthCm: Int; public let style: String
    public let compact: Bool; public let inStock: Bool; public let tradeoff: String; public let sourceRecord: String
    public let dataMode: String; public let shippingMinor: Int?; public let merchantUrl: String?
    public let fitScore: Int?; public let explanation: String?
}
public struct Catalog: Codable, Sendable { public let items: [Product]; public let dataMode: String }

/// Source names are extensible: the backend decides which registered sources exist.
public struct CatalogSource: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    public static let impact = Self(rawValue: "impact"), cj = Self(rawValue: "cj")
    public static let rakuten = Self(rawValue: "rakuten")
    public static let abo = Self(rawValue: "abo"), wands = Self(rawValue: "wands")
    public static let openBeautyFacts = Self(rawValue: "open_beauty_facts")
    public static let openProductsFacts = Self(rawValue: "open_products_facts")
    public static let openFoodFacts = Self(rawValue: "open_food_facts")
    public static let uciRetail = Self(rawValue: "uci_retail"), northwind = Self(rawValue: "northwind")
    public static let adventureWorks = Self(rawValue: "adventureworks"), synthetic = Self(rawValue: "synthetic")
}
public struct CatalogMerchant: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let platform: CatalogSource
}
public struct CatalogOffer: Codable, Sendable {
    public let id: String
    /// Exact minor units in currency; nil means unknown, never free.
    public let priceMinor: Int?
    public let currency: String?
    public let shippingMinor: Int?
    /// "unknown", "in_stock", or "out_of_stock"; do not infer stock from listing presence.
    public let availability: String
    public let condition: String?
    public let url: String?
    public let imageUrl: String?
    public let observedAt: Double?
    public let expiresAt: Double?
    public let marketplaceId: String?
    public let environment: String
    /// Nil means no current-offer expiry was provided, not an offer that never expires.
    public func isExpired(at date: Date = Date()) -> Bool? { expiresAt.map { $0 <= date.timeIntervalSince1970 } }
    /// Only a bounded observation window is current. This does not establish stock or delivery.
    public func hasCurrentObservation(at date: Date = Date()) -> Bool {
        guard let observedAt, let expiresAt else { return false }
        return observedAt <= date.timeIntervalSince1970 && date.timeIntervalSince1970 < expiresAt
    }
}
/// A normalized source record, separate from saved Library content.
public struct CatalogRecord: Codable, Sendable, Identifiable {
    public var id: String { "\(sourceId.rawValue):\(sourceRecordId)" }
    public let sourceId: CatalogSource
    public let sourceRecordId: String
    /// merchant_feed, merchant_api, open_dataset, or synthetic. Historical/sample facts are not live offers.
    public let dataKind: String
    public let title: String
    public let description: String?
    public let category: String?
    public let brand: String?
    public let attributes: [String: JSONValue]
    public let productKey: String?
    public let variantKey: String?
    public let merchant: CatalogMerchant
    public let offer: CatalogOffer
    public let provenance: [String: JSONValue]
}
public struct CatalogSearchPage: Codable, Sendable {
    public let items: [CatalogRecord]
    public let sourceId: CatalogSource
    public let nextOffset: Int?
    public let total: Int
    public let fetchedAt: Double
    public let expiresAt: Double?
    public let environment: String
    public let marketplace: String?
    public let retrieval: String
}
public enum ExploreReasonKind: String, Codable, Sendable {
    case categoryMatch = "category_match", attributeMatch = "attribute_match", brandMatch = "brand_match"
    case confirmedIntent = "confirmed_intent", queryMatch = "query_match"
}
public struct ExploreReason: Codable, Sendable {
    public let kind: ExploreReasonKind
    public let text: String
    public let savedItemId: String?
    public let savedItemTitle: String?
    public let savedItemRevision: Int?
    public let analysisPath: String?
    public let evidenceId: String?
    public let matchedValue: String
    public let catalogField: String?
    public let catalogValue: String?
}
public struct CatalogCitation: Codable, Sendable {
    public let sourceId: CatalogSource
    public let recordId: String
    public let title: String
    public let licenseId: String?
    public let licenseUrl: String?
    public let attribution: String?
    public let recordUrl: String?
}
public enum ExploreAction: String, Codable, Sendable { case viewOffer = "view_offer", viewSource = "view_source" }
public struct ExploreItem: Codable, Sendable, Identifiable {
    public var id: String { product.id }
    public let product: CatalogRecord
    /// A retrieval heuristic, never a probability of preference or purchase.
    public let score: Double
    public let scoreKind: String
    public let reasons: [ExploreReason]
    public let catalogCitation: CatalogCitation
    public let action: ExploreAction
    public let actionUrl: String?
}
public enum ExploreMode: String, Codable, Sendable { case personalized, search }
public enum ExploreStatus: String, Codable, Sendable {
    case ready, needsSaves = "needs_saves", needsAnalysis = "needs_analysis", noMatches = "no_matches"
}
public struct ExplorePage: Codable, Sendable {
    public let items: [ExploreItem]
    public let sourceId: CatalogSource
    public let query: String
    public let mode: ExploreMode
    public let status: ExploreStatus
    public let nextOffset: Int?
    public let candidateCount: Int
    public let candidateLimit: Int
    public let candidateWindowLimited: Bool
    public let personalizedFromSaves: Int
    public let profileLimit: Int
    public let profileWindowLimited: Bool
    public let contextVersion: Int
    public let generatedAt: Double
    public let rankingVersion: String
    public let expiresAt: Double?
}
public struct CatalogSourceStatus: Codable, Sendable, Identifiable {
    public var id: CatalogSource { sourceId }
    public let sourceId: CatalogSource
    /// Local sources have imported data; live sources have server credentials. Neither verifies merchant access or stock.
    public let configured: Bool
    public let enabledFeeds: Int
    public let freshRecords: Int?
    public let recordCount: Int
    public let dataKind: String
    public let name: String
    public let licenseId: String?
    public let licenseUrl: String?
    public let attribution: String?
    public let environment: String
    public let marketplace: String?
    public let retrieval: String
    public let allowedUses: [String]
    public let aiUse: String
    public let persistence: String
}
public struct CatalogSources: Codable, Sendable { public let items: [CatalogSourceStatus] }

public struct WatchRequest: Codable, Sendable {
    public let variantId: String; public let currency: String; public let targetMinor: Int
    public init(variantId: String, currency: String = "SGD", targetMinor: Int) { self.variantId = variantId; self.currency = currency; self.targetMinor = targetMinor }
}
public struct WatchUpdate: Codable, Sendable {
    public let enabled: Bool?; public let targetMinor: Int?
    public init(enabled: Bool? = nil, targetMinor: Int? = nil) { self.enabled = enabled; self.targetMinor = targetMinor }
}
public struct PriceWatch: Codable, Sendable, Identifiable {
    public let id: String; public let variantId: String; public let currency: String; public let targetMinor: Int
    public let enabled: Bool; public let ruleVersion: Int; public let below: Bool; public let episode: Int
    public let lastPriceMinor: Int?; public let lastCheckedAt: Double?; public let priceBasis: String?; public let dataMode: String?
}
public struct PriceSimulation: Codable, Sendable {
    public let amountMinor: Int; public let variantId: String; public let currency: String
    public init(amountMinor: Int, variantId: String, currency: String = "SGD") { self.amountMinor = amountMinor; self.variantId = variantId; self.currency = currency }
}
public struct JobReceipt: Codable, Sendable { public let jobId: String; public let dataMode: String }
public struct JobStatus: Codable, Sendable, Identifiable {
    public let id: String; public let kind: String; public let status: String; public let attempts: Int; public let error: String?
}
public struct AppNotification: Codable, Sendable, Identifiable {
    public let id: String; public let watchId: String; public let observationId: String; public let dedupeKey: String
    public let message: String; public let deliveryStatus: String
}
public struct Account: Codable, Sendable { public let userId: String; public let demoMode: Bool; public let inferenceProvider: String }
public struct DeleteReceipt: Codable, Sendable { public let deleted: Bool }
public struct Capabilities: Codable, Sendable {
    public let apiVersion: String; public let contractVersion: String; public let authentication: String
    public let capture: CaptureLimits; public let dataModes: [String: String]; public let features: [String: Bool]
    public let currencies: [String]; public let refresh: [String: JSONValue]
    public struct CaptureLimits: Codable, Sendable {
        public let clients: [String]; public let contentTypes: [String]; public let maxUrlLength: Int
        public let maxTitleLength: Int; public let maxSelectedTextLength: Int; public let maxNoteLength: Int
        public let maxImageBytes: Int?
    }
}
