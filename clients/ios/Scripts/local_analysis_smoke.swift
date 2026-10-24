// The real coordinator/store run against an in-memory model provider, never the user's Library.
import Foundation
import CommonThreadKit

@MainActor enum CaptureIntelligence {
    struct Configuration: Hashable { let account: String }
    enum Failure: Error { case configuration }
    static var current = Configuration(account: "alice")
    static var calls = 0
    static var observedImages = 0
    static var observedVoice = false
    static var observedNote = ""
    static var isConfigured: Bool { true }
    static func configuration() throws -> Configuration? { current }
    static func analyze(url: String?, title: String, text: String, note: String, imageData: Data?, additionalImages: [Data],
                        audio: MultimodalDraftAnalysis.Audio?, reviewedTranscript: String?) async throws -> CaptureIntelligenceResult {
        calls += 1; observedImages = (imageData == nil ? 0 : 1) + additionalImages.count; observedVoice = audio != nil; observedNote = note
        try await Task.sleep(for: .milliseconds(120))
        var result = CaptureIntelligenceResult(productName: nil, categoryPath: ["Watches"], brand: nil, style: [], summary: "A watch",
            uncertainties: [], prompts: [], evidence: [], analyzedAt: Date().timeIntervalSince1970, schemaVersion: 2)
        result.transcript = reviewedTranscript ?? "Original speech"
        return result
    }
}
private enum Failure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure.assertion(message) } }
@main @MainActor struct LocalAnalysisSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mymah-analysis-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalLibrary(fileURL: directory.appendingPathComponent("library.json"))
        let saved = try await store.captureContent(title: "Watch", text: "A digital watch", note: "A gift", attachments: [
            .init(filename: "one.jpg", typeIdentifier: "public.jpeg", data: Data([1, 2, 3])),
            .init(filename: "two.jpg", typeIdentifier: "public.jpeg", data: Data([4, 5, 6])),
            .init(filename: "voice.m4a", typeIdentifier: "com.apple.m4a-audio", data: Data([7, 8, 9]))], intents: ["Avoid metal straps"])
        try await store.setReviewedTranscript(saved.id, "A gift for my mum")
        let coordinator = LocalAnalysisCoordinator(library: store)
        async let first = coordinator.analyze(saved.id)
        async let second = coordinator.analyze(saved.id)
        let (result, _) = try await (first, second)
        try check(CaptureIntelligence.calls == 1, "screens coalesce the same saved input")
        try check(CaptureIntelligence.observedImages == 2 && CaptureIntelligence.observedVoice, "saved reanalysis includes every photo and voice")
        try check(CaptureIntelligence.observedNote.contains("Avoid metal straps") && result.transcript == "A gift for my mum", "confirmed preferences and corrected transcript join analysis")
        let persisted = try await store.metadata()[saved.id]!
        try check(persisted.analysis?.transcript == "A gift for my mum", "completed analysis survives independent sheet lifetime")

        try await store.update(saved.id, title: "Watch", note: "First note", text: "A digital watch")
        let editing = Task { try await coordinator.analyze(saved.id) }
        try await Task.sleep(for: .milliseconds(30))
        try await store.update(saved.id, title: "Watch", note: "Newer note", text: "A digital watch")
        do { _ = try await editing.value; throw Failure.assertion("old edit applied") } catch is CancellationError {}
        let changed = try await store.metadata()[saved.id]!
        try check(changed.analysis == nil, "an edit during analysis withdraws stale output")
        _ = try await coordinator.analyze(saved.id)

        try await store.update(saved.id, title: "Watch", note: "Another note", text: "A digital watch")
        let switching = Task { try await coordinator.analyze(saved.id) }
        try await Task.sleep(for: .milliseconds(30)); CaptureIntelligence.current = .init(account: "bob")
        do { _ = try await switching.value; throw Failure.assertion("previous account result applied") } catch is CancellationError {}
        _ = try await coordinator.analyze(saved.id)

        try await store.update(saved.id, title: "Watch", note: "Remove this", text: "A digital watch")
        let deleting = Task { try await coordinator.analyze(saved.id) }
        try await Task.sleep(for: .milliseconds(30)); try await store.delete(saved.id)
        do { _ = try await deleting.value; throw Failure.assertion("deleted find recreated") } catch is CancellationError {}
        let remaining = try await store.collection()
        try check(remaining.isEmpty, "deletion during analysis never recreates a find")
        print("PASS saved-flow coalescing, all-media context, transcript persistence, edit/account/deletion races")
    }
}
