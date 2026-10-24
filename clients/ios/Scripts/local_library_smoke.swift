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
        try check(afterDuplicate.count == reloaded.count && afterDuplicate.first?.note == note + "\n\nDo not overwrite" && afterDuplicate.first?.title == request.title, "duplicate combines notes without replacing the original title")
        let originalSources = try await reopened.metadata()[receipt.id]?.sourceItems
        try check(originalSources?.map(\.note) == [note, "Do not overwrite"], "duplicate keeps both original source notes")
        print("PASS capture, reload and canonical duplicate retain and combine original content")

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
        let legacyVoice = try await migrated.metadata()[receipt.id]?.hasVoiceNote
        try check(legacyVoice == nil, "older notes are readable without being relabeled as voice")
        let migratedFile = try JSONSerialization.jsonObject(with: Data(contentsOf: migrationFile)) as! [String: Any]
        try check(migratedFile["version"] as? Int == 3, "migration is persisted")
        var matchingID = originalObject; matchingID["id"] = "sample-reading"
        var unrelatedSample = originalObject; unrelatedSample["id"] = "sample-user-owned"; unrelatedSample["client"] = "sample"
        let legacyFile = directory.appendingPathComponent("legacy-array.json")
        try JSONSerialization.data(withJSONObject: [matchingID, unrelatedSample]).write(to: legacyFile)
        let legacyItems = try await LocalLibrary(fileURL: legacyFile).collection()
        try check(legacyItems.count == 2, "matching ID with real client and other sample IDs are preserved")
        print("PASS bounded sample migration and backward-compatible intention decoding")

        let voiceFile = directory.appendingPathComponent("voice-library.json")
        let voiceLibrary = LocalLibrary(fileURL: voiceFile)
        let voiceSave = try await voiceLibrary.captureContent(title: "Spoken idea", text: "A desk idea",
            note: "Warm light for my desk", hasVoiceNote: true)
        let voiceReload = LocalLibrary(fileURL: voiceFile)
        let voiceMetadata = try await voiceReload.metadata()[voiceSave.id]
        let voiceItem = try await voiceReload.collection().first { $0.id == voiceSave.id }
        try check(voiceMetadata?.hasVoiceNote == true && voiceItem?.note == "Warm light for my desk", "voice provenance and transcript survive reopening together")
        try await voiceReload.update(voiceSave.id, title: "Spoken idea", note: "Edited by typing", text: "A desk idea")
        try await voiceReload.setIntents(voiceSave.id, ["A typed preference"])
        let retainedVoice = try await LocalLibrary(fileURL: voiceFile).metadata()[voiceSave.id]?.hasVoiceNote
        try check(retainedVoice == true, "ordinary edits never erase existing voice provenance")

        let typedSave = try await voiceLibrary.captureContent(title: "Typed idea", text: "A plain typed note", note: "My voice transcript")
        let typedMetadata = try await voiceReload.metadata()[typedSave.id]
        try check(typedMetadata?.hasVoiceNote == nil, "note wording never implies that voice was used")
        try await voiceReload.update(typedSave.id, title: "Typed idea", note: "New dictated note", text: "A plain typed note", hasVoiceNote: true)
        let promotedVoice = try await LocalLibrary(fileURL: voiceFile).metadata()[typedSave.id]?.hasVoiceNote
        try check(promotedVoice == true, "explicit dictation during editing persists voice provenance")

        let intentSave = try await voiceLibrary.captureContent(title: "Preference", text: "An existing typed find")
        try await voiceReload.setIntents(intentSave.id, ["A spoken preference"], hasVoiceNote: true)
        let intentMetadata = try await LocalLibrary(fileURL: voiceFile).metadata()[intentSave.id]
        try check(intentMetadata?.hasVoiceNote == true && intentMetadata?.selectedIntents == ["A spoken preference"], "spoken intention and provenance persist in the same write")
        try await voiceReload.setIntents(intentSave.id, [])
        let clearedIntentMetadata = try await LocalLibrary(fileURL: voiceFile).metadata()[intentSave.id]
        try check(clearedIntentMetadata?.hasVoiceNote == true && clearedIntentMetadata?.selectedIntents == [], "clearing intentions retains voice provenance")
        let untaggedSave = try await voiceLibrary.captureContent(title: "Untouched", text: "Keep this typed")
        let beforeInvalidVoice = try Data(contentsOf: voiceFile)
        do {
            try await voiceReload.update(untaggedSave.id, title: "", note: "", text: "", hasVoiceNote: true)
            throw SmokeFailure.assertion("invalid voice edit accepted")
        } catch LocalLibrary.LocalError.invalidContent {}
        do {
            try await voiceReload.setIntents(untaggedSave.id, [String(repeating: "x", count: 501)], hasVoiceNote: true)
            throw SmokeFailure.assertion("invalid voice intention accepted")
        } catch LocalLibrary.LocalError.invalidIntents {}
        let afterInvalidVoice = try Data(contentsOf: voiceFile)
        try check(beforeInvalidVoice == afterInvalidVoice, "failed voice edits cannot partially tag a typed find")
        func audioAttachment(_ filename: String, _ type: String) -> LocalAttachment {
            LocalAttachment(id: UUID(), filename: filename, typeIdentifier: type, relativePath: "Attachments/fixture", byteCount: 1)
        }
        try check(audioAttachment("recording", "public.mp3").isAudio, "audio UTI is recognized without extension")
        try check(audioAttachment("recording", "audio/mp4").isAudio, "audio MIME is recognized without extension")
        try check(audioAttachment("Recording.M4A", "public.data").isAudio && audioAttachment("recording.opus", "public.data").isAudio, "generic imported audio recognizes uppercase and additional audio extensions")
        try check(!audioAttachment("movie.mp4", "public.mpeg-4").isAudio && !audioAttachment("photo.png", "public.png").isAudio && !audioAttachment("note.txt", "public.plain-text").isAudio, "video photo and plain text are not audio")
        print("PASS voice provenance capture/edit/intention persistence, legacy decoding, atomic validation and audio format classification")

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
        protectedObject["originalUrl"] = "https://example.org/protected-photo"
        protectedObject["canonicalUrl"] = "https://example.org/protected-photo"
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
        try check(migratedTitles.first(where: { $0.id == "old-photo" })?.title == "Digital watch" && migratedTitles.first(where: { $0.id == "protected-photo" })?.title == "IMG_2716.jpg", "existing analyzed filenames migrate while manual titles are protected")
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
        try await checkExactGrouping(directory: directory, png: png)
        if CommandLine.arguments.count > 1 {
            try await checkSnapshot(URL(fileURLWithPath: CommandLine.arguments[1]), directory: directory)
        }
        print("All frontend local library checks passed without a backend.")
    }

    private static func checkSnapshot(_ source: URL, directory: URL) async throws {
        let original = try Data(contentsOf: source)
        let copy = directory.appendingPathComponent("snapshot/library.json")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: copy)
        let store = LocalLibrary(fileURL: copy)
        let items = try await store.collection()
        let metadata = try await store.metadata()
        let raw = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        let sources = raw["items"] as! [[String: Any]]
        let observedIDs = Set(items.flatMap { metadata[$0.id]?.sourceItems?.map(\.id) ?? [$0.id] })
        let sourceIDs = Set(sources.compactMap { $0["id"] as? String })
        try check(observedIDs == sourceIDs, "snapshot grouped view represents every original source")
        let copiedAfterReads = try Data(contentsOf: copy)
        let sourceAfterReads = try Data(contentsOf: source)
        try check(copiedAfterReads == original, "reading snapshot groups preserves original JSON byte-for-byte")
        try check(sourceAfterReads == original, "snapshot source is never modified")
        for id in sourceIDs {
            let resolved = try await store.item(id)
            try check(resolved != nil && metadata[id] != nil, "every original snapshot ID resolves")
        }
        print("PASS isolated device snapshot: \(sources.count) originals → \(items.count) groups; source rows, metadata and input file unchanged")
    }

    private static func checkExactGrouping(directory: URL, png: Data) async throws {
        let file = directory.appendingPathComponent("grouping/library.json")
        let library = LocalLibrary(fileURL: file)
        func analysis(_ time: Double, _ evidence: String) -> CaptureIntelligenceResult {
            CaptureIntelligenceResult(productName: "Watch", categoryPath: ["Accessories", "Watches"], brand: "Example",
                style: ["Classic"], summary: evidence, uncertainties: ["Fit unknown"], prompts: [], evidence: [evidence], analyzedAt: time, schemaVersion: 2)
        }
        let first = try await library.captureContent(url: "https://example.org/watch?variant=blue&utm_source=first", title: "My exact watch",
            text: "First description", note: "A gift for Dad", attachments: [.init(filename: "watch.png", typeIdentifier: "public.png", data: png)],
            id: "watch-first", capturedAt: Date(timeIntervalSince1970: 100), intents: ["Blue dial", "Small case"], analysis: analysis(10, "Blue dial visible"), userEditedTitle: true)
        try await library.setPinned(first.id, true); try await library.setFavorite(first.id, true); try await library.setArchived(first.id, true)
        _ = try await library.captureContent(url: "https://EXAMPLE.ORG/watch?utm_medium=share&variant=blue", title: "Watch",
            text: "Second description", note: "Check the strap", attachments: [.init(filename: "note.m4a", typeIdentifier: "public.mpeg-4-audio", data: Data([1, 2, 3]))],
            id: "watch-second", capturedAt: Date(timeIntervalSince1970: 200), intents: ["Small case", "Leather strap"], analysis: analysis(20, "Leather strap visible"), hasVoiceNote: true)
        let group = try await library.collection()
        let details = try await library.metadata()[first.id]!
        try check(group.count == 1 && group[0].id == first.id && group[0].title == "My exact watch", "exact URL grouping keeps stable ID and manual title")
        try check(group[0].note == "A gift for Dad\n\nCheck the strap" && group[0].selectedText == "First description\n\nSecond description", "distinct notes and source text combine without loss")
        try check(details.selectedIntents == ["Blue dial", "Small case", "Leather strap"] && details.attachments.count == 2, "all selected details and attachments retained")
        try check(details.pinned && details.isFavorite && !details.isArchived && details.hasVoiceNote == true, "organization flags and voice history survive grouping")
        try check(details.analysis?.analyzedAt == 20 && details.sourceAnalyses?.count == 2 && details.sourceItems?.count == 2, "latest analysis and original insight sources retained")
        let alias = try await library.item("watch-second")
        let aliasMetadata = try await library.metadata()["watch-second"]
        try check(alias?.id == first.id && aliasMetadata?.sourceItems?.count == 2, "old IDs resolve to the merged find and metadata")
        let rawBeforeEdits = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let rawSources = rawBeforeEdits["items"] as! [[String: Any]]
        let rawMetadata = rawBeforeEdits["metadata"] as! [String: Any]
        try check(rawSources.count == 2, "grouping does not remove original records")

        try await library.setPinned("watch-second", false); try await library.setFavorite("watch-second", false)
        try await library.setArchived("watch-second", true)
        let archived = try await library.metadata()[first.id]!
        try check(!archived.pinned && !archived.isFavorite && archived.isArchived, "group overrides can clear member pins and favorites and archive every source")
        try await library.setArchived(first.id, false); try await library.setIntents("watch-second", [])
        try await library.update("watch-second", title: "Dad’s birthday watch", note: "Final gift shortlist", text: "Combined description")
        let edited = try await LocalLibrary(fileURL: file).item(first.id)!
        let editedDetails = try await LocalLibrary(fileURL: file).metadata()[first.id]!
        try check(edited.note == "Final gift shortlist" && edited.title == "Dad’s birthday watch" && editedDetails.selectedIntents.isEmpty && !editedDetails.isArchived, "combined edits persist without old selections reappearing")
        try check(editedDetails.analysis == nil && editedDetails.sourceAnalyses?.count == 2, "source edit invalidates current analysis but retains original insight evidence")
        let rawAfterEdits = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let options: JSONSerialization.WritingOptions = [.sortedKeys]
        let retainedRows = try JSONSerialization.data(withJSONObject: rawSources, options: options) == JSONSerialization.data(withJSONObject: rawAfterEdits["items"]!, options: options)
        let retainedMetadata = try JSONSerialization.data(withJSONObject: rawMetadata, options: options) == JSONSerialization.data(withJSONObject: rawAfterEdits["metadata"]!, options: options)
        try check(retainedRows, "group edits preserve every original row byte-for-byte logically")
        try check(retainedMetadata, "group edits preserve original metadata")

        _ = try await library.captureContent(url: "https://example.org/watch?variant=blue", title: "Third save", note: "Remember his wrist size",
            id: "watch-third", capturedAt: Date(timeIntervalSince1970: 300), intents: ["Measure fit"])
        let appended = try await library.item("watch-third")!
        let appendedDetails = try await library.metadata()[first.id]!
        try check(appended.note == "Final gift shortlist\n\nRemember his wrist size" && appendedDetails.selectedIntents == ["Measure fit"], "later source adds context without restoring explicitly removed details")
        let beforeReplay = try Data(contentsOf: file)
        let replay = try await library.captureContent(url: "https://example.org/watch?variant=blue", title: "Old payload", note: "Old payload", id: "watch-third")
        let afterReplay = try Data(contentsOf: file)
        try check(replay.id == first.id && replay.duplicate && beforeReplay == afterReplay, "replayed share alias stays idempotent after grouping and edits")
        try await library.setAnalysis(first.id, analysis(30, "New complete analysis"))
        let refreshed = try await library.metadata()[first.id]!
        try check(refreshed.analysis?.analyzedAt == 30 && refreshed.sourceAnalyses?.count == 3, "new combined analysis retains individual sources")
        _ = try await library.captureContent(url: "https://example.org/watch?variant=red", title: "Watch", id: "watch-red")
        _ = try await library.captureContent(url: "https://another.example/watch?variant=blue", title: "My exact watch", id: "watch-other")
        let variants = try await library.collection()
        try check(variants.count == 3, "different variants and domains never merge by title or brand")

        let photosFile = directory.appendingPathComponent("photos/library.json")
        let photos = LocalLibrary(fileURL: photosFile)
        let photo = LocalCaptureAttachment(filename: "a.png", typeIdentifier: "public.png", data: png)
        _ = try await photos.captureContent(title: "Photo A", note: "Original photo note", attachments: [photo], id: "photo-a", capturedAt: Date(timeIntervalSince1970: 10))
        let secondPhoto = try await photos.captureContent(title: "Photo B", note: "Another reason", attachments: [photo], id: "photo-b", capturedAt: Date(timeIntervalSince1970: 20))
        let mergedPhotos = try await photos.collection()
        try check(mergedPhotos.count == 1 && secondPhoto.id == "photo-a" && mergedPhotos[0].note.contains("Another reason"), "identical photo bytes combine notes")
        var differentBytes = png; differentBytes.append(1)
        let otherPhoto = LocalCaptureAttachment(filename: "a.png", typeIdentifier: "public.png", data: differentBytes)
        _ = try await photos.captureContent(title: "Photo A", attachments: [otherPhoto], id: "photo-c")
        _ = try await photos.captureContent(title: "Photo set", attachments: [photo, otherPhoto], id: "photo-set")
        let separatePhotos = try await photos.collection()
        try check(separatePhotos.count == 3, "different image bytes or complete photo sets remain distinct")
        let sourceBytes = try await photos.metadata()["photo-a"]!.attachments
        try await photos.delete("photo-b")
        let removed = try await photos.item("photo-a")
        try check(removed == nil, "explicit group deletion resolves aliases and deletes that group")
        for attachment in sourceBytes {
            let location = await photos.attachmentURL(attachment)
            try check(!FileManager.default.fileExists(atPath: location.path), "explicit group deletion cleans its original attachment files")
        }
        print("PASS exact URL/photo grouping, source preservation, aliases, overrides, later notes, replay and variant separation")
    }
}
