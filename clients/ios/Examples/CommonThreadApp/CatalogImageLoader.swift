import Foundation

/// Public catalog photos only. No account headers, cookies, or saved-find data.
/// The work outlives a scrolling card so opening its detail reuses the request.
@MainActor final class CatalogImageLoader {
    static let shared = CatalogImageLoader()
    nonisolated static let maximumBytes = 5 * 1_024 * 1_024
    enum Failure: Error { case invalidURL, unavailable, tooLarge, capacity }

    private let session: URLSession
    private let memory = NSCache<NSURL, NSData>()
    private var inFlight: [URL: Task<Data, Error>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 15
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config, delegate: CatalogImageRedirectGuard(), delegateQueue: nil)
        }
        memory.countLimit = 64
        memory.totalCostLimit = 16 * 1_024 * 1_024
    }

    nonisolated static func publicURL(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.contains("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return url
    }

    func data(for url: URL) async throws -> Data {
        guard let url = Self.publicURL(url) else { throw Failure.invalidURL }
        if let value = memory.object(forKey: url as NSURL) { return value as Data }
        if let work = inFlight[url] { return try await work.value }
        guard inFlight.count < 24 else { throw Failure.capacity }
        let work = Task { @MainActor in
            await takeSlot()
            defer { releaseSlot() }
            let value = try await Self.fetch(url, session: session)
            memory.setObject(value as NSData, forKey: url as NSURL, cost: value.count)
            return value
        }
        inFlight[url] = work
        defer { inFlight[url] = nil }
        return try await work.value
    }

    /// Do not preserve a response which passed transport checks but cannot decode.
    func discard(_ url: URL) { memory.removeObject(forKey: url as NSURL) }

    private func takeSlot() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }

    nonisolated private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        for attempt in 0...1 {
            do {
                var request = URLRequest(url: url)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      let finalURL = http.url, Self.publicURL(finalURL) != nil else { throw Failure.unavailable }
                if attempt == 0 && (http.statusCode == 429 || (500...599).contains(http.statusCode)) {
                    bytes.task.cancel()
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                guard http.statusCode == 200, response.mimeType?.lowercased().hasPrefix("image/") == true else {
                    bytes.task.cancel(); throw Failure.unavailable
                }
                guard response.expectedContentLength <= Self.maximumBytes else {
                    bytes.task.cancel(); throw Failure.tooLarge
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < Self.maximumBytes else { bytes.task.cancel(); throw Failure.tooLarge }
                    data.append(byte)
                }
                guard !data.isEmpty else { throw Failure.unavailable }
                return data
            } catch let error as URLError where attempt == 0 && [
                URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet
            ].contains(error.code) {
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw Failure.unavailable
    }
}

private final class CatalogImageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No credentials are attached, and HTTPS photos cannot redirect into
        // local resources or silently downgrade to an insecure transport.
        guard let url = request.url else { completionHandler(nil); return }
        let allowed = CatalogImageLoader.publicURL(url) != nil
        completionHandler(allowed ? request : nil)
    }
}
