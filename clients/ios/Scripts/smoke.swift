// Standalone equivalent of the key SDK tests for CLT installations lacking a working SwiftPM/XCTest.
// Compiled alongside Sources/CommonThreadKit/*.swift; never connects to a network service.
import Foundation

private enum SmokeFailure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            let (status, data, headers) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main
struct Smoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func fixture(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name).appendingPathExtension("json")) }
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try CommonThreadClient.decoder().decode(type, from: fixture(name)) }
        let capabilities = try decode(Capabilities.self, "capabilities")
        try check(capabilities.features["image_upload"] == true, "capability flag")
        _ = try decode(Account.self, "account"); _ = try decode(CaptureReceipt.self, "capture")
        _ = try decode(SavedItem.self, "pending"); _ = try decode(SavedItem.self, "saved")
        _ = try decode(CollectionPage.self, "collection"); _ = try decode(AnnotationReceipt.self, "annotation")
        _ = try decode(ItemList<Hypothesis>.self, "hypotheses"); _ = try decode(DiscoverySession.self, "session")
        _ = try decode(DiscoverySession.self, "budget"); _ = try decode(ItemList<DiscoverySession>.self, "discoveries")
        let shortlist = try decode(DiscoverySession.self, "shortlist")
        try check(!shortlist.products.isEmpty && shortlist.preferences["budget_minor"] == .integer(10000), "shortlist and exact minor units")
        _ = try decode(Catalog.self, "catalog"); _ = try decode(PriceWatch.self, "watch")
        _ = try decode(PriceWatch.self, "watch_update"); _ = try decode(ItemList<PriceWatch>.self, "watches")
        _ = try decode(PriceWatch.self, "watch_detail"); _ = try decode(JobStatus.self, "job")
        _ = try decode(JobReceipt.self, "simulation")
        let notifications = try decode(ItemList<AppNotification>.self, "notifications")
        try check(notifications.items.count == 1, "notification fixture")
        print("PASS 20 actual API response fixtures")

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try CommonThreadClient(baseURL: URL(string: "https://api.example.org")!, session: URLSession(configuration: config)) { "test-token" }
        let imageBytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let imageDataURL = "data:image/png;base64,\(imageBytes.base64EncodedString())"
        let imageCapture = CaptureRequest(title: "Saved chair", source: .product, client: .iosShareExtension, imageDataUrl: imageDataURL)
        let imageEncoded = try CommonThreadClient.encoder().encode(imageCapture)
        let imageCaptureJSON = try JSONSerialization.jsonObject(with: imageEncoded) as! [String: Any]
        try check(imageCaptureJSON["url"] == nil && imageCaptureJSON["image_data_url"] as? String == imageDataURL, "image-only capture sends bytes without an invented URL")
        let restoredImageCapture = try CommonThreadClient.decoder().decode(CaptureRequest.self, from: imageEncoded)
        try check(restoredImageCapture == imageCapture, "image capture survives outbox encoding")
        let oldCaptureJSON = Data(#"{"url":"https://example.org/chair","title":"Chair","source":"product","selected_text":"","note":"","client":"ios_app"}"#.utf8)
        let oldCapture = try CommonThreadClient.decoder().decode(CaptureRequest.self, from: oldCaptureJSON)
        try check(oldCapture.url == "https://example.org/chair" && oldCapture.imageDataUrl == nil, "existing queued URL captures remain decodable")
        var imageItemJSON = try JSONSerialization.jsonObject(with: fixture("saved")) as! [String: Any]
        imageItemJSON["original_url"] = ""; imageItemJSON["has_image"] = true; imageItemJSON["image_path"] = "/v1/saves/save-image/image"
        imageItemJSON["suggestions"] = [["id":"suggestion-image", "item_id":"save-image", "kind":"intent", "text":"Remind me about this tomorrow", "claim":"remind_later", "model_version":"astra-v1", "status":"suggested", "intent":"remind_later", "requires_confirmation":true]]
        let imageItem = try CommonThreadClient.decoder().decode(SavedItem.self, from: JSONSerialization.data(withJSONObject: imageItemJSON))
        try check(imageItem.hasImage && imageItem.imagePath == "/v1/saves/save-image/image" && imageItem.originalUrl.isEmpty, "private image resource decode")
        try check(imageItem.suggestions[0].intent == .remindLater && imageItem.suggestions[0].requiresConfirmation, "typed predictive intent and confirmation decode")
        var annotationJSON = try JSONSerialization.jsonObject(with: fixture("annotation")) as! [String: Any]
        annotationJSON["intent"] = "remind_later"; annotationJSON["execution_status"] = "annotation_only"
        let intentReceipt = try CommonThreadClient.decoder().decode(AnnotationReceipt.self, from: JSONSerialization.data(withJSONObject: annotationJSON))
        try check(intentReceipt.intent == .remindLater && intentReceipt.executionStatus == "annotation_only", "confirmed intent is not a scheduled action")
        var imageRequests: [URLRequest] = []
        StubProtocol.handler = { request in
            imageRequests.append(request)
            return (200, imageBytes, ["Content-Type":"image/png", "Cache-Control":"no-store"])
        }
        let loadedImage = try await api.savedImage("save-image")
        try check(loadedImage == imageBytes && imageRequests[0].url?.path == "/v1/saves/save-image/image", "image fetch returns bytes")
        try check(imageRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-token" && imageRequests[0].url?.query == nil, "image auth stays in the header")
        try check(imageRequests[0].cachePolicy == .reloadIgnoringLocalCacheData && imageRequests[0].value(forHTTPHeaderField: "Cache-Control") == "no-store", "private images bypass URL cache")
        for invalidID in ["", "..", "../another-user", "a/b", "a\\b", "id\n"] {
            do { _ = try await api.savedImage(invalidID); throw SmokeFailure.assertion("invalid image ID accepted") }
            catch ClientError.invalidSavedImageId {}
        }
        try check(imageRequests.count == 1, "invalid image paths never reach transport")
        StubProtocol.handler = { _ in (200, Data("<html>login</html>".utf8), ["Content-Type":"text/html"]) }
        do { _ = try await api.savedImage("save-image"); throw SmokeFailure.assertion("non-image response accepted") }
        catch ClientError.invalidResponse {}
        let missingImage = Data(#"{"error":{"code":"not_found","message":"Image unavailable.","retryable":false,"request_id":"private-image"}}"#.utf8)
        StubProtocol.handler = { _ in (404, missingImage, ["Content-Type":"application/json"]) }
        do { _ = try await api.savedImage("save-image"); throw SmokeFailure.assertion("missing image accepted") }
        catch let error as APIError { try check(error.code == "not_found" && error.requestId == "private-image" && !error.retryable, "image errors use the same typed API contract") }
        print("PASS image-only capture, typed annotation intent, private image authentication and error handling")
        // Invented dataset records exercise the local catalog wire contract.
        let catalogItemData = Data(#"""
        {
          "source_id":"uci_retail", "source_record_id":"sku:123 + café #1?", "data_kind":"open_dataset", "title":"Reading lamp",
          "description":null, "category":null, "brand":null, "attributes":{"custom_flag":false},
          "product_key":null, "variant_key":null,
          "merchant":{"id":null,"name":null,"platform":"uci_retail"},
          "offer":{
            "id":"sku:123 + café #1?", "price_minor":null, "currency":null, "shipping_minor":null,
            "availability":"unknown", "condition":null, "url":null,
            "image_url":null, "observed_at":null, "expires_at":null,
            "marketplace_id":null, "environment":"local"
          },
          "provenance":{"source_record_id":"sku:123 + café #1?", "license_id":"CC-BY-4.0", "optional_value":null}
        }
        """#.utf8)
        let catalogSourceData = Data(#"""
        {"items":[
          {"source_id":"impact","configured":false,"enabled_feeds":0,"fresh_records":0,"record_count":0,
           "data_kind":"merchant_feed","name":"Impact feeds","license_id":null,"license_url":null,"attribution":null,
           "environment":"production","marketplace":null,"retrieval":"approved_feed","allowed_uses":[],"ai_use":"disabled","persistence":"approved_snapshot"},
          {"source_id":"uci_retail","configured":true,"enabled_feeds":1,"fresh_records":null,"record_count":3958,
           "data_kind":"open_dataset","name":"UCI Online Retail","license_id":"CC-BY-4.0","license_url":"https://creativecommons.org/licenses/by/4.0/","attribution":"Chen, D. (2015). Online Retail. UCI.",
           "environment":"local","marketplace":null,"retrieval":"local_dataset","allowed_uses":["direct_display","deterministic_search"],"ai_use":"disabled","persistence":"licensed_dataset"},
          {"source_id":"synthetic","configured":true,"enabled_feeds":1,"fresh_records":null,"record_count":100,
           "data_kind":"synthetic","name":"Generated catalog","license_id":null,"license_url":null,"attribution":null,
           "environment":"local","marketplace":null,"retrieval":"local_dataset","allowed_uses":["direct_display","deterministic_search"],"ai_use":"disabled","persistence":"synthetic"}
        ]}
        """#.utf8)
        let catalogItemJSON = try JSONSerialization.jsonObject(with: catalogItemData) as! [String: Any]
        let catalogPageData = try JSONSerialization.data(withJSONObject: [
            "items": [catalogItemJSON], "source_id": "uci_retail", "next_offset": NSNull(), "total": 1,
            "fetched_at": 1700000000.25, "expires_at": NSNull(),
            "environment": "local", "marketplace": NSNull(), "retrieval": "local_dataset"
        ])
        var catalogRequests: [URLRequest] = []
        StubProtocol.handler = { request in
            catalogRequests.append(request)
            switch request.url?.path {
            case "/v1/commerce/sources": return (200, catalogSourceData, ["Cache-Control": "no-store"])
            case "/v1/commerce/search": return (200, catalogPageData, ["Cache-Control": "no-store"])
            default: return (200, catalogItemData, ["Cache-Control": "no-store"])
            }
        }
        let catalogSources = try await api.catalogSources()
        try check(catalogSources.items.map(\.sourceId) == [.impact, .uciRetail, .synthetic], "catalog source identities")
        try check(catalogSources.items[1].freshRecords == nil && catalogSources.items[1].recordCount == 3958, "historical count is not fresh-offer count")
        try check(catalogSources.items[1].licenseId == "CC-BY-4.0" && catalogSources.items[1].attribution != nil, "source license and attribution decode")
        let catalogQuery = "USB-C + lamp & café #1?"
        let catalogPage = try await api.searchProducts(source: .uciRetail, query: catalogQuery, limit: 10, offset: 10001)
        try check(catalogPage.sourceId == .uciRetail && catalogPage.nextOffset == nil && catalogPage.total == 1 && catalogPage.expiresAt == nil, "dataset page decode")
        let catalogItem = try await api.catalogItem(source: .uciRetail, id: "sku:123 + café #1?")
        try check(catalogItem.dataKind == "open_dataset" && catalogItem.merchant.id == nil && catalogItem.merchant.name == nil, "source kind and unknown merchant preserved")
        try check(catalogItem.offer.url == nil && catalogItem.offer.priceMinor == nil && catalogItem.offer.shippingMinor == nil && catalogItem.offer.availability == "unknown", "unknown offer facts preserved")
        try check(catalogItem.offer.isExpired() == nil && !catalogItem.offer.hasCurrentObservation(), "missing expiry does not become an evergreen current offer")
        try check(catalogItem.attributes["custom_flag"] == .bool(false) && catalogItem.provenance["optional_value"] == .null, "dynamic metadata preserved")
        let catalogSearchURL = URLComponents(url: catalogRequests[1].url!, resolvingAgainstBaseURL: false)!
        let catalogParameters = Dictionary(uniqueKeysWithValues: catalogSearchURL.queryItems!.map { ($0.name, $0.value ?? "") })
        try check(catalogParameters == ["source": "uci_retail", "q": catalogQuery, "limit": "10", "offset": "10001"], "catalog parameters encode exactly")
        try check(catalogSearchURL.percentEncodedQuery!.contains("%2B") && !catalogSearchURL.percentEncodedQuery!.contains("+"), "literal plus survives server form query parsing")
        try check(catalogRequests[2].url?.lastPathComponent == "sku:123 + café #1?", "record ID remains one encoded path component")
        try check(catalogRequests[2].url?.path.hasPrefix("/v1/commerce/items/uci_retail/") == true && catalogRequests[2].url?.query == nil, "record ID cannot become a query")
        try check(catalogRequests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" && $0.value(forHTTPHeaderField: "Idempotency-Key") == nil }, "catalog reads use app auth without mutation keys")
        try check(catalogRequests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData && $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" }, "catalog bypasses local cache")
        for query in ["", "  ", String(repeating: "a", count: 101), "lamp\n"] {
            do { _ = try await api.searchProducts(source: .abo, query: query); throw SmokeFailure.assertion("invalid catalog query accepted") }
            catch ClientError.invalidCatalogSearch {}
        }
        for (limit, offset) in [(0, 0), (51, 0), (20, -1), (20, 1000000)] {
            do { _ = try await api.searchProducts(source: .abo, query: "lamp", limit: limit, offset: offset); throw SmokeFailure.assertion("invalid catalog pagination accepted") }
            catch ClientError.invalidCatalogPagination {}
        }
        for source in ["", "Uppercase", "../sources", String(repeating: "a", count: 65)] {
            do { _ = try await api.searchProducts(source: CatalogSource(rawValue: source), query: "lamp"); throw SmokeFailure.assertion("invalid source accepted") }
            catch ClientError.invalidCatalogSource {}
        }
        for itemId in ["", ".", "..", "../search", "sku\\other", "sku\n", String(repeating: "a", count: 1025)] {
            do { _ = try await api.catalogItem(source: .abo, id: itemId); throw SmokeFailure.assertion("invalid record ID accepted") }
            catch ClientError.invalidCatalogItemId {}
        }
        try check(catalogRequests.count == 3, "invalid catalog input never reaches transport")
        var exactMoneyItem = catalogItemJSON
        exactMoneyItem["source_id"] = "synthetic"; exactMoneyItem["data_kind"] = "synthetic"
        exactMoneyItem["merchant"] = ["id": "fictional-seller", "name": "Fictional merchant", "platform": "synthetic"]
        var exactMoneyOffer = exactMoneyItem["offer"] as! [String: Any]
        exactMoneyOffer["price_minor"] = Int(9_000_000_000_000_000); exactMoneyOffer["currency"] = "SGD"
        exactMoneyOffer["observed_at"] = 1699999900; exactMoneyOffer["expires_at"] = 1700000300
        exactMoneyItem["offer"] = exactMoneyOffer
        let exactMoneyData = try JSONSerialization.data(withJSONObject: exactMoneyItem)
        let exactMoneyRecord = try CommonThreadClient.decoder().decode(CatalogRecord.self, from: exactMoneyData)
        try check(exactMoneyRecord.dataKind == "synthetic" && exactMoneyRecord.offer.priceMinor == 9_000_000_000_000_000, "synthetic origin and exact minor-unit money decode")
        try check(exactMoneyRecord.offer.hasCurrentObservation(at: Date(timeIntervalSince1970: 1700000000)), "bounded observation window")
        try check(exactMoneyRecord.offer.isExpired(at: Date(timeIntervalSince1970: 1700000300)) == true, "expired observation remains expired")
        let unknownCatalog = Data(#"{"error":{"code":"unknown_source","message":"Unknown source.","retryable":false,"request_id":"catalog-source"}}"#.utf8)
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try check(query.first(where: { $0.name == "source" })?.value == "future_source", "new syntactically valid source reaches backend validation")
            return (422, unknownCatalog, [:])
        }
        do { _ = try await api.searchProducts(source: CatalogSource(rawValue: "future_source"), query: "lamp"); throw SmokeFailure.assertion("unknown source error expected") }
        catch let error as APIError { try check(error.code == "unknown_source" && !error.retryable && error.requestId == "catalog-source", "backend remains source registry authority") }
        let disabledCatalog = Data(#"{"error":{"code":"catalog_not_configured","message":"Import source data first.","retryable":false,"request_id":"catalog-disabled"}}"#.utf8)
        StubProtocol.handler = { _ in (503, disabledCatalog, [:]) }
        do { _ = try await api.searchProducts(source: .abo, query: "lamp"); throw SmokeFailure.assertion("disabled catalog error expected") }
        catch let error as APIError { try check(error.code == "catalog_not_configured" && !error.retryable && error.requestId == "catalog-disabled", "explicit non-retryable catalog error") }
        print("PASS dataset catalog models, source licenses, null offer semantics, exact money, URL encoding and no-cache transport")

        let analysisObject: [String: Any] = [
            "schema_version":1, "summary":"A rectangular digital watch with vintage-inspired styling.",
            "products":[["product_type":"watch", "category_path":["Accessories", "Wristwatches", "Digital watches"],
                "brand":NSNull(), "model":NSNull(), "attributes":[["name":"style", "value":"vintage-inspired", "basis":"image", "evidence":"Rectangular case and segmented display", "certainty":"inferred"]],
                "use_cases":["Everyday wear"], "search_terms":["digital watch", "vintage-inspired"]]],
            "intent_context":["Interested in comparing watches"], "uncertainties":["Brand label is unreadable"]
        ]
        var analyzedItemObject = try JSONSerialization.jsonObject(with: fixture("saved")) as! [String: Any]
        analyzedItemObject["analysis"] = analysisObject; analyzedItemObject["analysis_status"] = "ready"
        let analyzedItemData = try JSONSerialization.data(withJSONObject: analyzedItemObject)
        let analyzedItem = try CommonThreadClient.decoder().decode(SavedItem.self, from: analyzedItemData)
        try check(analyzedItem.analysisStatus == .ready && analyzedItem.analysis?.products.first?.categoryPath.last == "Digital watches", "typed category path decode")
        try check(analyzedItem.analysis?.products.first?.brand == nil && analyzedItem.analysis?.products.first?.model == nil, "unknown brand and model stay nil")
        try check(analyzedItem.analysis?.products.first?.attributes.first?.certainty == .inferred && analyzedItem.analysis?.uncertainties.first == "Brand label is unreadable", "inferred style retains evidence and uncertainty")
        let libraryPageData = try JSONSerialization.data(withJSONObject: ["items":[analyzedItemObject], "total":1, "next_offset":NSNull(), "query":"vintage + café", "category":"Wristwatches"])
        let reason: [String:Any] = ["kind":"attribute_match", "text":"Matches vintage styling in your saved watch", "saved_item_id":analyzedItem.id,
            "saved_item_title":"My watch", "saved_item_revision":3, "analysis_path":"products.0.attributes.0.value", "evidence_id":NSNull(),
            "matched_value":"vintage-inspired", "catalog_field":"title", "catalog_value":"Vintage-inspired watch"]
        let citation: [String:Any] = ["source_id":"uci_retail", "record_id":"sku:123 + café #1?", "title":"Historical source record",
            "license_id":"CC-BY-4.0", "license_url":"https://creativecommons.org/licenses/by/4.0/", "attribution":"Source attribution", "record_url":NSNull()]
        var exploreObject: [String:Any] = ["items":[["product":catalogItemJSON, "score":12, "score_kind":"heuristic_match", "reasons":[reason], "catalog_citation":citation, "action":"view_source", "action_url":NSNull()]],
            "source_id":"uci_retail", "query":"", "mode":"personalized", "status":"ready", "next_offset":NSNull(),
            "candidate_count":1, "candidate_limit":500, "candidate_window_limited":false, "personalized_from_saves":1,
            "profile_limit":24, "profile_window_limited":false, "context_version":4, "generated_at":1700000000, "ranking_version":"facet-match-v1", "expires_at":NSNull()]
        let exploreData = try JSONSerialization.data(withJSONObject: exploreObject)
        let analyzeData = Data(#"{"id":"save-ai","status":"pending","revision":3,"job_id":"job-ai","queued":true}"#.utf8)
        var aiRequests: [URLRequest] = []
        StubProtocol.handler = { request in
            aiRequests.append(request)
            if request.url?.path == "/v1/library/search" { return (200,libraryPageData,[:]) }
            if request.url?.path == "/v1/explore" { return (200,exploreData,[:]) }
            return (202,analyzeData,[:])
        }
        let libraryPage = try await api.searchLibrary(query:"vintage + café",category:"Wristwatches",limit:10,offset:12)
        try check(libraryPage.total == 1 && libraryPage.items.first?.analysisStatus == .ready && libraryPage.category == "Wristwatches", "server Library search returns typed analyses")
        let libraryQuery = URLComponents(url:aiRequests[0].url!,resolvingAgainstBaseURL:false)!.queryItems!
        try check(libraryQuery.first(where:{$0.name == "q"})?.value == "vintage + café" && libraryQuery.first(where:{$0.name == "offset"})?.value == "12", "Library Unicode query and paging preserved")
        let explorePage = try await api.explore()
        try check(explorePage.status == .ready && explorePage.mode == .personalized && explorePage.items.first?.reasons.first?.kind == .attributeMatch, "typed Explore reason decode")
        try check(explorePage.items.first?.reasons.first?.savedItemId == analyzedItem.id && explorePage.items.first?.catalogCitation.licenseId == "CC-BY-4.0", "Explore citations preserve Library and source attribution")
        try check(explorePage.items.first?.action == .viewSource && explorePage.items.first?.actionUrl == nil && explorePage.items.first?.product.offer.priceMinor == nil, "unknown current offer never becomes buy action")
        let defaultExploreQuery = URLComponents(url:aiRequests[1].url!,resolvingAgainstBaseURL:false)!.queryItems!
        try check(!defaultExploreQuery.contains(where:{$0.name == "source"}), "backend source default requires no client provider configuration")
        _ = try await api.explore(query:"watch + strap", source:.abo,limit:5,offset:10)
        let sourceExploreQuery = URLComponents(url:aiRequests[2].url!,resolvingAgainstBaseURL:false)!.queryItems!
        try check(sourceExploreQuery.first(where:{$0.name == "source"})?.value == "abo" && sourceExploreQuery.first(where:{$0.name == "q"})?.value == "watch + strap", "explicit Explore source and query preserved")
        let analysisKey = MutationKey()
        let analysisReceipt = try await api.analyzeSave("save-ai",key:analysisKey)
        _ = try await api.analyzeSave("save-ai",key:analysisKey)
        try check(analysisReceipt.queued && analysisReceipt.jobId == "job-ai" && analysisReceipt.revision == 3, "analysis queue receipt")
        try check(aiRequests.suffix(2).allSatisfy { $0.httpMethod == "POST" && $0.httpBody == nil && $0.value(forHTTPHeaderField:"Idempotency-Key") == analysisKey.rawValue }, "reanalysis retries retain key without retransmitting image")
        try check(aiRequests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData && $0.value(forHTTPHeaderField:"Authorization") == "Bearer test-token" }, "AI reads and reanalysis remain account authenticated and uncached")
        for query in [String(repeating:"q",count:201), "watch\n"] {
            do { _ = try await api.searchLibrary(query:query); throw SmokeFailure.assertion("invalid Library query accepted") } catch ClientError.invalidLibrarySearch {}
        }
        do { _ = try await api.searchLibrary(offset:100001); throw SmokeFailure.assertion("invalid Library offset accepted") } catch ClientError.invalidPagination {}
        do { _ = try await api.explore(offset:500); throw SmokeFailure.assertion("invalid Explore offset accepted") } catch ClientError.invalidExploreSearch {}
        do { _ = try await api.analyzeSave("../other",key:analysisKey); throw SmokeFailure.assertion("invalid reanalysis ID accepted") } catch ClientError.invalidSavedItemId {}
        try check(aiRequests.count == 5, "invalid AI API requests do not reach transport")
        exploreObject["items"] = []; exploreObject["status"] = "needs_saves"; exploreObject["personalized_from_saves"] = 0
        let emptyExplore = try CommonThreadClient.decoder().decode(ExplorePage.self,from:JSONSerialization.data(withJSONObject:exploreObject))
        try check(emptyExplore.items.isEmpty && emptyExplore.status == .needsSaves, "cold start remains an explicit empty state")
        print("PASS typed product analysis, Library search, cited Explore, cold start, and idempotent reanalysis")

        for url in ["http://api.example.org", "https://api.example.org/v1", "https://user:pass@api.example.org", "https://api.example.org?x=1"] {
            do { _ = try CommonThreadClient(baseURL: URL(string: url)!) { "token" }; throw SmokeFailure.assertion("invalid URL accepted") }
            catch ClientError.invalidBaseURL {}
        }
        _ = try CommonThreadClient(baseURL: URL(string: "http://127.0.0.1:8000")!) { "token" }
        for (interval, timeout) in [(Double.nan, 30.0), (Double.infinity, 30.0), (1.0, Double.nan), (1.0, Double.infinity), (0.0, 30.0)] {
            do { _ = try await api.waitForEnrichment("save", interval: interval, timeout: timeout); throw SmokeFailure.assertion("invalid polling options accepted") }
            catch ClientError.invalidPollingOptions {}
        }
        print("PASS HTTPS/origin validation and nonfinite polling option rejection")
        let key = MutationKey(), capture = CaptureRequest(url: "https://example.org/desk", title: "Desk", client: .iosShareExtension)
        let receipt = try fixture("capture"); var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 { throw URLError(.networkConnectionLost) }
            return (201, receipt, [:])
        }
        do { _ = try await api.capture(capture, key: key); throw SmokeFailure.assertion("transport failure expected") } catch is URLError {}
        _ = try await api.capture(capture, key: key)
        try check(requests.count == 2, "exactly two caller-driven attempts")
        try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == key.rawValue }, "stable key")
        try check(requests[0].httpBody == requests[1].httpBody && requests[0].httpBody != nil, "stable payload")
        try check(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "injected auth")
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        try check(body["client"] as? String == "ios_share_extension" && body["selected_text"] as? String == "", "wire keys")
        print("PASS lost-response retry retains key, body, auth, and client origin")

        let denied = try fixture("unauthorized")
        StubProtocol.handler = { _ in (401, denied, [:]) }
        do { _ = try await api.account(); throw SmokeFailure.assertion("401 expected") }
        catch let error as APIError { try check(error.code == "unauthorized" && error.requestId != nil && !error.retryable, "typed 401") }
        let conflict = try fixture("stale_version"); var attempts = 0
        StubProtocol.handler = { _ in attempts += 1; return (409, conflict, [:]) }
        do { _ = try await api.apply(DiscoveryEvent(expectedVersion: 1, action: .retrieve), to: "session", key: MutationKey()); throw SmokeFailure.assertion("409 expected") }
        catch let error as APIError { try check(error.isVersionConflict && error.current?.version == 2, "current session conflict") }
        try check(attempts == 1, "no automatic conflict retry")
        StubProtocol.handler = { _ in (503, Data("unavailable".utf8), ["X-Request-ID": "proxy-id"]) }
        do { _ = try await api.account(); throw SmokeFailure.assertion("503 expected") }
        catch let error as APIError { try check(error.retryable && error.requestId == "proxy-id", "non-JSON error fallback") }
        print("PASS 401, stale-version snapshot, non-JSON 503 and request IDs")

        let pending = try fixture("pending"), ready = try fixture("saved"); var polls = 0
        StubProtocol.handler = { _ in polls += 1; return (200, polls == 1 ? pending : ready, [:]) }
        let result = try await api.waitForEnrichment("save", interval: 0.01, timeout: 1)
        try check(result.status == "ready" && polls == 2, "poll terminal state")
        StubProtocol.handler = { _ in (200, pending, [:]) }
        do { _ = try await api.waitForEnrichment("save", timeout: 0); throw SmokeFailure.assertion("timeout expected") }
        catch ClientError.pollingTimedOut(let item) { try check(item.status == "pending", "retained timeout state") }
        var failure = try JSONSerialization.jsonObject(with: pending) as! [String: Any]; failure["status"] = "enrichment_failed"
        let failureData = try JSONSerialization.data(withJSONObject: failure)
        StubProtocol.handler = { _ in (200, failureData, [:]) }
        let failed = try await api.waitForEnrichment("save")
        try check(failed.status == "enrichment_failed", "enrichment failure preserves save")
        print("PASS pending-to-ready polling, timeout, and enrichment failure")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://api.example.org")!
        let draft = PendingCapture(request: capture, accountId: "alex", baseURL: url), outbox = CaptureOutbox(directory: directory)
        try await outbox.enqueue(draft); try await outbox.enqueue(draft)
        let own = try await outbox.pending(accountId: "alex", baseURL: url)
        let otherUser = try await outbox.pending(accountId: "sam", baseURL: url)
        let otherServer = try await outbox.pending(accountId: "alex", baseURL: URL(string: "https://other.example.org")!)
        try check(own.count == 1 && own[0].key == draft.key && own[0].request == capture, "persist immutable intent")
        try check(otherUser.isEmpty && otherServer.isEmpty, "account and backend isolation")
        try await outbox.remove(draft)
        let removed = try await outbox.pending(accountId: "alex", baseURL: url)
        try check(removed.isEmpty, "remove on acknowledgment")
        print("PASS durable outbox, duplicate enqueue, account/backend isolation, removal")
        print("All standalone Swift checks passed.")
    }
}
