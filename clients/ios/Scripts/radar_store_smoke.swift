import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "RadarSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct RadarStoreSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RadarSmoke-" + UUID().uuidString)
        let file = directory.appendingPathComponent("radar.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RadarStore(fileURL: file)
        let initial = try await store.all()
        try check(initial.isEmpty, "New Radar must not seed fake needs")
        var brief = RadarBrief()
        brief.intention = "Find a leather-strap watch"
        brief.sourceIDs = ["real-save-1", "real-save-1"]
        brief.budget = "250.50"
        brief.mustHaves = "No metal strap"
        brief.smallSpace = true
        brief.fitNotes = "Under 40 mm"
        var watch = RadarWatch(brief: brief, scope: .category, target: "Watches", conditions: "Black leather strap")
        try check(watch.frequency == .manually, "New needs must default to manual checks")
        watch = try await store.save(watch)
        let reopened = RadarStore(fileURL: file)
        let saved = try await reopened.all()
        try check(saved.count == 1 && saved[0].id == watch.id, "Saved need must persist across reopen")
        try check(saved[0].brief.sourceIDs == ["real-save-1"], "Source identities must be unique")
        try check(saved[0].brief.budget == "250.50" && saved[0].conditions == "Black leather strap", "Conditions and budget must persist")
        try check(saved[0].brief.smallSpace && saved[0].brief.fitNotes == "Under 40 mm", "Fit preferences must persist")
        watch.frequency = .weekly; watch.target = "Analog watches"
        _ = try await reopened.save(watch)
        let edited = try await store.all()
        try check(edited.count == 1 && edited[0].target == "Analog watches" && edited[0].frequency == .weekly, "Editing must replace the same need")
        try await store.setPaused(watch.id, true)
        let paused = try await reopened.all()
        try check(paused[0].isPaused, "Pause must persist")
        try await store.setPaused(watch.id, false)
        let resumed = try await reopened.all()
        try check(!resumed[0].isPaused, "Resume must persist")
        try await store.recordCheck(watch)
        let checked = try await reopened.all()
        try check(checked[0].lastCheckedAt != nil, "An actual completed search must record its check")
        let previousSearch = watch
        watch.conditions = "Brown leather strap"
        _ = try await store.save(watch)
        try await store.recordCheck(previousSearch)
        let changedSearch = try await reopened.all()
        try check(changedSearch[0].lastCheckedAt == nil, "A late result for old conditions must not mark an edited need as checked")
        var invalid = watch; invalid.target = "  "
        do { _ = try await store.save(invalid); throw NSError(domain: "RadarSmoke", code: 2) }
        catch RadarStoreError.invalidTarget {}
        invalid = watch; invalid.target = "? 🟣"
        do { _ = try await store.save(invalid); throw NSError(domain: "RadarSmoke", code: 5) }
        catch RadarStoreError.invalidTarget {}
        invalid = watch; invalid.brief.budget = "-20"
        do { _ = try await store.save(invalid); throw NSError(domain: "RadarSmoke", code: 3) }
        catch RadarStoreError.invalidBudget {}
        let afterInvalid = try await store.all()
        try check(afterInvalid.count == 1 && afterInvalid[0].target == "Analog watches", "Invalid edits must not corrupt stored needs")
        try await store.remove(watch.id)
        try await store.recordCheck(watch)
        let removed = try await reopened.all()
        try check(removed.isEmpty, "Removal must persist")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: file)
        do { _ = try await store.save(watch); throw NSError(domain: "RadarSmoke", code: 4) }
        catch RadarStoreError.unreadable {}
        let preserved = try Data(contentsOf: file)
        try check(preserved == corrupt, "Unreadable storage must never be overwritten")
        print("Radar store smoke passed: empty state, persistence, source deduplication, constraints, edit, pause/resume, validation, removal, corruption protection")
    }
}
