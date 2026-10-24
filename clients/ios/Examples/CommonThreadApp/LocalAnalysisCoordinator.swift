import Foundation
import CommonThreadKit

extension Notification.Name {
    static let localAnalysisChanged = Notification.Name("MymahFinds.localAnalysisChanged")
}

/// Saved inputs on disk are the queue. Closing a capture sheet does not own or cancel
/// this work; foregrounding the app retries interrupted work after relaunch/offline use.
@MainActor final class LocalAnalysisCoordinator {
    static let shared = LocalAnalysisCoordinator()
    private let library: LocalLibrary
    init(library: LocalLibrary = .shared) { self.library = library }
    private var pending: Task<Void, Never>?
    private struct Request: Hashable { let input: LocalAnalysisInput; let configuration: CaptureIntelligence.Configuration }
    private var running: [Request: Task<CaptureIntelligenceResult, Error>] = [:]
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
                while !Task.isCancelled && CaptureIntelligence.isConfigured {
                    let items = try await library.collection()
                    let metadata = try await library.metadata()
                    let candidate = items.first { item in
                        let state = metadata[item.id] ?? LocalFindMetadata()
                        return item.client != "sample" && !state.isArchived && state.analysis?.schemaVersion != 2
                            && !attempted.contains(LocalAnalysisInput(item, metadata: state))
                    }
                    guard let item = candidate else { return }
                    let input = LocalAnalysisInput(item, metadata: metadata[item.id] ?? LocalFindMetadata())
                    attempted.insert(input)
                    do { _ = try await analyze(item.id) }
                    catch is CancellationError {
                        // A newer edit/account can be picked up on the next pass.
                        if Task.isCancelled { attempted.remove(input); return }
                    }
                    catch { NotificationCenter.default.post(name: .localAnalysisChanged, object: nil) }
                }
            } catch { /* Local storage errors are shown by the Library itself. */ }
        }
    }

    func analyze(_ id: String) async throws -> CaptureIntelligenceResult {
        guard let configuration = try CaptureIntelligence.configuration(),
              let item = try await library.item(id),
              let metadata = try await library.metadata()[item.id] else { throw CaptureIntelligence.Failure.configuration }
        if let analysis = metadata.analysis, analysis.schemaVersion == 2 { return analysis }
        let input = LocalAnalysisInput(item, metadata: metadata)
        let request = Request(input: input, configuration: configuration)
        if let task = running[request] { return try await task.value }
        let task = Task<CaptureIntelligenceResult, Error> {
            var images: [Data] = []
            for attachment in metadata.attachments.filter(\.isImage) {
                images.append(try await library.attachmentData(attachment))
            }
            let recordings = metadata.attachments.filter(\.isAudio)
            guard recordings.count <= 1 else { throw MultimodalDraftAnalysis.Failure.unsupportedAudio }
            var audio: MultimodalDraftAnalysis.Audio?
            if let recording = recordings.first {
                let bytes = try await library.attachmentData(recording)
                audio = try MultimodalDraftAnalysis.Audio(data: bytes, filename: recording.filename)
            }
            let note = ([item.note] + metadata.selectedIntents).filter { !$0.isEmpty }.joined(separator: "\n")
            let result = try await CaptureIntelligence.analyze(url: item.originalUrl.isEmpty ? nil : item.originalUrl,
                title: item.title, text: item.selectedText, note: String(note.prefix(2000)), imageData: images.first,
                additionalImages: Array(images.dropFirst()), audio: audio, reviewedTranscript: metadata.reviewedTranscript)
            try Task.checkCancellation()
            guard try CaptureIntelligence.configuration() == configuration,
                  try await library.setAnalysis(result, matching: input) else { throw CancellationError() }
            NotificationCenter.default.post(name: .localAnalysisChanged, object: nil)
            return result
        }
        running[request] = task
        defer { running[request] = nil }
        return try await task.value
    }
}
