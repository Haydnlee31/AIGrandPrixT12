import SwiftUI
import LinkPresentation
import UniformTypeIdentifiers
import CryptoKit
import ImageIO

/// A source-page thumbnail, not a catalog image or a change to the saved title.
struct WebsitePreview: View {
    enum Presentation { case card, thumbnail, hero }
    let url: URL
    var presentation: Presentation = .card
    var onImageReady: ((Bool) -> Void)? = nil
    var reservedBottomSpace: CGFloat = 0
    @State private var image: UIImage?
    @State private var record: WebsitePreviewRecord?
    @State private var loadedURL: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loadedURL == url.absoluteString, let image {
                Color(.secondarySystemBackground).frame(height: presentation == .hero ? 280 + reservedBottomSpace : presentation == .thumbnail ? 76 : 180)
                    .overlay {
                        if presentation == .hero {
                            Image(uiImage: image).resizable().scaledToFit().padding(.bottom, reservedBottomSpace)
                        }
                        else { Image(uiImage: image).resizable().scaledToFill() }
                    }
                    .clipped().accessibilityLabel(record?.title ?? "Website preview")
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "globe").font(presentation == .thumbnail ? .title3 : .title)
                        .foregroundStyle(.blue)
                    if loading { ProgressView().controlSize(.small).tint(.blue) }
                }.frame(maxWidth: .infinity)
                    .frame(height: presentation == .thumbnail ? 64 : presentation == .hero ? 96 : 82)
                    .background(Color.blue.opacity(0.055))
                    .accessibilityLabel(loading ? "Loading website preview" : "Website link")
            }
        }
        .task(id: url.absoluteString) {
            let requestedURL = url.absoluteString
            record = nil; image = nil; loading = true; onImageReady?(false)
            let result = await WebsitePreviewStore.shared.preview(url)
            guard !Task.isCancelled, requestedURL == url.absoluteString else { return }
            record = result; image = result?.imageData.flatMap { UIImage(data: $0) }
            loadedURL = requestedURL; loading = false; onImageReady?(image != nil)
        }
    }
}

struct WebsitePreviewRecord: Codable, Sendable {
    let title: String?
    let imageData: Data?
    let fetchedAt: Date
    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < (imageData == nil ? 600 : 86_400) }
}

/// Coalesces card/detail requests and permits three independent source pages at once.
/// Failed previews are cached briefly, avoiding repeated requests while scrolling.
@MainActor final class WebsitePreviewStore {
    static let shared = WebsitePreviewStore()
    private var memory: [String: WebsitePreviewRecord] = [:]
    private var access: [String: Date] = [:]
    private var inFlight: [String: Task<WebsitePreviewRecord, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func preview(_ original: URL) async -> WebsitePreviewRecord? {
        guard let url = Self.publicURL(original) else { return nil }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        if let value = memory[key], value.isFresh { access[key] = Date(); return value }
        if let work = inFlight[key] { return await work.value }
        guard inFlight.count < 16 else { return nil }
        let work = Task { @MainActor in
            if let cached = await WebsitePreviewDisk.shared.read(key), cached.isFresh {
                remember(cached, key: key); return cached
            }
            await takeSlot()
            let result = await Self.fetch(url)
            releaseSlot()
            remember(result, key: key)
            await WebsitePreviewDisk.shared.write(result, key: key)
            return result
        }
        inFlight[key] = work
        let result = await work.value
        inFlight[key] = nil
        return result
    }
    private func remember(_ value: WebsitePreviewRecord, key: String) {
        memory[key] = value; access[key] = Date()
        var bytes = memory.values.reduce(0) { $0 + ($1.imageData?.count ?? 0) }
        for oldest in access.sorted(by: { $0.value < $1.value }).map(\.key) {
            guard memory.count > 48 || bytes > 16 * 1_024 * 1_024 else { break }
            bytes -= memory.removeValue(forKey: oldest)?.imageData?.count ?? 0; access[oldest] = nil
        }
    }
    private func takeSlot() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func releaseSlot() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
    private static func publicURL(_ value: URL) -> URL? {
        guard var parts = URLComponents(url: value, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), host.contains("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        return parts.url
    }
    private static func fetch(_ url: URL) async -> WebsitePreviewRecord {
        let provider = LPMetadataProvider(); provider.timeout = 6
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let raw = await metadata.imageProvider.mapAsyncPreview { await readImage($0) }
            let image = raw.flatMap { Self.thumbnail($0) }
            return WebsitePreviewRecord(title: metadata.title.map { String($0.prefix(300)) }, imageData: image, fetchedAt: Date())
        } catch {
            return WebsitePreviewRecord(title: nil, imageData: nil, fetchedAt: Date())
        }
    }
    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.72), jpeg.count <= 1_024 * 1_024 else { return nil }
        return jpeg
    }
    private static func readImage(_ provider: NSItemProvider) async -> Data? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return nil }
        let completion = PreviewImageCompletion()
        return await withCheckedContinuation { continuation in
            completion.install(continuation)
            completion.register(provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                completion.finish(data.flatMap { $0.count <= 8 * 1_024 * 1_024 ? $0 : nil })
            })
            Task {
                try? await Task.sleep(for: .seconds(3))
                completion.finish(nil)
            }
        }
    }
}

private final class PreviewImageCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var progress: Progress?
    private var finished = false
    func install(_ value: CheckedContinuation<Data?, Never>) {
        lock.lock(); continuation = value; lock.unlock()
    }
    func register(_ value: Progress) {
        lock.lock(); let complete = finished
        if !complete { progress = value }; lock.unlock()
        if complete { value.cancel() }
    }
    func finish(_ value: Data?) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let progress = self.progress; self.progress = nil
        lock.unlock(); progress?.cancel(); continuation?.resume(returning: value)
    }
}

private actor WebsitePreviewDisk {
    static let shared = WebsitePreviewDisk()
    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MynahWebsitePreviews", isDirectory: true)
    func read(_ key: String) -> WebsitePreviewRecord? {
        let url = root.appendingPathComponent(key + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_500_000, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WebsitePreviewRecord.self, from: data) else { return nil }
        return value
    }
    func write(_ value: WebsitePreviewRecord, key: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent(key + ".json"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .compactMap { url -> (URL, Date, Int)? in
                    guard let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                    return (url, info.contentModificationDate ?? .distantPast, info.fileSize ?? 0)
                }.sorted { $0.1 < $1.1 }
            var count = files.count; var bytes = files.reduce(0) { $0 + $1.2 }
            for file in files where count > 64 || bytes > 24 * 1_024 * 1_024 {
                try? FileManager.default.removeItem(at: file.0); count -= 1; bytes -= file.2
            }
        } catch { /* Previews are disposable; source content remains available. */ }
    }
}

private extension Optional {
    func mapAsyncPreview<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let value = self else { return nil }; return await transform(value)
    }
}
