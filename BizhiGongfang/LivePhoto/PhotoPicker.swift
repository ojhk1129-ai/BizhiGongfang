import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 相册选择器（PHPicker）的 SwiftUI 封装。
struct PhotoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let filter: PHPickerFilter
    let limit: Int
    let onComplete: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = filter
        configuration.selectionLimit = limit
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotoPicker

        init(parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            parent.onComplete(results)
        }
    }
}

/// 从 PHPicker 结果里取一段视频，复制到临时目录后返回。
func loadPickedVideoURL(from result: PHPickerResult, completion: @escaping (URL?) -> Void) {
    let provider = result.itemProvider
    let typeIdentifier = UTType.movie.identifier
    guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
        completion(nil)
        return
    }
    provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
        guard let url = url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            DispatchQueue.main.async { completion(destination) }
        } catch {
            DispatchQueue.main.async { completion(nil) }
        }
    }
}