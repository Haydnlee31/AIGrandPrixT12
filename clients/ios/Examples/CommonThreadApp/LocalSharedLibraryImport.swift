import Foundation
import CommonThreadKit

extension LocalLibrary {
    /// Explicit one-time copies. Local originals, metadata and attachments survive.
    /// The outbox remembers source → server receipts across restarts and deletions.
    func copyToSharedLibrary(_ environment: SharedEnvironment, limits: Capabilities.CaptureLimits) async throws -> String {
        let outbox = try SharedEnvironment.outbox()
        let saved = try collection()
        let details = try metadata()
        var queued = 0, alreadyCopied = 0, keptLocal = 0
        for item in saved where item.client != "sample" {
            if try await outbox.hasImported(sourceId: item.id, accountId: environment.accountId, baseURL: environment.baseURL) {
                alreadyCopied += 1; continue
            }
            let flags = details[item.id] ?? LocalFindMetadata()
            do {
                let attachments = try flags.attachments.map { attachment in
                    SharedCaptureRequest.Attachment(data: try attachmentData(attachment), isImage: attachment.isImage)
                }
                let request = try SharedCaptureRequest.prepare(url: item.originalUrl, title: item.title,
                    text: item.selectedText, note: item.note, intents: flags.selectedIntents,
                    source: CaptureSource(rawValue: item.source) ?? .web, client: .iosApp,
                    attachments: attachments, limits: limits)
                if try await outbox.enqueueImport(request: request, sourceId: item.id, accountId: environment.accountId, baseURL: environment.baseURL) { queued += 1 }
                else { alreadyCopied += 1 }
            } catch is SharedCaptureRequest.PreparationError { keptLocal += 1 }
        }
        return "\(queued) queued, \(alreadyCopied) already copied, \(keptLocal) unsupported. All originals remain on this iPhone."
    }
}
