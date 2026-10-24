import Foundation

struct LivePriceSnapshot: Decodable {
    let status: String
    let productUrl: String?
    let asin: String?
    let marketplace: String?
    let priceMinor: Int?
    let currency: String?
    let referencePriceMinor: Int?
    let referenceLabel: String?
    let discountPercent: Int?
    let checkedAt: Double
    let basis: String
    let message: String
    var isAvailable: Bool { status == "available" && (priceMinor ?? 0) > 0 && currency != nil && basis == "item_excluding_shipping" }
}

struct TrackedPrice: Decodable, Identifiable {
    struct Observation: Decodable, Identifiable {
        let priceMinor: Int
        let currency: String
        let basis: String
        let checkedAt: Double
        var id: String { "\(checkedAt):\(currency):\(priceMinor)" }
    }
    let id: String
    let productUrl: String
    let title: String
    let targetMinor: Int?
    let currency: String?
    let lastResult: LivePriceSnapshot?
    let history: [Observation]
    let priceDropMinor: Int?
    let targetReached: Bool?
    let lastCheckedAt: Double?
    let lastSuccessAt: Double?
}

enum PriceMoney {
    static func targetStep(for priceMinor: Int) -> Double {
        let raw = max(1, Double(priceMinor) / 100)
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let factor = [1.0, 2.0, 5.0, 10.0].first { $0 >= normalized } ?? 10
        return max(1, factor * magnitude)
    }
    static func exactURL(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased() else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let markets: Set<String> = ["amazon.com", "amazon.sg", "amazon.co.uk", "amazon.ca", "amazon.com.au", "amazon.de", "amazon.fr",
            "amazon.it", "amazon.es", "amazon.co.jp", "amazon.in", "amazon.nl", "amazon.se", "amazon.pl", "amazon.com.be",
            "amazon.com.mx", "amazon.com.br", "amazon.ae", "amazon.sa", "amazon.com.tr", "amazon.eg"]
        guard markets.contains(domain), let range = parts.path.range(of: "/(?:dp|gp/product)/([A-Z0-9]{10})(?:/|$)", options: .regularExpression) else { return nil }
        let path = String(parts.path[range]).split(separator: "/")
        guard let asin = path.last, asin.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.\(domain)/dp/\(asin)")
    }
    static func divisor(_ currency: String) -> Double {
        ["JPY", "KRW"].contains(currency) ? 1 : (["KWD", "BHD", "OMR"].contains(currency) ? 1000 : 100)
    }
    static func label(_ minor: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_SG")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = divisor(currency) == 1 ? 0 : 2
        formatter.maximumFractionDigits = divisor(currency) == 1000 ? 3 : formatter.minimumFractionDigits
        return formatter.string(from: NSNumber(value: Double(minor) / divisor(currency))) ?? "\(currency) \(Double(minor) / divisor(currency))"
    }
    static func sameListing(_ first: String, _ second: String) -> Bool {
        guard let one = exactURL(first), let two = exactURL(second) else { return false }
        return one == two
    }
}
