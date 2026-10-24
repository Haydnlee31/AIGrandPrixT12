import Foundation
import Security
import UIKit
import LinkPresentation
import UniformTypeIdentifiers

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
        var contextTitle = title
        var contextImage = imageData
        var contextText = text
        // Enrich the model input, independently of the user's editable display title.
        // Never substitute the site's icon for product imagery. Failed/slow metadata
        // stays optional and cannot block local saving or keep this request hanging.
        if let raw = url, let page = publicURL(raw), imageData == nil {
            let provider = LPMetadataProvider(); provider.timeout = 6
            do {
                let metadata = try await withTaskCancellationHandler {
                    try await provider.startFetchingMetadata(for: page)
                } onCancel: { provider.cancel() }
                try Task.checkCancellation()
                if let fetched = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !fetched.isEmpty {
                    if title.isEmpty || title == page.host || ["A new find", "A photo worth saving"].contains(title) {
                        contextTitle = String(fetched.prefix(300))
                    }
                    // Captions such as "Post from …" and custom names must not
                    // suppress a more informative title supplied by the source page.
                    contextText = "Source page title: " + String(fetched.prefix(600)) + (text.isEmpty ? "" : "\n" + text)
                }
                if let provider = metadata.imageProvider, let bytes = await readMetadataImage(provider) {
                    contextImage = bytes
                }
                try Task.checkCancellation()
            } catch is CancellationError { throw CancellationError() } catch { /* URL-only uncertainty is handled by the model. */ }
        }
        try Task.checkCancellation()
        var payload: [String: Any] = ["title": String(contextTitle.prefix(300)), "text": String(contextText.prefix(12_000)), "note": String(note.prefix(2_000))]
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
        let data = try await post(path: "v1/capture-preview", body: JSONSerialization.data(withJSONObject: payload))
        do {
            let value = try JSONDecoder().decode(CaptureIntelligenceResult.self, from: data)
            guard value.schemaVersion == 2, value.prompts.count <= 3, value.prompts.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 180 }),
                  Set(value.prompts.map(\.id)).count == value.prompts.count else { throw Failure.unreadable }
            return value
        } catch { throw Failure.unreadable }
    }

    /// NSItemProvider callbacks are not guaranteed to arrive after cancellation.
    /// One protected continuation is completed by the first callback/timeout/cancel.
    private final class MetadataImageRead: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var continuation: CheckedContinuation<Data?, Never>?
        private var progress: Progress?

        func install(_ value: CheckedContinuation<Data?, Never>) -> Bool {
            lock.lock()
            if completed { lock.unlock(); value.resume(returning: nil); return false }
            continuation = value; lock.unlock(); return true
        }
        func register(_ value: Progress) {
            lock.lock()
            let alreadyCompleted = completed
            if !alreadyCompleted { progress = value }
            lock.unlock()
            if alreadyCompleted { value.cancel() }
        }
        func finish(_ data: Data?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let continuation = self.continuation; self.continuation = nil
            let progress = self.progress; self.progress = nil
            lock.unlock()
            progress?.cancel()
            continuation?.resume(returning: data)
        }
    }
    private static func readMetadataImage(_ provider: NSItemProvider) async -> Data? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return nil }
        let read = MetadataImageRead()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard read.install(continuation) else { return }
                let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    read.finish(data.flatMap { $0.count <= 4 * 1024 * 1024 ? $0 : nil })
                }
                read.register(progress)
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    read.finish(nil)
                }
            }
        } onCancel: { read.finish(nil) }
    }

    /// One bounded retry handles a transient tunnel/mobile connection without
    /// requiring a second tap. A server cache coalesces repeated analysis inputs.
    static func post(path: String, body: Data) async throws -> Data {
        guard ["v1/capture-preview", "v1/recommendations"].contains(path),
              let config = try configuration() else { throw Failure.configuration }
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 50
        request.setValue("Bearer " + config.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 50; settings.timeoutIntervalForResource = 60
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw Failure.network }
                if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
                if attempt == 0 && [429, 502, 503, 504].contains(http.statusCode) {
                    try await Task.sleep(for: .seconds(1)); continue
                }
                if http.statusCode == 429 { throw Failure.busy }
                guard http.statusCode == 200 else { throw Failure.unavailable }
                guard data.count <= 512_000 else { throw Failure.unreadable }
                return data
            } catch is CancellationError { throw CancellationError() }
            catch let failure as Failure { throw failure }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 0 { try await Task.sleep(for: .seconds(1)); continue }
                throw Failure.network
            }
        }
        throw Failure.network
    }
    private static func publicURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
