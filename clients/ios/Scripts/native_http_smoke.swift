// Real URLSession -> isolated FastAPI checks. Compiled alongside CommonThreadKit.
// Tokens below are documented local fixtures, never production credentials.
import Foundation

private enum SmokeFailure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}

@main
struct NativeHTTPSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let origin = URL(string: CommandLine.arguments[1]),
              origin.scheme == "http", origin.host == "127.0.0.1" else {
            throw SmokeFailure.assertion("Run native_http_smoke.sh against its isolated loopback API")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let alex = try CommonThreadClient(baseURL: origin) { "demo-alex" }
        let sam = try CommonThreadClient(baseURL: origin) { "demo-sam" }
        let alexAccount = try await alex.account()
        let samAccount = try await sam.account()
        try check(alexAccount.userId == "alex" && samAccount.userId == "sam", "verified account identities")
        let initialAlex = try await alex.collection()
        let initialSam = try await sam.collection()
        try check(initialAlex.items.isEmpty && initialSam.items.isEmpty, "isolated empty database")
        print("PASS real HTTP account verification for two fixture users")

        let originalNote = "I like the warm light, but need it to fit my small rented desk."
        let request = CaptureRequest(
            url: "https://example.org/native-http-lamp?utm_source=ios-smoke",
            title: "A warm desk lamp", source: .product,
            selectedText: "A compact lamp with a warm glow.", note: originalNote, client: .iosApp
        )
        let pending = PendingCapture(request: request, accountId: alexAccount.userId, baseURL: origin)
        let outbox = CaptureOutbox(directory: directory)
        try await outbox.enqueue(pending)
        let reopened = CaptureOutbox(directory: directory)
        let queued = try await reopened.pending(accountId: alexAccount.userId, baseURL: origin)
        let otherAccountQueue = try await reopened.pending(accountId: samAccount.userId, baseURL: origin)
        try check(queued.count == 1 && queued[0].key == pending.key && queued[0].request == request, "immutable capture survives reopening")
        try check(otherAccountQueue.isEmpty, "outbox isolates verified account")
        let receipt = try await alex.capture(queued[0].request, key: queued[0].key)
        try check(!receipt.id.isEmpty && !receipt.duplicate && receipt.status == "pending", "durable receipt before enrichment")
        try await reopened.remove(queued[0])
        let acknowledged = try await reopened.pending(accountId: alexAccount.userId, baseURL: origin)
        try check(acknowledged.isEmpty, "acknowledged capture removed from outbox")
        let replay = try await alex.capture(queued[0].request, key: queued[0].key)
        try check(replay.id == receipt.id && replay.status == receipt.status && replay.duplicate == receipt.duplicate, "same-key replay retains original receipt")
        print("PASS durable PendingCapture, immediate receipt, acknowledgment and same-key replay")

        let saved = try await alex.savedItem(receipt.id)
        let collection = try await alex.collection()
        try check(saved.note == originalNote && saved.title == request.title && saved.client == "ios_app", "note, title and capture client persisted")
        try check(collection.items.count == 1 && collection.items[0].id == receipt.id, "saved item appears in library")
        var duplicateRequest = request
        duplicateRequest.title = "Duplicate title must not replace the original"
        duplicateRequest.note = "Duplicate note must not replace the original"
        let duplicate = try await alex.capture(duplicateRequest, key: MutationKey())
        let retained = try await alex.savedItem(receipt.id)
        try check(duplicate.duplicate && duplicate.id == receipt.id, "duplicate returns original save")
        try check(retained.note == originalNote && retained.title == request.title, "duplicate preserves existing note and title")
        print("PASS library retrieval and duplicate capture preserves original user note")

        let hidden = try await sam.collection()
        try check(hidden.items.isEmpty, "second account cannot list first account saves")
        do {
            _ = try await sam.savedItem(receipt.id)
            throw SmokeFailure.assertion("second account unexpectedly read first account save")
        } catch let error as APIError {
            try check(error.status == 404, "cross-account lookup returns 404")
        }
        var samRequest = request
        samRequest.note = "Sam's independent save"
        let samReceipt = try await sam.capture(samRequest, key: MutationKey())
        let samSaved = try await sam.savedItem(samReceipt.id)
        try check(!samReceipt.duplicate && samReceipt.id != receipt.id && samSaved.note == samRequest.note, "same URL belongs independently to each account")
        print("PASS HTTP account isolation and independent ownership of the same URL")

        let deletion = try await alex.deleteSavedItem(receipt.id, key: MutationKey())
        let afterDeletion = try await alex.collection()
        let samAfterDeletion = try await sam.collection()
        try check(deletion.deleted && afterDeletion.items.isEmpty, "deleted save removed from library")
        try check(samAfterDeletion.items.count == 1 && samAfterDeletion.items[0].id == samReceipt.id, "deleting one user's save preserves the other")
        do {
            _ = try await alex.savedItem(receipt.id)
            throw SmokeFailure.assertion("deleted save remained readable")
        } catch let error as APIError {
            try check(error.status == 404, "deleted save returns 404")
        }
        _ = try await sam.deleteSavedItem(samReceipt.id, key: MutationKey())
        print("PASS deletion and account-scoped retention")
        print("All native Swift SDK real HTTP checks passed.")
    }
}
