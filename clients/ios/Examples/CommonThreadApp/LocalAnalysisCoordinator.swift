import Foundation
import CommonThreadKit

extension Notification.Name {
    static let localAnalysisChanged = Notification.Name("MymahFinds.localAnalysisChanged")
}

/// Saved inputs on disk are the queue. Closing a capture sheet does not own or cancel
/// this work; foregrounding the app retries interrupted work after relaunch/offline use.
@MainActor final class LocalAnalysisCoordinator {
    static let shared = LocalAnalysisCoordinator()
    private var pending: Task<Void, Never>?
    private var running: [LocalAnalysisInput: Task<CaptureIntelligenceResult, Error>] = [:]
    private var attempted: Set<LocalAnalysisInput> = []
    private var connection: CaptureIntelligence.Configuration?

    func resume(retryFailures: Bool = false) {
        guard CaptureIntelligence.isConfigured else { return }
        let configured = try? CaptureIntelligence.configuration()
        if configured != connection { attempted.removeAll(); connection = configured }
        if retryFailures { attempted.removeAll() }
        guard pending == nil else { return }
        pending = Task {
            defer { pending = nil }
            do {
                let items = try await LocalLibrary.shared.collection()
                let metadata = try await LocalLibrary.shared.metadata()
                for item in items where item.client != "sample" && metadata[item.id]?.isArchived != true {
                    guard !Task.isCancelled, CaptureIntelligence.isConfigured else { return }
                    let state = metadata[item.id] ?? LocalFindMetadata()
                    guard state.analysis?.schemaVersion != 2 else { continue }
                    let input = LocalAnalysisInput(item, metadata: state)
                    guard attempted.insert(input).inserted else { continue }
                    do { _ = try await analyze(item.id) }
                    catch is CancellationError { attempted.remove(input); return }
                    catch { NotificationCenter.default.post(name: .localAnalysisChanged, object: nil) }
                }
            } catch { /* Local storage errors are shown by the Library itself. */ }
        }
    }

    func analyze(_ id: String) async throws -> CaptureIntelligenceResult {
        guard let configuration = try CaptureIntelligence.configuration(),
              let item = try await LocalLibrary.shared.item(id),
              let metadata = try await LocalLibrary.shared.metadata()[item.id] else { throw CaptureIntelligence.Failure.configuration }
        if let analysis = metadata.analysis, analysis.schemaVersion == 2 { return analysis }
        let input = LocalAnalysisInput(item, metadata: metadata)
        if let task = running[input] { return try await task.value }
        let task = Task<CaptureIntelligenceResult, Error> {
            var images: [Data] = []
            for attachment in metadata.attachments.filter(\.isImage) {
                images.append(try await LocalLibrary.shared.attachmentData(attachment))
            }
            let recordings = metadata.attachments.filter(\.isAudio)
            guard recordings.count <= 1 else { throw MultimodalDraftAnalysis.Failure.unsupportedAudio }
            var audio: MultimodalDraftAnalysis.Audio?
            if let recording = recordings.first {
                let bytes = try await LocalLibrary.shared.attachmentData(recording)
                audio = try MultimodalDraftAnalysis.Audio(data: bytes, filename: recording.filename)
            }
            let note = ([item.note] + metadata.selectedIntents).filter { !$0.isEmpty }.joined(separator: "\n")
            let result = try await CaptureIntelligence.analyze(url: item.originalUrl.isEmpty ? nil : item.originalUrl,
                title: item.title, text: item.selectedText, note: String(note.prefix(2000)), imageData: images.first,
                additionalImages: Array(images.dropFirst()), audio: audio, reviewedTranscript: metadata.reviewedTranscript)
            try Task.checkCancellation()
            guard try CaptureIntelligence.configuration() == configuration,
                  try await LocalLibrary.shared.setAnalysis(result, matching: input) else { throw CancellationError() }
            NotificationCenter.default.post(name: .localAnalysisChanged, object: nil)
            return result
        }
        running[input] = task
        defer { running[input] = nil }
        return try await task.value
    }
}
