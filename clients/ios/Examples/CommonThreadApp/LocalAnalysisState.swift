import Foundation
import CommonThreadKit

/// Includes every user-owned input so delayed work cannot overwrite edits or a deletion.
struct LocalAnalysisInput: Hashable, Sendable {
    let id: String
    let url: String
    let title: String
    let text: String
    let note: String
    let attachmentIDs: [UUID]
    let intents: [String]
    let reviewedTranscript: String?
    init(_ item: SavedItem, metadata: LocalFindMetadata) {
        id = item.id; url = item.originalUrl; title = item.title; text = item.selectedText; note = item.note
        attachmentIDs = metadata.attachments.map(\.id); intents = metadata.selectedIntents
        reviewedTranscript = metadata.reviewedTranscript
    }
}

extension LocalLibrary {
    func analysisInput(_ id: String) throws -> LocalAnalysisInput? {
        guard let item = try item(id), let metadata = try metadata()[item.id] else { return nil }
        return LocalAnalysisInput(item, metadata: metadata)
    }
    /// Comparison and commit execute together on the storage actor.
    func setAnalysis(_ analysis: CaptureIntelligenceResult, matching input: LocalAnalysisInput) throws -> Bool {
        try Task.checkCancellation()
        guard try analysisInput(input.id) == input else { return false }
        try setAnalysis(input.id, analysis)
        return true
    }
}
