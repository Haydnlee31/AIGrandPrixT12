import Foundation

/// Combines stored observations without inventing new product claims. Original
/// analyses remain in local storage; the view only removes repeated wording.
struct ProductInsightSummary: Sendable {
    let highlights: [String]
    let details: [String]
    let uncertainties: [String]

    init(summary: String, evidence: [String], uncertainties: [String], additionalSummaries: [String] = []) {
        let summaries = Self.unique([summary] + additionalSummaries)
        let leading = summaries.first ?? ""
        let headline = Self.firstSentence(leading)
        let observations = Self.unique(evidence).filter { text in
            !Self.isTitleOrCaptionEcho(text) && !summaries.contains { Self.isContained(text, in: $0) }
        }
        highlights = headline.isEmpty ? Array(observations.prefix(2)) : [headline]
        // Full source summaries and unique supporting evidence are available inline.
        details = Self.unique((leading != headline && !leading.isEmpty ? [leading] : [])
            + Array(summaries.dropFirst()) + Array(observations.dropFirst(headline.isEmpty ? 2 : 0)))
        self.uncertainties = Self.unique(uncertainties)
    }

    static func firstSentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { value, _, _, stop in
            sentence = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        return sentence ?? text
    }

    static func unique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !result.contains(where: { normalized(text) == normalized($0) }) else { return }
            result.append(text)
        }
    }

    private static func isContained(_ first: String, in second: String) -> Bool {
        let first = normalized(first), second = normalized(second)
        return first == second || (first.count > 28 && second.contains(first))
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func isTitleOrCaptionEcho(_ text: String) -> Bool {
        normalized(text).range(of: "^(?:(?:the|saved|source|page|product|post|image|link) )*(?:title|caption)\\b", options: .regularExpression) != nil
    }
}
