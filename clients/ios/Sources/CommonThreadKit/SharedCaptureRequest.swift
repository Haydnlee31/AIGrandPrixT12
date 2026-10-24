import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// The shared service accepts a public link and/or one image. Native originals
/// remain untouched; unsupported content must stay local rather than be dropped.
public enum SharedCaptureRequest {
    public struct Attachment: Sendable {
        public let data: Data
        public let isImage: Bool
        public init(data: Data, isImage: Bool) { self.data = data; self.isImage = isImage }
    }
    public enum PreparationError: Error, LocalizedError {
        case unsupported, tooLong, invalidImage
        public var errorDescription: String? {
            switch self {
            case .unsupported: return "Shared saves support a link or one photo. Text-only finds, files and multiple attachments stay on this iPhone."
            case .tooLong: return "This find has more text than the shared library accepts. Shorten its title, text or notes, or keep it on this iPhone."
            case .invalidImage: return "This photo could not be prepared within the shared library’s image limit. Its original stays on this iPhone."
            }
        }
    }
    public static let defaultImageLimit = 3 * 1024 * 1024
    public static func supports(url: String?, attachments: [Attachment]) -> Bool {
        (!(url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.count == 1)
            && attachments.count <= 1 && attachments.allSatisfy(\.isImage)
    }
    public static func prepare(url: String?, title: String, text: String, note: String, intents: [String] = [],
                               source: CaptureSource = .web, client: CaptureClient,
                               attachments: [Attachment] = [], limits: Capabilities.CaptureLimits? = nil) throws -> CaptureRequest {
        let link = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard supports(url: link, attachments: attachments) else { throw PreparationError.unsupported }
        let combinedNote = ([note] + intents).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= (limits?.maxTitleLength ?? 300), link.count <= (limits?.maxUrlLength ?? 2048),
              text.count <= (limits?.maxSelectedTextLength ?? 12000), combinedNote.count <= (limits?.maxNoteLength ?? 2000) else { throw PreparationError.tooLong }
        let image = try attachments.first.map { try imageDataURL($0.data, maximumBytes: limits?.maxImageBytes ?? defaultImageLimit) }
        return CaptureRequest(url: link.isEmpty ? nil : link, title: title, source: source,
            selectedText: text, note: combinedNote, client: client, imageDataUrl: image)
    }
    public static func imageDataURL(_ original: Data, maximumBytes: Int) throws -> String {
        #if canImport(ImageIO)
        // Conservative Vercel request budget, even if an older server advertises 4 MB.
        let limit = min(maximumBytes, defaultImageLimit)
        guard limit > 0, let source = CGImageSourceCreateWithData(original as CFData, nil) else { throw PreparationError.invalidImage }
        for pixels in [1600, 1200, 900, 600, 300, 128, 64, 32] {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ] as CFDictionary) else { throw PreparationError.invalidImage }
            let jpeg = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw PreparationError.invalidImage }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination), jpeg.length <= limit {
                return "data:image/jpeg;base64," + (jpeg as Data).base64EncodedString()
            }
        }
        #endif
        throw PreparationError.invalidImage
    }
}
