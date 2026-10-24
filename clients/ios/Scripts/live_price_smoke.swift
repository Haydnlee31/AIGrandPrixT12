import Foundation

@main struct LivePriceSmoke {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "LivePriceSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"{"status":"available","product_url":"https://www.amazon.in/dp/B07FCLBWD9","asin":"B07FCLBWD9","marketplace":"amazon.in","price_minor":630000,"currency":"INR","reference_price_minor":1650000,"reference_label":"MRP","discount_percent":61,"checked_at":1792874952.0,"basis":"item_excluding_shipping","message":"Verified product price"}"#.utf8)
        let value = try decoder.decode(LivePriceSnapshot.self, from: data)
        try check(value.isAvailable && value.priceMinor == 630000 && value.referenceLabel == "MRP", "Live endpoint contract must decode without changing money or its basis")
        var unavailable = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        unavailable["status"] = "unavailable"; unavailable["price_minor"] = NSNull()
        let missing = try decoder.decode(LivePriceSnapshot.self, from: JSONSerialization.data(withJSONObject: unavailable))
        try check(!missing.isAvailable, "Failed checks must not display a price as available")
        let item: [String: Any] = ["id": "watch", "product_url": value.productUrl!, "title": "Watch", "target_minor": 640000, "currency": "INR",
            "last_result": try JSONSerialization.jsonObject(with: data), "history": [["price_minor": 630000, "currency": "INR", "basis": "item_excluding_shipping", "checked_at": 1792874952.0]],
            "price_drop_minor": NSNull(), "target_reached": true, "last_checked_at": 1792874952.0, "last_success_at": 1792874952.0]
        let watch = try decoder.decode(TrackedPrice.self, from: JSONSerialization.data(withJSONObject: item))
        try check(watch.targetReached == true && watch.history.count == 1 && watch.priceDropMinor == nil, "Tracking must preserve real history and nullable drop signals")
        try check(PriceMoney.label(12345, currency: "JPY").contains("12,345"), "JPY must not be divided by 100")
        try check(PriceMoney.label(630000, currency: "INR").contains("6,300"), "INR uses integer paise")
        try check(PriceMoney.targetStep(for: 630000) == 10000, "A 6300 rupee watch uses clean 100 rupee target steps")
        try check(PriceMoney.targetStep(for: 1995) == 20, "Small dollar purchases still permit useful sub-dollar targets")
        try check(PriceMoney.sameListing("https://amazon.in/Product/dp/B07FCLBWD9?tag=test", "https://www.amazon.in/dp/B07FCLBWD9"), "Exact links preserve ASIN and marketplace")
        for unsafe in ["https://amazon.in.evil.example/dp/B07FCLBWD9", "https://www.www.amazon.in/dp/B07FCLBWD9", "http://amazon.in/dp/B07FCLBWD9", "https://amazon.in/s/B07FCLBWD9", "https://user@amazon.in/dp/B07FCLBWD9", "https://amazon.in:8443/dp/B07FCLBWD9"] {
            try check(PriceMoney.exactURL(unsafe) == nil, "Unsafe or nonproduct URLs cannot become a price-check target")
        }
        try check(!PriceMoney.sameListing("https://amazon.in/dp/B07FCLBWD9", "https://amazon.com/dp/B07FCLBWD9"), "Different marketplaces cannot silently share prices")
        print("Live price model smoke passed: endpoint decoding, history, unavailable states, currency precision and exact listing identity")
    }
}
