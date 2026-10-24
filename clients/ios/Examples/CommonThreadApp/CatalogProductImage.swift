import SwiftUI
import ImageIO

struct CatalogProductImage: View {
    let url: URL?
    let height: CGFloat
    var fit: Bool = false
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @State private var failed = false
    @State private var attempt = 0
    @State private var requestID = UUID()

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let image, loadedURL == url {
                    Color.white.overlay {
                        if fit { Image(uiImage: image).resizable().scaledToFit().padding(12) }
                        else { Image(uiImage: image).resizable().scaledToFill() }
                    }.accessibilityLabel("Product photo")
                } else if url == nil {
                    placeholder("Photo unavailable", symbol: "photo")
                } else if failed {
                    VStack(spacing: 10) {
                        placeholder("Photo couldn’t load", symbol: "photo")
                        Button { attempt += 1 } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            .font(.caption.bold()).buttonStyle(.bordered)
                    }
                } else {
                    ProgressView().tint(.secondary).accessibilityLabel("Loading product photo")
                }
            }
            .frame(maxWidth: .infinity).frame(height: height).clipped()
            .task(id: "\(url?.absoluteString ?? "none")|\(attempt)") { await load(url) }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(text).font(.caption.weight(.medium)).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).padding(.horizontal, 10)
    }

    @MainActor private func load(_ requestedURL: URL?) async {
        // An old task may enter after a newer view request has already begun.
        guard !Task.isCancelled, requestedURL == url else { return }
        let ownership = UUID(); requestID = ownership
        image = nil; loadedURL = nil; failed = false
        guard let requestedURL else { return }
        do {
            let data = try await CatalogImageLoader.shared.data(for: requestedURL)
            try Task.checkCancellation()
            guard requestedURL == url, requestID == ownership else { return }
            // Bound decoded memory too; catalog sources can supply very large
            // original images even when their compressed response is small.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                CatalogImageLoader.shared.discard(requestedURL)
                failed = true
                return
            }
            image = UIImage(cgImage: cg); loadedURL = requestedURL
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, requestedURL == url, requestID == ownership else { return }
            failed = true
        }
    }
}
