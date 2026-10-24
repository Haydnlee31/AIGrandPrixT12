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
    public var url: String
    public var title: String
    public var source: CaptureSource
    public var selectedText: String
    public var note: String
    public var client: CaptureClient
    public init(url: String, title: String, source: CaptureSource = .web, selectedText: String = "", note: String = "", client: CaptureClient = .iosApp) {
        self.url = url; self.title = title; self.source = source; self.selectedText = selectedText; self.note = note; self.client = client
    }
}
public struct CaptureReceipt: Codable, Sendable { public let id: String; public let status: String; public let duplicate: Bool }
public struct CollectionPage: Codable, Sendable { public let items: [SavedItem]; public let nextOffset: Int? }
public struct ItemList<Item: Codable & Sendable>: Codable, Sendable { public let items: [Item]; public let nextOffset: Int? }
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
    public var isEnriching: Bool { status == "pending" || status == "processing" }
    public var capturedDate: Date { Date(timeIntervalSince1970: capturedAt) }
}
public struct Suggestion: Codable, Sendable, Identifiable {
    public let id: String; public let itemId: String; public let kind: String; public let text: String
    public let claim: String; public let modelVersion: String; public let status: String
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
public struct AnnotationReceipt: Codable, Sendable { public let eventId: String; public let hypothesis: Hypothesis }
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
    }
}
