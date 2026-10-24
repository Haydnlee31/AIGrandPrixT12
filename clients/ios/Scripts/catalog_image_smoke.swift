import Foundation

private final class ImageFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var counts: [String: Int] = [:]
    static var receivedPrivateHeader = false
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        let call = Self.counts[path]!
        Self.receivedPrivateHeader = Self.receivedPrivateHeader || request.value(forHTTPHeaderField: "Authorization") != nil || request.value(forHTTPHeaderField: "Cookie") != nil
        Self.lock.unlock()
        if path == "/timeout" && call == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let status = path == "/missing" ? 404 : path == "/retry" && call == 1 ? 503 : 200
        let mime = path == "/html" ? "text/html" : "image/png"
        let contentLength = path == "/declared-too-large" ? String(6 * 1_024 * 1_024) : String(Self.png.count)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": mime, "Content-Length": contentLength])!
        let send = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if path == "/stream-too-large" {
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 5 * 1_024 * 1_024 + 1))
            } else { client?.urlProtocol(self, didLoad: Self.png) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if path == "/shared" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: send) }
        else { send() }
    }
    override func stopLoading() {}
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
}

@main struct CatalogImageSmoke {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageFixtureProtocol.self]
        config.urlCache = nil; config.httpCookieStorage = nil
        let loader = CatalogImageLoader(session: URLSession(configuration: config))
        @Sendable func url(_ path: String) -> URL { URL(string: "https://photos.example.com" + path)! }
        func expectFailure(_ path: String) async {
            do { _ = try await loader.data(for: url(path)); fatalError("Expected failure for \(path)") }
            catch {}
        }
        let first = try await loader.data(for: url("/image"))
        let cached = try await loader.data(for: url("/image"))
        precondition(first == ImageFixtureProtocol.png && cached == first)
        precondition(ImageFixtureProtocol.count("/image") == 1, "Successful photo should be cached")
        loader.discard(url("/image"))
        _ = try await loader.data(for: url("/image"))
        precondition(ImageFixtureProtocol.count("/image") == 2, "Decode rejection must evict bytes")

        async let sharedA = loader.data(for: url("/shared"))
        async let sharedB = loader.data(for: url("/shared"))
        let shared = try await (sharedA, sharedB)
        precondition(shared.0 == first && shared.1 == first && ImageFixtureProtocol.count("/shared") == 1)

        _ = try await loader.data(for: url("/retry"))
        _ = try await loader.data(for: url("/timeout"))
        precondition(ImageFixtureProtocol.count("/retry") == 2 && ImageFixtureProtocol.count("/timeout") == 2)
        await expectFailure("/missing")
        await expectFailure("/missing")
        precondition(ImageFixtureProtocol.count("/missing") == 2, "Failure is neither retried blindly nor cached as an image")
        await expectFailure("/html")
        await expectFailure("/declared-too-large")
        await expectFailure("/stream-too-large")
        for unsafe in ["http://photos.example.com/a", "https://127.0.0.1/a", "https://server.local/a", "https://user:pass@photos.example.com/a", "https://photos.example.com:8787/a"] {
            precondition(CatalogImageLoader.publicURL(URL(string: unsafe)!) == nil)
        }
        precondition(!ImageFixtureProtocol.receivedPrivateHeader)
        print("Catalog image smoke: cache, eviction, coalescing, retries, missing image, MIME, streamed size, URL and private-header checks passed")
    }
}
