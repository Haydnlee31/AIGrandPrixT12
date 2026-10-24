import Foundation

struct TasteLabSession {
    enum Dimension: String { case lighting, furniture }
    enum Choice: String, CaseIterable { case a = "A", b = "B", both = "Both", neither = "Neither" }
    struct Answer { let dimension: Dimension; let choice: Choice }
    private(set) var answers: [Answer] = []
    var dimension: Dimension { answers.isEmpty ? .lighting : .furniture }
    var complete: Bool { answers.count == 2 }
    mutating func choose(_ choice: Choice) { guard !complete else { return }; answers.append(Answer(dimension: dimension, choice: choice)) }
    mutating func undo() { if !answers.isEmpty { answers.removeLast() } }
    var lighting: Choice? { answers.first { $0.dimension == .lighting }?.choice }
    var furniture: Choice? { answers.first { $0.dimension == .furniture }?.choice }
    var suggestedFocus: String {
        if lighting == .a || lighting == .b { return "Lighting" }
        if furniture == .a || furniture == .b { return "Furniture" }
        return ""
    }
    var interpretation: String {
        if lighting == .a || lighting == .b {
            let light = lighting == .a ? "warmer" : "cooler"
            if furniture == .both || furniture == .neither {
                return "You chose the \(light) light without choosing one chair. Lighting may be a better starting point than furniture. Explore that?"
            }
            return "You chose the \(light) light and a chair variation. Both may matter. Which would you like to explore first?"
        }
        if furniture == .a || furniture == .b { return "You chose one chair, but not one lighting style. Furniture may be the more useful starting point. Explore that?" }
        return "These choices don’t point to one clear preference. Choose a direction or write your own brief."
    }
    static func suitableTitle(_ title: String, for productType: String?) -> Bool {
        let value = title.lowercased()
        let excluded = ["kids", "youth", "children", "renewed", "outdoor", "patio", "dining", "office", "gaming", "sectional"]
        guard !excluded.contains(where: value.contains) else { return false }
        if productType == "chair" { return ["chair", "recliner", "glider"].contains(where: value.contains) }
        return productType == "lamp" && value.contains("lamp")
    }
    static func productType(for brief: String) -> String? {
        let words = brief.lowercased().split { !$0.isLetter }
        return words.reversed().compactMap { word -> String? in
            if ["lamp", "lamps", "lighting", "light"].contains(String(word)) { return "lamp" }
            if ["chair", "chairs", "armchair", "furniture"].contains(String(word)) { return "chair" }
            return nil
        }.first
    }
    func brief(for focus: String) -> String {
        guard !focus.isEmpty else { return "" }
        if focus == "Lighting" { return lighting == .b ? "Find a reading lamp for a bright, cool-lit reading corner" : "Find a reading lamp for a softly lit, warm reading corner" }
        return furniture == .b ? "Find a wooden reading chair for a relaxing reading corner" : "Find an upholstered reading chair for a relaxing reading corner"
    }
}
