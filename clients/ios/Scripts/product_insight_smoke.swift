import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "ProductInsightSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct ProductInsightSmoke {
    static func main() throws {
        let combined = ProductInsightSummary(
            summary: "A watch with a black leather strap. The dial has gold markers.",
            evidence: ["Title states Tudor Oyster Prince wristwatch", "A WATCH WITH A BLACK LEATHER STRAP.",
                       "The case has a polished finish.", "The case has a polished finish", "  "],
            uncertainties: ["Case width is not verified.", "case width is not verified"],
            additionalSummaries: ["A watch with a black leather strap. The dial has gold markers.",
                                  "The photo also shows a date window."])
        try check(combined.highlights == ["A watch with a black leather strap."], "The main product highlight should stay concise")
        try check(combined.details.contains("A watch with a black leather strap. The dial has gold markers."), "The full analysis must remain available")
        try check(combined.details.contains("The photo also shows a date window."), "A merged source’s distinct observation must appear")
        try check(combined.details.filter { $0.lowercased().contains("polished finish") }.count == 1, "Duplicate source evidence must appear once")
        try check(!combined.details.contains(where: { $0.hasPrefix("Title states") }), "Transcribed titles must not repeat as insights")
        try check(combined.uncertainties.count == 1, "Repeated uncertainty must deduplicate")
        let richerEvidence = "A watch with a black leather strap and a scratched bezel."
        let preserved = ProductInsightSummary(summary: "A watch with a black leather strap", evidence: [richerEvidence], uncertainties: [])
        try check(preserved.details.contains(richerEvidence), "Additional evidence must not disappear just because it contains the summary")
        let conflicting = ProductInsightSummary(summary: "The strap appears black.", evidence: [], uncertainties: ["The lighting may change its apparent color."], additionalSummaries: ["The strap appears brown."])
        try check(conflicting.details.contains("The strap appears brown."), "Conflicting source observations must remain visible, not silently resolved")
        let empty = ProductInsightSummary(summary: "", evidence: [], uncertainties: [])
        try check(empty.highlights.isEmpty && empty.details.isEmpty, "No source material must yield no invented insights")
        print("Product insight smoke passed: merged source evidence, deduplication, title suppression, full context, conflicts and empty input")
    }
}
