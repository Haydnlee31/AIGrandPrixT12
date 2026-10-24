import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Create once per user action; persist with the exact payload before sending.
public struct MutationKey: Codable, Sendable, Hashable {
    public let rawValue: String
    public init() { rawValue = UUID().uuidString }
    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty, rawValue.count <= 128,
              rawValue.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw ClientError.invalidMutationKey }
        self.rawValue = rawValue
    }
}
public enum ClientError: Error, LocalizedError {
    case invalidBaseURL, missingToken, invalidMutationKey, invalidResponse, invalidPagination, invalidPollingOptions
    case invalidCatalogSearch, invalidCatalogPagination, invalidCatalogSource, invalidCatalogItemId
    case invalidSavedImageId
    case pollingTimedOut(lastKnown: SavedItem)
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Use an HTTPS API origin without a path, credentials, query, or fragment. HTTP is allowed only on localhost."
        case .missingToken: return "Sign in before connecting."
        case .invalidMutationKey: return "Use a nonempty printable idempotency key of at most 128 characters."
        case .invalidResponse: return "The server returned an unexpected response."
        case .invalidPagination: return "Use a nonnegative offset and a limit between 1 and 100."
        case .invalidPollingOptions: return "Use a finite positive polling interval and a finite timeout from zero to one day."
        case .invalidCatalogSearch: return "Enter a search query of 1–100 characters without control characters."
        case .invalidCatalogPagination: return "Use a catalog limit of 1–50 and an offset below 1000000."
        case .invalidCatalogSource: return "Use a catalog source name returned by the backend."
        case .invalidCatalogItemId: return "Use a bounded single record ID returned by product search."
        case .invalidSavedImageId: return "Use a single saved-item ID returned by the Library."
        case .pollingTimedOut: return "Your save is stored. Processing is still pending; refresh later."
        }
    }
}
public struct APIError: Error, LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public let retryable: Bool
    public let requestId: String?
    /// Reconcile with this snapshot before issuing a new user action/key. Never silently replay a stale edit.
    public let current: DiscoverySession?
    public var isVersionConflict: Bool { status == 409 && code == "stale_version" }
    public var errorDescription: String? { message }
}
private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let message: String; let retryable: Bool; let requestId: String?; let current: DiscoverySession? }
    let error: Detail
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// UI-independent client. Supply a fresh token from your credential store; the library never persists credentials.
public actor CommonThreadClient {
    public typealias TokenProvider = @Sendable () async throws -> String
    private let baseURL: URL
    private let tokenProvider: TokenProvider
    private let session: URLSession

    public init(baseURL: URL, session: URLSession? = nil, tokenProvider: @escaping TokenProvider) throws {
        let scheme = baseURL.scheme?.lowercased(), host = baseURL.host?.lowercased()
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "")
        guard scheme == "https" || (scheme == "http" && local), host != nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw ClientError.invalidBaseURL }
        self.baseURL = baseURL; self.tokenProvider = tokenProvider
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    private func send<Response: Decodable>(_ method: String = "GET", _ path: [String], query: [URLQueryItem] = [], body: Data? = nil, key: MutationKey? = nil, uncached: Bool = false) async throws -> Response {
        let data = try await sendData(method, path, query: query, body: body, key: key, uncached: uncached)
        return try Self.decoder().decode(Response.self, from: data)
    }
    private func sendData(_ method: String = "GET", _ path: [String], query: [URLQueryItem] = [], body: Data? = nil, key: MutationKey? = nil, uncached: Bool = false, image: Bool = false) async throws -> Data {
        var url = baseURL
        for component in path { url.appendPathComponent(component) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClientError.invalidBaseURL }
        parts.queryItems = query.isEmpty ? nil : query
        // URLQueryItem permits literal '+', but the server's query parser reads it
        // as a space. Preserve searches such as "USB-C + lamp" exactly.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let requestURL = parts.url else { throw ClientError.invalidBaseURL }
        var request = URLRequest(url: requestURL)
        if uncached {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        }
        request.httpMethod = method; request.httpBody = body
        let token = try await tokenProvider()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw ClientError.missingToken }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(image ? "image/jpeg, image/png, image/webp" : "application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue(key.rawValue, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? Self.decoder().decode(ErrorEnvelope.self, from: data).error
            throw APIError(status: http.statusCode, code: detail?.code ?? "http_error", message: detail?.message ?? "The server returned HTTP \(http.statusCode).", retryable: detail?.retryable ?? [429, 503].contains(http.statusCode), requestId: detail?.requestId ?? http.value(forHTTPHeaderField: "X-Request-ID"), current: detail?.current)
        }
        if image {
            guard ["image/jpeg", "image/png", "image/webp"].contains(http.mimeType ?? ""), data.count <= 4 * 1024 * 1024 else { throw ClientError.invalidResponse }
        }
        return data
    }
    private func mutation<Body: Encodable, Response: Decodable>(_ method: String = "POST", _ path: [String], _ body: Body, key: MutationKey) async throws -> Response {
        try await send(method, path, body: Self.encoder().encode(body), key: key)
    }
    private func page(_ offset: Int, _ limit: Int) throws -> [URLQueryItem] {
        guard offset >= 0, (1...100).contains(limit) else { throw ClientError.invalidPagination }
        return [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))]
    }
    public func account() async throws -> Account { try await send("GET", ["v1", "me"]) }
    public func capabilities() async throws -> Capabilities { try await send("GET", ["v1", "capabilities"]) }
    public func capture(_ request: CaptureRequest, key: MutationKey) async throws -> CaptureReceipt { try await mutation("POST", ["v1", "saves"], request, key: key) }
    public func collection(offset: Int = 0, limit: Int = 30) async throws -> CollectionPage { try await send("GET", ["v1", "collection"], query: page(offset, limit)) }
    public func savedItem(_ id: String) async throws -> SavedItem { try await send("GET", ["v1", "saves", id]) }
    /// Load private image bytes with the current account's bearer token and no local URL cache.
    public func savedImage(_ id: String) async throws -> Data {
        guard !id.isEmpty, id.count <= 200, ![".", ".."].contains(id), !id.contains("/"), !id.contains("\\"),
              id.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw ClientError.invalidSavedImageId }
        return try await sendData("GET", ["v1", "saves", id, "image"], uncached: true, image: true)
    }
    public func deleteSavedItem(_ id: String, key: MutationKey) async throws -> DeleteReceipt { try await send("DELETE", ["v1", "saves", id], key: key) }
    public func respond(to id: String, with response: AnnotationRequest, key: MutationKey) async throws -> AnnotationReceipt { try await mutation("POST", ["v1", "saves", id, "responses"], response, key: key) }
    public func hypotheses() async throws -> ItemList<Hypothesis> { try await send("GET", ["v1", "hypotheses"]) }
    public func feedback(on id: String, action: HypothesisFeedback, key: MutationKey) async throws -> Hypothesis { try await mutation("POST", ["v1", "hypotheses", id, "feedback"], ["action": action], key: key) }
    public func startDiscovery(explicit: Bool = false, key: MutationKey) async throws -> DiscoverySession { try await mutation("POST", ["v1", "discovery-sessions"], ["explicit": explicit], key: key) }
    public func discoveries(offset: Int = 0, limit: Int = 30) async throws -> ItemList<DiscoverySession> { try await send("GET", ["v1", "discovery-sessions"], query: page(offset, limit)) }
    public func discovery(_ id: String) async throws -> DiscoverySession { try await send("GET", ["v1", "discovery-sessions", id]) }
    public func apply(_ event: DiscoveryEvent, to id: String, key: MutationKey) async throws -> DiscoverySession { try await mutation("POST", ["v1", "discovery-sessions", id, "events"], event, key: key) }
    public func catalog() async throws -> Catalog { try await send("GET", ["v1", "catalog"]) }
    /// Source readiness and permitted retrieval modes; never contains provider secrets.
    public func catalogSources() async throws -> CatalogSources {
        try await send("GET", ["v1", "commerce", "sources"], uncached: true)
    }
    /// Search one licensed dataset or approved feed. Source data does not guarantee delivery.
    public func searchProducts(source: CatalogSource, query: String, limit: Int = 20, offset: Int = 0) async throws -> CatalogSearchPage {
        try validateCatalogSource(source)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, query.unicodeScalars.count <= 100,
              query.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { throw ClientError.invalidCatalogSearch }
        guard (1...50).contains(limit), (0..<1000000).contains(offset) else { throw ClientError.invalidCatalogPagination }
        let parameters = [URLQueryItem(name: "source", value: source.rawValue), URLQueryItem(name: "q", value: query),
                          URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        return try await send("GET", ["v1", "commerce", "search"], query: parameters, uncached: true)
    }
    /// Refresh a source record. Missing offer timestamps or URL must remain unknown.
    public func catalogItem(source: CatalogSource, id: String) async throws -> CatalogRecord {
        try validateCatalogSource(source)
        guard !id.isEmpty, id.unicodeScalars.count <= 1024, ![".", ".."].contains(id),
              !id.contains("/"), !id.contains("\\"), id.unicodeScalars.allSatisfy({ $0.value >= 32 }) else {
            throw ClientError.invalidCatalogItemId
        }
        return try await send("GET", ["v1", "commerce", "items", source.rawValue, id], uncached: true)
    }
    private func validateCatalogSource(_ source: CatalogSource) throws {
        guard source.rawValue.range(of: #"\A[a-z][a-z0-9_]{0,63}\z"#, options: .regularExpression) != nil else {
            throw ClientError.invalidCatalogSource
        }
    }
    public func createWatch(_ request: WatchRequest, key: MutationKey) async throws -> PriceWatch { try await mutation("POST", ["v1", "watches"], request, key: key) }
    public func watches(offset: Int = 0, limit: Int = 30) async throws -> ItemList<PriceWatch> { try await send("GET", ["v1", "watches"], query: page(offset, limit)) }
    public func watch(_ id: String) async throws -> PriceWatch { try await send("GET", ["v1", "watches", id]) }
    public func updateWatch(_ id: String, update: WatchUpdate, key: MutationKey) async throws -> PriceWatch { try await mutation("PATCH", ["v1", "watches", id], update, key: key) }
    public func simulatePrice(for id: String, observation: PriceSimulation, key: MutationKey) async throws -> JobReceipt { try await mutation("POST", ["v1", "watches", id, "simulate"], observation, key: key) }
    public func notifications(offset: Int = 0, limit: Int = 30) async throws -> ItemList<AppNotification> { try await send("GET", ["v1", "notifications"], query: page(offset, limit)) }
    public func job(_ id: String) async throws -> JobStatus { try await send("GET", ["v1", "jobs", id]) }

    /// Foreground helper only. Cancellation propagates; timeout preserves the last known saved item.
    /// Enrichment failure is terminal and returned to the UI, never treated as a failed capture.
    public func waitForEnrichment(_ id: String, interval: TimeInterval = 1.5, timeout: TimeInterval = 30) async throws -> SavedItem {
        guard interval.isFinite, interval > 0, timeout.isFinite, (0...86_400).contains(timeout) else { throw ClientError.invalidPollingOptions }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            try Task.checkCancellation()
            let item = try await savedItem(id)
            if !item.isEnriching { return item }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ClientError.pollingTimedOut(lastKnown: item) }
            try await Task.sleep(nanoseconds: UInt64(min(max(interval, 0.01), remaining) * 1_000_000_000))
        }
    }
}
