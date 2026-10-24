import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct DraftAttachment: Identifiable {
    let id = UUID()
    let value: LocalCaptureAttachment
    var preview: UIImage? { value.typeIdentifier == UTType.jpeg.identifier ? UIImage(data: value.data) : nil }
}
enum CaptureMedia {
    static func image(_ data: Data, name: String = "Photo.jpg") throws -> LocalCaptureAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.82),
              jpeg.count <= 4 * 1024 * 1024 else { throw LocalLibrary.LocalError.invalidMedia }
        // Rendering into a new JPEG applies orientation and drops location/EXIF metadata.
        return LocalCaptureAttachment(filename: (name as NSString).deletingPathExtension + ".jpg", typeIdentifier: UTType.jpeg.identifier, data: jpeg)
    }
    static func file(_ url: URL) throws -> LocalCaptureAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 12 * 1024 * 1024 else { throw LocalLibrary.LocalError.mediaTooLarge }
        let data = try Data(contentsOf: url)
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) { return try image(data, name: url.lastPathComponent) }
        return LocalCaptureAttachment(filename: url.lastPathComponent, typeIdentifier: type.identifier, data: data)
    }
}
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
