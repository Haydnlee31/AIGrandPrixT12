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
        try check(starter.isEmpty, "new library starts with only the user's finds")
        try check(FileManager.default.fileExists(atPath: file.path), "empty collection persists to disk")
        let reopened = LocalLibrary(fileURL: file)
        let persistedStarter = try await reopened.collection()
        try check(starter.map(\.id) == persistedStarter.map(\.id) && starter.map(\.capturedAt) == persistedStarter.map(\.capturedAt), "reopening retains starter items and dates")
        print("PASS fresh library stays empty without fabricated finds")

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

        // Version-2 migration removes only the four known starter records.
        let originalObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded[0])) as! [String: Any]
        let knownIDs = ["sample-reading", "sample-lamp", "sample-balcony", "sample-ceramics"]
        let oldExamples: [[String: Any]] = knownIDs.map { id in
            var copy = originalObject; copy["id"] = id; copy["client"] = "sample"; return copy
        }
        let migrationFile = directory.appendingPathComponent("migration.json")
        let oldMetadata: [String: Any] = ["isFavorite": false, "isArchived": false, "attachments": [], "intent": "I like the small dial"]
        try JSONSerialization.data(withJSONObject: ["version": 2, "items": oldExamples + [originalObject],
            "metadata": [receipt.id: oldMetadata]]).write(to: migrationFile)
        let migrated = LocalLibrary(fileURL: migrationFile)
        let migratedItems = try await migrated.collection()
        let migratedIntents = try await migrated.metadata()[receipt.id]?.selectedIntents
        try check(migratedItems.map(\.id) == [receipt.id] && migratedIntents == ["I like the small dial"], "known samples removed and legacy user intention survives migration")
        let legacyPin = try await migrated.metadata()[receipt.id]?.pinned
        try check(legacyPin == false, "older metadata without pin field remains readable and unpinned")
        let migratedFile = try JSONSerialization.jsonObject(with: Data(contentsOf: migrationFile)) as! [String: Any]
        try check(migratedFile["version"] as? Int == 3, "migration is persisted")
        var matchingID = originalObject; matchingID["id"] = "sample-reading"
        var unrelatedSample = originalObject; unrelatedSample["id"] = "sample-user-owned"; unrelatedSample["client"] = "sample"
        let legacyFile = directory.appendingPathComponent("legacy-array.json")
        try JSONSerialization.data(withJSONObject: [matchingID, unrelatedSample]).write(to: legacyFile)
        let legacyItems = try await LocalLibrary(fileURL: legacyFile).collection()
        try check(legacyItems.count == 2, "matching ID with real client and other sample IDs are preserved")
        print("PASS bounded sample migration and backward-compatible intention decoding")

        let beforeInvalid = try Data(contentsOf: file)
        do {
            _ = try await library.capture(CaptureRequest(url: "ftp://example.org/invalid", title: "Invalid"))
            throw SmokeFailure.assertion("invalid link was accepted")
        } catch LocalLibrary.LocalError.invalidLink {}
        let afterInvalid = try Data(contentsOf: file)
        try check(beforeInvalid == afterInvalid, "invalid link leaves persisted file byte-for-byte intact")
        print("PASS invalid link rejected without changing the saved library")

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let imageReceipt = try await library.capture(CaptureRequest(title: "A local photo", imageDataUrl: "data:image/png;base64," + png.base64EncodedString()))
        let images = try await reopened.collection()
        try check(images.first?.id == imageReceipt.id && images.first?.hasImage == true, "image-only find persists")
        let metadata = try await reopened.metadata()
        let attachment = metadata[imageReceipt.id]!.attachments[0]
        let restoredImage = try await reopened.attachmentData(attachment)
        try check(restoredImage == png, "photo bytes survive reopening")
        try await reopened.setPinned(imageReceipt.id, true)
        let pinned = try await LocalLibrary(fileURL: file).metadata()[imageReceipt.id]?.pinned
        try check(pinned == true, "pin survives reopening")
        let pinnedBytes = try Data(contentsOf: file)
        try await reopened.setPinned(imageReceipt.id, true)
        let repinnedBytes = try Data(contentsOf: file)
        try check(pinnedBytes == repinnedBytes, "unchanged pin does not rewrite or bump revision")
        try await reopened.setArchived(imageReceipt.id, true)
        let archivedPin = try await library.metadata()[imageReceipt.id]!
        try check(archivedPin.pinned && archivedPin.isArchived, "archiving retains pin metadata")
        try await reopened.setArchived(imageReceipt.id, false)
        let restoredPin = try await library.metadata()[imageReceipt.id]!
        try check(restoredPin.pinned && !restoredPin.isArchived, "unarchiving restores pinned find without recreating it")
        try await reopened.setPinned(imageReceipt.id, false)
        let unpinned = try await LocalLibrary(fileURL: file).metadata()[imageReceipt.id]?.pinned
        try check(unpinned == false, "unpin persists")
        print("PASS pin persistence, archive restoration and backward-compatible pin decoding")
        try await reopened.setFavorite(imageReceipt.id, true)
        try await reopened.setArchived(imageReceipt.id, true)
        try await reopened.update(imageReceipt.id, title: "Edited title", note: "An editable voice transcript", text: "")
        try await reopened.setIntent(imageReceipt.id, "Compare smaller versions")
        let edited = try await library.collection().first { $0.id == imageReceipt.id }
        let editedMetadata = try await library.metadata()[imageReceipt.id]!
        try check(edited?.title == "Edited title" && edited?.note == "An editable voice transcript" && editedMetadata.isFavorite && editedMetadata.isArchived && editedMetadata.intent == "Compare smaller versions", "editing and organization persist")
        let revisionBeforeIntents = edited!.revision
        try await reopened.setIntents(imageReceipt.id, ["Retro face", "Smaller case", "Retro face", "  "])
        let chosenDetails = try await LocalLibrary(fileURL: file).metadata()[imageReceipt.id]?.selectedIntents
        let revisionAfterIntents = try await library.collection().first { $0.id == imageReceipt.id }!.revision
        try check(chosenDetails == ["Retro face", "Smaller case"] && revisionAfterIntents > revisionBeforeIntents, "multiple intentions deduplicate, persist and change revision")
        let beforeInvalidIntents = try Data(contentsOf: file)
        for invalid in [Array(repeating: "x", count: 9).enumerated().map { "\($0.offset)\($0.element)" }, [String(repeating: "x", count: 501)]] {
            do { try await library.setIntents(imageReceipt.id, invalid); throw SmokeFailure.assertion("invalid intentions accepted") }
            catch LocalLibrary.LocalError.invalidIntents {}
        }
        let afterInvalidIntents = try Data(contentsOf: file)
        try check(afterInvalidIntents == beforeInvalidIntents, "invalid intentions never alter the store")
        try await reopened.setIntents(imageReceipt.id, [])
        let clearedDetails = try await library.metadata()[imageReceipt.id]?.selectedIntents
        try check(clearedDetails == [], "clearing intentions does not restore the legacy value")
        let analysis = CaptureIntelligenceResult(productName: "Digital watch", categoryPath: ["Accessories", "Watches", "Digital"], brand: nil,
            style: ["Vintage-inspired"], summary: "Test analysis fixture", uncertainties: ["Brand is unknown"],
            prompts: [.init(id: "p1", text: "I like the retro face", question: "What draws you to this face?")], evidence: ["Rectangular digital face"], analyzedAt: 1234, schemaVersion: 2)
        try await reopened.setAnalysis(imageReceipt.id, analysis)
        let analyzed = try await LocalLibrary(fileURL: file).metadata()[imageReceipt.id]?.analysis
        try check(analyzed?.categoryPath == analysis.categoryPath && analyzed?.brand == nil && analyzed?.prompts.first?.question == "What draws you to this face?" && analyzed?.schemaVersion == 2, "structured analysis, schema version and predictive question survive reopening")
        let generatedReceipt = try await library.captureContent(title: "A new find", text: "Watch description", analysis: analysis, userEditedTitle: false)
        let correctedAnalysis = CaptureIntelligenceResult(productName: "Solar digital watch", categoryPath: analysis.categoryPath,
            brand: nil, style: analysis.style, summary: analysis.summary, uncertainties: [],
            prompts: [.init(id: "no-question", text: "I like the face")], evidence: analysis.evidence, analyzedAt: 1235, schemaVersion: 2)
        try await library.setAnalysis(generatedReceipt.id, correctedAnalysis)
        let correctedTitle = try await library.collection().first { $0.id == generatedReceipt.id }?.title
        let currentVersion = try await library.metadata()[generatedReceipt.id]?.analysis
        try check(correctedTitle == "Solar digital watch", "known autogenerated title follows corrected product analysis")
        try check(currentVersion?.schemaVersion == 2 && currentVersion?.prompts.first?.question == nil, "schema version distinguishes valid current analysis with no question")
        try await library.delete(generatedReceipt.id)
        let stillCustom = try await library.collection().first { $0.id == imageReceipt.id }?.title
        try check(stillCustom == "Edited title", "analysis preserves explicitly edited titles")
        let oldPrompt = try JSONDecoder().decode(CaptureIntelligenceResult.Prompt.self, from: Data("{\"id\":\"old\",\"text\":\"An older prompt\"}".utf8))
        try check(oldPrompt.question == nil, "old prompt decodes without question")
        let analysisObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis))
        var oldPhotoObject = originalObject; oldPhotoObject["id"] = "old-photo"; oldPhotoObject["title"] = "IMG_2715.jpg"
        var protectedObject = originalObject; protectedObject["id"] = "protected-photo"; protectedObject["title"] = "IMG_2716.jpg"
        var oldPhotoMetadata = oldMetadata; oldPhotoMetadata["analysis"] = analysisObject
        var protectedMetadata = oldPhotoMetadata; protectedMetadata["userEditedTitle"] = true
        let titleMigrationFile = directory.appendingPathComponent("title-migration.json")
        try JSONSerialization.data(withJSONObject: ["version": 2, "items": [oldPhotoObject, protectedObject],
            "metadata": ["old-photo": oldPhotoMetadata, "protected-photo": protectedMetadata]]).write(to: titleMigrationFile)
        let titleMigrationLibrary = LocalLibrary(fileURL: titleMigrationFile)
        let migratedTitles = try await titleMigrationLibrary.collection()
        let firstMigrationBytes = try Data(contentsOf: titleMigrationFile)
        _ = try await titleMigrationLibrary.collection()
        let repeatedMigrationBytes = try Data(contentsOf: titleMigrationFile)
        try check(migratedTitles[0].title == "Digital watch" && migratedTitles[1].title == "IMG_2716.jpg", "existing analyzed filenames migrate while manual titles are protected")
        try check(firstMigrationBytes == repeatedMigrationBytes, "title migration does not create revision or persistence loops")
        let shareDraft = LocalShareDraft(title: "A new find", url: "https://example.org/watch", text: "A watch", note: "My note", attachments: [],
            intents: ["Retro face", "Smaller case"], analysis: analysis, userEditedTitle: false)
        let restoredDraft = try JSONDecoder().decode(LocalShareDraft.self, from: JSONEncoder().encode(shareDraft))
        try check(restoredDraft.intents?.count == 2 && restoredDraft.analysis?.prompts.first?.question == "What draws you to this face?", "share payload roundtrip preserves chosen details and AI questions")
        var oldDraftObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shareDraft)) as! [String: Any]
        oldDraftObject.removeValue(forKey: "intents"); oldDraftObject.removeValue(forKey: "analysis"); oldDraftObject.removeValue(forKey: "userEditedTitle")
        let oldDraft = try JSONDecoder().decode(LocalShareDraft.self, from: JSONSerialization.data(withJSONObject: oldDraftObject))
        try check(oldDraft.intents == nil && oldDraft.analysis == nil && oldDraft.note == "My note", "older queued share drafts remain readable")
        let namedReceipt = try await library.captureContent(url: "https://example.net/watch", title: "example.net")
        try await library.setAnalysis(namedReceipt.id, analysis)
        let renamed = try await library.collection().first { $0.id == namedReceipt.id }
        try check(renamed?.title == "Digital watch", "generic hostname becomes product title")
        try await library.update(namedReceipt.id, title: "my-own-name.png", note: "My own title", text: "")
        try await library.setAnalysis(namedReceipt.id, analysis)
        let titleProtected = try await library.collection().first { $0.id == namedReceipt.id }
        try check(titleProtected?.title == "my-own-name.png", "user-chosen filename-like title stays intact")
        let analyzedShareID = UUID().uuidString
        _ = try await library.captureContent(title: "A photo worth saving", text: "A saved watch", id: analyzedShareID,
            deduplicateLink: false, intents: ["Retro face", "Smaller case"], analysis: analysis)
        let imported = try await LocalLibrary(fileURL: file).metadata()[analyzedShareID]
        let importedTitle = try await library.collection().first { $0.id == analyzedShareID }?.title
        try check(imported?.selectedIntents == ["Retro face", "Smaller case"] && imported?.analysis?.productName == "Digital watch" && importedTitle == "Digital watch", "shared content and AI context are durable in the same write")
        try await library.setIntents(analyzedShareID, ["My newer choice"])
        _ = try await library.captureContent(title: "Old title", text: "Old text", id: analyzedShareID,
            deduplicateLink: false, intents: ["Retro face"], analysis: analysis)
        let replayed = try await library.metadata()[analyzedShareID]?.selectedIntents
        try check(replayed == ["My newer choice"], "share replay never overwrites later preference edits")
        try await library.delete(namedReceipt.id); try await library.delete(analyzedShareID)
        print("PASS multi-intent persistence, generated titles, custom title protection and atomic share replay")
        try await library.update(imageReceipt.id, title: "A different find", note: "", text: "Changed context")
        let invalidated = try await reopened.metadata()[imageReceipt.id]?.analysis
        try check(invalidated == nil, "editing source context invalidates stale analysis")
        let mediaURL = await library.attachmentURL(attachment)
        try await library.delete(imageReceipt.id)
        try check(!FileManager.default.fileExists(atPath: mediaURL.path), "deleting a find cleans its private files")
        let noteReceipt = try await library.captureContent(title: "Just an idea", text: "Warm lighting without drilling")
        let documentReceipt = try await library.captureContent(title: "Files", attachments: [LocalCaptureAttachment(filename: "idea.txt", typeIdentifier: "public.plain-text", data: Data("small space".utf8))])
        let fixedID = UUID().uuidString
        _ = try await library.captureContent(title: "Imported share", text: "shared", id: fixedID, deduplicateLink: false)
        let repeatImport = try await library.captureContent(title: "Imported share", text: "shared", id: fixedID, deduplicateLink: false)
        try check(repeatImport.duplicate, "shared inbox replay is idempotent")
        for id in [noteReceipt.id, documentReceipt.id, fixedID] { try await library.delete(id) }
        let beforeMediaError = try Data(contentsOf: file)
        do {
            _ = try await library.capture(CaptureRequest(title: "Invalid image", imageDataUrl: "data:image/png;base64,aW1hZ2U="))
            throw SmokeFailure.assertion("invalid image accepted")
        } catch LocalLibrary.LocalError.invalidMedia {}
        let afterMediaError = try Data(contentsOf: file)
        try check(beforeMediaError == afterMediaError, "failed media validation is atomic")
        print("PASS image/file/text capture, persistent edits, favorites/archive, replay and attachment cleanup")

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
