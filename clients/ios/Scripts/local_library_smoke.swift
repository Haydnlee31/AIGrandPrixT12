// Exercises the frontend's real disk store without a server or network requests.
import Foundation
import CommonThreadKit

private enum SmokeFailure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}

@main
struct LocalLibrarySmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mymah-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let library = LocalLibrary(fileURL: file)
        let starter = try await library.collection()
        try check(starter.count == 4 && starter.allSatisfy { $0.client == "sample" }, "starter collection is available")
        try check(FileManager.default.fileExists(atPath: file.path), "starter collection persists to disk")
        let reopened = LocalLibrary(fileURL: file)
        let persistedStarter = try await reopened.collection()
        try check(starter.map(\.id) == persistedStarter.map(\.id) && starter.map(\.capturedAt) == persistedStarter.map(\.capturedAt), "reopening retains starter items and dates")
        print("PASS starter collection persisted and retained after reopening")

        let note = "Warm light for my small rented desk; keep the original note."
        let request = CaptureRequest(url: "https://example.org/desk-lamp/?utm_source=local&a=1#detail",
                                     title: "My desk lamp", note: note, client: .iosApp)
        let receipt = try await library.capture(request)
        try check(!receipt.duplicate && receipt.status == "saved", "new save returns acknowledgment")
        let reloaded = try await LocalLibrary(fileURL: file).collection()
        try check(reloaded.count == starter.count + 1 && reloaded.first?.id == receipt.id, "new save is persisted at front of collection")
        try check(reloaded.first?.note == note && reloaded.first?.originalUrl == request.url, "original note and source link retained")

        let duplicate = try await reopened.capture(CaptureRequest(
            url: "https://EXAMPLE.ORG/desk-lamp?a=1&utm_medium=note", title: "Different title", note: "Do not overwrite"
        ))
        let afterDuplicate = try await reopened.collection()
        try check(duplicate.duplicate && duplicate.id == receipt.id, "canonical URL identifies duplicate")
        try check(afterDuplicate.count == reloaded.count && afterDuplicate.first?.note == note && afterDuplicate.first?.title == request.title, "duplicate preserves original title and note")
        print("PASS capture, reload and canonical duplicate preserve original content")

        let beforeInvalid = try Data(contentsOf: file)
        do {
            _ = try await library.capture(CaptureRequest(url: "ftp://example.org/invalid", title: "Invalid"))
            throw SmokeFailure.assertion("invalid link was accepted")
        } catch LocalLibrary.LocalError.invalidLink {}
        let afterInvalid = try Data(contentsOf: file)
        try check(beforeInvalid == afterInvalid, "invalid link leaves persisted file byte-for-byte intact")
        print("PASS invalid link rejected without changing the saved library")

        try await library.delete(receipt.id)
        let afterDelete = try await LocalLibrary(fileURL: file).collection()
        try check(afterDelete.count == starter.count && !afterDelete.contains { $0.id == receipt.id }, "deletion persists")
        for item in afterDelete { try await library.delete(item.id) }
        let emptied = try await LocalLibrary(fileURL: file).collection()
        try check(emptied.isEmpty, "empty collection stays empty after reopening")
        print("PASS deletion persists and empty library is not reseeded")
        print("All frontend local library checks passed without a backend.")
    }
}
