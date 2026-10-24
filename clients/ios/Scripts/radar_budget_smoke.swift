import Foundation

@main struct RadarBudgetSmoke {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "RadarBudgetSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func brief(_ intention: String, budget: String = "") -> RadarBrief {
            var brief = RadarBrief(); brief.intention = intention; brief.budget = budget; return brief
        }
        let lamp = RadarBudgetScale.steps(for: brief("A warm reading lamp"))
        let phone = RadarBudgetScale.steps(for: brief("iPhone 17 Pro"))
        let watch = RadarBudgetScale.steps(for: brief("silver retro wristwatch"))
        let luxury = RadarBudgetScale.steps(for: brief("a Tudor watch"))
        let strap = RadarBudgetScale.steps(for: brief("a Tudor watch strap"))
        try check(lamp.last! < phone.last! && watch.last! < luxury.last!, "Scales must follow the current product")
        try check(strap.last! < watch.last!, "Watch accessories must not inherit the parent luxury range")
        try check(RadarBudgetScale.steps(for: brief("iPhone case")).last! < phone.last!, "Phone case uses the accessory range")
        var changed = brief("a reading lamp"); changed.product = "iPhone 17 Pro"; changed.category = "Phones"
        try check(RadarBudgetScale.steps(for: changed) == lamp, "Edited intention overrides previous product context")
        try check(RadarBudgetScale.steps(for: changed, target: "iPhone 17 Pro") == phone, "Edited tracking target defines its own scale")
        try check(RadarBudgetScale.steps(for: brief("warm reading lamp", budget: "12000")).last == 12000, "Existing large choices must not reset")
        let precise = RadarBudgetScale.steps(for: brief("lamp", budget: "49.95"))
        try check(precise.contains(49.95) && precise == precise.sorted(), "Existing decimal choices retain precision")
        try check(RadarBudgetScale.storedValue(49.95) == "49.95", "Slider should not truncate decimal budgets")
        try check(RadarBudgetScale.label(amount: 2500, currency: "SGD") == "S$2,500", "Budget endpoints show currency and readable grouping")
        try check(RadarBudgetScale.storedValue(0).isEmpty, "Any budget remains unbounded")
        for values in [lamp, phone, watch, luxury, strap, precise] {
            try check(values.first == 0 && values == values.sorted() && Set(values).count == values.count, "Slider ranges stay ordered and unique")
        }
        print("Radar budget smoke passed: product scales, accessory precedence, edited targets, retained budgets and decimal precision")
    }
}
