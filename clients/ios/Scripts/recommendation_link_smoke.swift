import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "RecommendationLinkSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct RecommendationLinkSmoke {
    static func main() throws {
        func item(_ link: String?) throws -> LocalRecommendation {
            var data: [String: Any] = ["id": "fixture", "title": "Watch", "source_name": "Amazon Berkeley Objects",
                "source_record_id": "B012345678", "source_url": "https://amazon.com", "reasons": []]
            if let link { data["product_url"] = link }
            return try JSONDecoder().decode(LocalRecommendation.self, from: JSONSerialization.data(withJSONObject: data))
        }
        for domain in ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazon.it",
                       "amazon.es", "amazon.co.jp", "amazon.in", "amazon.sg", "amazon.com.au"] {
            let result = try item("https://www.\(domain)/dp/B012345678?tag=ignored")
            try check(result.exactAmazonURL?.absoluteString == "https://\(domain)/dp/B012345678",
                      "A catalog listing must retain its original Amazon marketplace and ASIN")
        }
        let alternative = try item("https://amazon.sg/gp/product/B012345678")
        try check(alternative.exactAmazonURL?.absoluteString == "https://amazon.sg/dp/B012345678",
                  "An exact product path may canonicalize to the same ASIN")
        for link in ["https://amazon.com/s?k=watch", "https://amazon.com.evil.invalid/dp/B012345678",
                     "https://shop.amazon.com/dp/B012345678", "https://amazon.com@evil.invalid/dp/B012345678",
                     "https://user@amazon.com/dp/B012345678", "https://amazon.com:444/dp/B012345678",
                     "http://amazon.com/dp/B012345678", "https://amazon.com/dp/invalid",
                     "https://amazon.com/dp/B012345678/redirect"] {
            let result = try item(link)
            try check(result.exactAmazonURL == nil, "A search, malformed link or unrelated host must never become a listing CTA")
        }
        let missing = try item(nil)
        try check(missing.exactAmazonURL == nil, "Older catalog responses must decode without inventing an exact link")
        print("Recommendation links passed: original marketplaces, exact ASINs, canonical paths, missing links and unsafe/search URL rejection")
    }
}
