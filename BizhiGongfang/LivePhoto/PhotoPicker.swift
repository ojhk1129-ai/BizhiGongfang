import CoreImage
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

/// 从 PHPicker 结果里取一张 UIImage（已按照片方向转正）。
func loadPickedImage(from result: PHPickerResult, completion: @escaping (UIImage?) -> Void) {
    let provider = result.itemProvider
    guard provider.canLoadObject(ofClass: UIImage.self) else {
        completion(nil)
        return
    }
    provider.loadObject(ofClass: UIImage.self) { object, _ in
        let image = (object as? UIImage)?.flattenedForDrawing()
        DispatchQueue.main.async {
            completion(image)
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

extension UIImage {
    /// 把照片的方向信息画进像素里，避免之后用 cgImage 绘制时方向错乱。
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(at: .zero)
        }
    }

    /// 归一化成“一定能画”的图：保证有 cgImage、方向 .up。
    /// 构建 #23（2026-11-20）：PHPicker 拿回来的 UIImage 可能是 CIImage
    /// backing（cgImage == nil），image.draw(in:) 在 CGContext（视频像素
    /// 缓冲、预览渲染）里画不出来，静默变黑；而 SwiftUI 的缩略图能显示它。
    /// 实测：B 槽放已知的好照片 A 也黑（2026-11-20 21:51 CST），证明不是
    /// 照片坏了，是第二张图画不出来。选图时归一化一次，之后预览、视频、
    /// Live Photo、注入都用这张图。
    func flattenedForDrawing() -> UIImage {
        // 已经是 CGImage-backed 且方向正，直接用。
        if ciImage == nil, cgImage != nil, imageOrientation == .up {
            return self
        }
        // CIImage backing → 先用 CIContext 烤成 CGImage。
        var base = self
        if let ciImage = ciImage {
            if let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) {
                base = UIImage(cgImage: cgImage, scale: scale, orientation: imageOrientation)
            }
        }
        // 再把方向烤进像素，并保证结果有 cgImage。
        let oriented = base.normalizedOrientation()
        if let cgImage = oriented.cgImage {
            return UIImage(cgImage: cgImage, scale: oriented.scale, orientation: .up)
        }
        return oriented
    }
}
