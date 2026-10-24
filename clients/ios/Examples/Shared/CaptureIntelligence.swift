import Foundation
import Security
import UIKit
import LinkPresentation

/// The phone holds only a scoped relay credential. The OpenAI key stays on the server.
enum CaptureIntelligence {
    struct Configuration: Codable, Sendable {
        let baseURL: URL
        let accessToken: String
        func validated() throws -> Self {
            guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", let host = parts.host, host.contains("."),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/", accessToken.count >= 24,
                  !accessToken.hasPrefix("sk-"), !accessToken.contains(where: \.isWhitespace) else { throw Failure.configuration }
            return self
        }
    }
    enum Failure: LocalizedError {
        case configuration, unavailable, unauthorized, busy, unreadable, network
        var errorDescription: String? {
            switch self {
            case .configuration: "Connect shopping intelligence in Profile to get tailored suggestions."
            case .unavailable: "AI suggestions are unavailable right now. You can still save this find."
            case .unauthorized: "The AI connection needs to be updated in Profile. Your find can still be saved."
            case .busy: "AI is busy. Wait a moment and try suggestions again. Saving still works."
            case .unreadable: "AI couldn’t read this find clearly. Add a photo or a short description."
            case .network: "Couldn’t reach shopping intelligence. Check your connection or save for later."
            }
        }
    }
    private static let service = "MynahFinds.CaptureIntelligence.v1"
    private static func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CommonThreadKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw Failure.configuration }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "connection", kSecAttrAccessGroup as String: group,
                kSecAttrSynchronizable as String: false]
    }
    static var isConfigured: Bool { (try? configuration()) != nil }
    static func configuration() throws -> Configuration? {
        var query = try query(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.configuration }
        return try JSONDecoder().decode(Configuration.self, from: data).validated()
    }
    static func configure(_ configuration: Configuration) throws {
        let value = try configuration.validated()
        let data = try JSONEncoder().encode(value)
        let query = try query()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw Failure.configuration }
        } else if status != errSecSuccess { throw Failure.configuration }
    }
    static func disconnect() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.configuration }
    }
    #if DEBUG
    /// Developer installation imports a scoped connection once, then removes the transfer file.
    static func importDevelopmentConfiguration() throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mynah-preview-connection.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_384 else { throw Failure.configuration }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try configure(config)
        try FileManager.default.removeItem(at: url)
    }
    #endif

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    @MainActor static func analyze(url: String?, title: String, text: String, note: String, imageData: Data?) async throws -> CaptureIntelligenceResult {
        guard let config = try configuration() else { throw Failure.configuration }
        var contextTitle = title
        let contextImage = imageData
        // LinkPresentation can supply the actual page title when the source permits it.
        // Obvious local addresses are excluded; no authentication is supplied by the app.
        if let raw = url, let page = publicURL(raw), imageData == nil {
            let provider = LPMetadataProvider(); provider.timeout = 6
            do {
                let metadata = try await withTaskCancellationHandler {
                    try await provider.startFetchingMetadata(for: page)
                } onCancel: { provider.cancel() }
                try Task.checkCancellation()
                if (title.isEmpty || title == page.host), let fetched = metadata.title {
                    contextTitle = String(fetched.prefix(300))
                }
            } catch is CancellationError { throw CancellationError() } catch { /* URL-only uncertainty is handled by the model. */ }
        }
        try Task.checkCancellation()
        var payload: [String: Any] = ["title": String(contextTitle.prefix(300)), "text": String(text.prefix(12_000)), "note": String(note.prefix(2_000))]
        if let url, !url.isEmpty { payload["url"] = url }
        if let data = contextImage, let image = UIImage(data: data) {
            let scale = min(1, 1024 / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let bytes = thumbnail.jpegData(compressionQuality: 0.65), bytes.count <= 1_500_000 {
                payload["image_data_url"] = "data:image/jpeg;base64," + bytes.base64EncodedString()
            }
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/capture-preview"))
        request.httpMethod = "POST"; request.timeoutInterval = 55
        request.setValue("Bearer " + config.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 55; settings.timeoutIntervalForResource = 65
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw Failure.network }
            if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
            if http.statusCode == 429 { throw Failure.busy }
            guard http.statusCode == 200 else { throw Failure.unavailable }
            guard data.count <= 256_000 else { throw Failure.unreadable }
            let value = try JSONDecoder().decode(CaptureIntelligenceResult.self, from: data)
            guard value.prompts.count <= 3, value.prompts.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 180 }),
                  Set(value.prompts.map(\.id)).count == value.prompts.count else { throw Failure.unreadable }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw Failure.network }
    }
    private static func publicURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
