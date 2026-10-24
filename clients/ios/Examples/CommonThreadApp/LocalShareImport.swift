import Foundation
import CommonThreadKit

extension LocalLibrary {
    /// Acknowledges only after content is durable. A repeat import keeps the same ID.
    func importPendingShares() throws -> Int {
        let drafts = try LocalShareInbox.pending()
        var count = 0
        for draft in drafts {
            let host = URL(string: draft.url ?? "")?.host?.lowercased() ?? ""
            let source: CaptureSource = host == "instagram.com" || host.hasSuffix(".instagram.com") ? .instagram : .web
            let attachments = draft.attachments.map { LocalCaptureAttachment(filename: $0.filename, typeIdentifier: $0.typeIdentifier, data: $0.data) }
            _ = try captureContent(url: draft.url, title: draft.title, text: draft.text, note: draft.note,
                                   source: source, client: .iosShareExtension, attachments: attachments,
                                   id: draft.id.uuidString, deduplicateLink: false, capturedAt: draft.createdAt)
            try LocalShareInbox.remove(draft)
            count += 1
        }
        return count
    }
}
