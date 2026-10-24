import Foundation

/// Server-owned model configuration and limits. No provider credential belongs in the app.
public struct MultimodalCapabilities: Codable, Sendable {
    public let enabled: Bool
    public let schemaVersion: Int
    public let contentTypes: [String]
    public let maxAssets: Int
    public let maxImages: Int
    public let maxAudio: Int
    public let maxAssetBytes: Int
    public let actionsExecute: Bool
}

/// An analysis draft is independent of the local Library. Publication is a separate explicit action.
public struct MultimodalCaptureRequest: Codable, Sendable, Equatable {
    public var title: String
    public var text: String
    public var note: String
    public var url: String?
    public var client: CaptureClient
    public init(title: String = "", text: String = "", note: String = "", url: String? = nil, client: CaptureClient = .iosApp) {
        self.title = title; self.text = text; self.note = note; self.url = url; self.client = client
    }
}

/// Nil leaves a field unchanged. An empty string explicitly clears it. Edits invalidate prior analysis.
public struct MultimodalCaptureEdit: Codable, Sendable, Equatable {
    public var revision: Int
    public var title: String?
    public var text: String?
    public var note: String?
    public init(revision: Int, title: String? = nil, text: String? = nil, note: String? = nil) {
        self.revision = revision; self.title = title; self.text = text; self.note = note
    }
}

/// Persist this exact payload and its mutation key for retries. Uploads return a new capture revision.
public struct MultimodalAssetRequest: Codable, Sendable, Equatable {
    public var revision: Int
    public let mediaType: String
    public let dataBase64: String
    public init(revision: Int, mediaType: String, data: Data) throws {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw MultimodalClientError.invalidAsset }
        self.revision = revision; self.mediaType = mediaType; self.dataBase64 = data.base64EncodedString()
    }
}

public struct MultimodalAsset: Codable, Sendable, Identifiable {
    public let id: String
    public let mediaType: String
    public let kind: String
    public let sizeBytes: Int
    public let status: String
    public let transcript: String?
    public let transcriptOrigin: String?
}

public struct MultimodalTranscriptEdit: Codable, Sendable, Equatable {
    public var revision: Int
    public var transcript: String
    public init(revision: Int, transcript: String) {
        self.revision = revision; self.transcript = transcript
    }
}

/// Same wire shape as the native capture preview, with no dependency on the example application's UI.
public struct MultimodalPreview: Codable, Sendable {
    public struct Prompt: Codable, Sendable, Identifiable {
        public let id: String
        public let text: String
        public let question: String?
    }
    public let productName: String?
    public let categoryPath: [String]
    public let brand: String?
    public let style: [String]
    public let summary: String
    public let uncertainties: [String]
    public let evidence: [String]
    public let prompts: [Prompt]
    public let schemaVersion: Int
    public let analyzedAt: Double?
}

public struct MultimodalResult: Codable, Sendable {
    public let analysis: ProductAnalysis
    public let preview: MultimodalPreview
    public let sourceAssets: [String]
    private enum CodingKeys: String, CodingKey { case analysis, preview, sourceAssets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        analysis = try values.decode(ProductAnalysis.self, forKey: .analysis)
        preview = try values.decode(MultimodalPreview.self, forKey: .preview)
        sourceAssets = try values.decode([String].self, forKey: .sourceAssets)
        guard analysis.schemaVersion == 1, preview.schemaVersion == 2 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported multimodal analysis schema version"))
        }
    }
}

public struct MultimodalCapture: Codable, Sendable, Identifiable {
    public let id: String
    public let revision: Int
    /// Outer statuses remain compatible across detailed processing stages.
    public let status: String
    public let stage: String
    public let title: String
    public let text: String
    public let note: String
    public let url: String?
    public let client: String
    public let assets: [MultimodalAsset]
    public let result: MultimodalResult?
    public let errorCode: String?
    public let createdAt: Double
    public let updatedAt: Double
    /// A published capture is frozen. Remove the shared save through deleteSavedItem to revoke its evidence.
    public let publishedSaveId: String?
}

public enum MultimodalClientError: Error, LocalizedError, Sendable {
    case invalidIdentifier, invalidRevision, invalidAsset, invalidPollingOptions, invalidResponse
    case staleRevision(expected: Int, actual: Int)
    case analysisFailed(code: String?)
    case pollingTimedOut
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "Use a single capture or asset ID returned by the multimodal API."
        case .invalidRevision: return "Use the latest positive capture revision returned by the server."
        case .invalidAsset: return "Upload a nonempty supported image or audio file of at most 4 MiB."
        case .invalidPollingOptions: return "Use a finite interval of at least 0.1 seconds and a timeout from zero to one day."
        case .invalidResponse: return "The server returned an unexpected multimodal response."
        case .staleRevision: return "The capture changed during analysis. Refresh before applying the result."
        case .analysisFailed: return "Your capture is stored, but analysis failed. Review it before retrying."
        case .pollingTimedOut: return "Your capture is stored and still processing. Refresh it later."
        }
    }
}

func validateMultimodalIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.unicodeScalars.count <= 200, ![".", ".."].contains(value),
          !value.contains("/"), !value.contains("\\"),
          value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw MultimodalClientError.invalidIdentifier }
}

func validateMultimodalRevision(_ value: Int) throws {
    guard value > 0 else { throw MultimodalClientError.invalidRevision }
}
