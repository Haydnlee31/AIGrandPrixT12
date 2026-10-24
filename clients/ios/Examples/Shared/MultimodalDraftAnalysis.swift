import Foundation
import CommonThreadKit

/// A separate analysis account never changes the local Library destination.
/// Drafts are temporary: no call to publish is made, and terminal/cancelled work
/// is deleted. Local saves remain available even if inference is interrupted.
enum MultimodalDraftAnalysis {
    enum Failure: LocalizedError {
        case disabled, tooManyImages, unsupportedAudio
        var errorDescription: String? {
            switch self {
            case .unsupportedAudio: "AI accepts one M4A or WAV recording, up to 60 seconds and 4 MB. Your file can still be saved locally."
            case .disabled: "Multimodal analysis is unavailable. You can still save locally."
            case .tooManyImages: "AI can compare up to four photos together. All photos can still be saved locally."
            }
        }
    }
    struct Audio: Sendable {
        let data: Data
        let mediaType: String
        init(data: Data, filename: String) throws {
            let ext = (filename as NSString).pathExtension.lowercased()
            guard ["m4a", "wav"].contains(ext), data.count <= 4 * 1024 * 1024 else { throw Failure.unsupportedAudio }
            self.data = data; self.mediaType = ext == "wav" ? "audio/wav" : "audio/mp4"
        }
    }
    static func analyze(origin: URL, token: String, title: String, text: String,
                        note: String, url: String?, images: [Data], audio: Audio? = nil, reviewedTranscript: String? = nil, client suppliedClient: CommonThreadClient? = nil) async throws -> CaptureIntelligenceResult {
        let client: CommonThreadClient
        if let suppliedClient { client = suppliedClient }
        else { client = try CommonThreadClient(baseURL: origin) { token } }
        guard try await client.multimodalCapabilities().enabled else { throw Failure.disabled }
        var capture = try await client.createMultimodalCapture(
            .init(title: title, text: text, note: note, url: url,
                  client: Bundle.main.bundleURL.pathExtension == "appex" ? .iosShareExtension : .iosApp), key: MutationKey())
        let captureID = capture.id
        defer {
            // A detached cleanup survives cancellation of a changing capture sheet.
            Task.detached {
                for attempt in 0..<3 {
                    do { _ = try await client.deleteMultimodalCapture(captureID, key: MutationKey()); return }
                    catch { if attempt < 2 { try? await Task.sleep(for: .seconds(2)) } }
                }
            }
        }
        for image in images {
            try Task.checkCancellation()
            capture = try await client.uploadMultimodalAsset(to: capture.id,
                request: .init(revision: capture.revision, mediaType: "image/jpeg", data: image), key: MutationKey())
        }
        if let audio {
            capture = try await client.uploadMultimodalAsset(to: capture.id,
                request: .init(revision: capture.revision, mediaType: audio.mediaType, data: audio.data), key: MutationKey())
        }
        if let reviewedTranscript, let asset = capture.assets.first(where: { $0.kind == "audio" }) {
            capture = try await client.updateMultimodalTranscript(asset.id, in: capture.id,
                edit: .init(revision: capture.revision, transcript: reviewedTranscript), key: MutationKey())
        }
        capture = try await client.analyzeMultimodalCapture(capture.id, revision: capture.revision, key: MutationKey())
        let ready = try await client.waitForMultimodalCapture(capture.id, expectedRevision: capture.revision, timeout: 110)
        try Task.checkCancellation()
        guard let preview = ready.result?.preview else { throw MultimodalClientError.invalidResponse }
        var result = CaptureIntelligenceResult(productName: preview.productName, categoryPath: preview.categoryPath,
            brand: preview.brand, style: preview.style, summary: preview.summary, uncertainties: preview.uncertainties,
            prompts: preview.prompts.map { .init(id: $0.id, text: $0.text, question: $0.question) },
            evidence: preview.evidence, analyzedAt: preview.analyzedAt ?? Date().timeIntervalSince1970, schemaVersion: 2)
        result.productAnalysis = ready.result?.analysis
        result.transcript = ready.assets.first(where: { $0.kind == "audio" })?.transcript
        return result
    }
}
