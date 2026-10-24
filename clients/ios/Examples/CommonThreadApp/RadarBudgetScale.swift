import Foundation

/// Product-aware control ranges, not quoted prices or catalog price estimates.
/// An explicitly chosen budget is always retained when the intention changes.
enum RadarBudgetScale {
    static func steps(for brief: RadarBrief, target: String? = nil) -> [Double] {
        let current = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (current?.isEmpty == false ? current! : brief.intention).lowercased()
        let fallback = [brief.product, brief.category, brief.brand].joined(separator: " ").lowercased()
        let base = range(for: text) ?? range(for: fallback) ?? standard
        guard let selected = Double(brief.budget), selected.isFinite, selected > 0 else { return base }
        // Keep decimals and old out-of-range choices exactly, with no silent
        // rounding or reset when a new product changes the suggested scale.
        return Array(Set(base + [selected])).sorted()
    }

    static func label(amount: Double, currency: String) -> String {
        guard amount > 0 else { return "Any budget" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_SG")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSNumber(value: amount)) ?? String(amount)
        let prefix = ["SGD": "S$", "USD": "US$", "GBP": "£", "EUR": "€"][currency] ?? currency + " "
        return prefix + number
    }

    static func storedValue(_ amount: Double) -> String {
        amount == 0 ? "" : NSDecimalNumber(value: amount).stringValue
    }

    private static let small: [Double] = [0, 5, 10, 15, 20, 25, 35, 50, 75, 100, 150, 200]
    private static let lighting: [Double] = [0, 10, 20, 30, 40, 50, 75, 100, 150, 200, 300, 500]
    private static let wearable: [Double] = [0, 25, 50, 75, 100, 150, 200, 300, 500, 750, 1000]
    private static let tech: [Double] = [0, 100, 200, 300, 500, 750, 1000, 1250, 1500, 2000, 2500, 3000]
    private static let large: [Double] = [0, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000]
    private static let luxury: [Double] = [0, 250, 500, 1000, 1500, 2000, 3000, 5000, 7500, 10000, 15000, 25000]
    private static let standard: [Double] = [0, 25, 50, 75, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000]

    private static func range(for text: String) -> [Double]? {
        func contains(_ pattern: String) -> Bool {
            text.range(of: "\\b(?:" + pattern + ")\\b", options: .regularExpression) != nil
        }
        // Match accessories before their parent devices: an iPhone case should
        // not use the iPhone range, nor a watch strap the luxury-watch range.
        if contains("(?:phone|iphone|ipad|tablet|laptop|airpods?|watch|rolex|tudor) (?:case|cover|strap|band|sleeve)s?|screen protectors?|(?:charging|usb) cables?|watch straps?|watch bands?|coasters?|mugs?|notebooks?|stationery|pens?|socks?|keychains?|cushions?|pillowcases?|candles?|organizers?|organisers?|coffee filters?|coffee beans?") { return small }
        if contains("(?:luxury|premium|designer) (?:watches|watch)|rolex|tudor|omega|cartier|breitling|patek|audemars") { return luxury }
        if contains("lamps?|lighting|light bulbs?|nightlights?|desk lights?|reading lights?") { return lighting }
        if contains("smartphones?|iphones?|phones?|mobile phones?|cell phones?|laptops?|macbooks?|ipads?|tablets?|cameras?|televisions?|tvs?|projectors?|espresso machines?|coffee machines?") { return tech }
        if contains("sofas?|couches?|mattresses?|bed frames?|wardrobes?|dining tables?|refrigerators?|fridges?|washing machines?") { return large }
        if contains("watches|watch|wristwatches|wristwatch|smartwatches|smartwatch|headphones?|earphones?|earbuds?|airpods?|shoes?|sneakers?|jackets?|bags?|backpacks?|coffee grinders?|desks?|chairs?") { return wearable }
        return nil
    }
}
