import Foundation
import Photos

/// 把静态图 JPEG + 视频 MOV 作为一对 Live Photo 保存到相册。
enum LivePhotoExporter {

    enum ExportError: LocalizedError {
        case writeFailed
        case photoAccessDenied

        var errorDescription: String? {
            switch self {
            case .writeFailed: return "无法写入临时文件"
            case .photoAccessDenied: return "没有相册保存权限，请在「设置 → 壁纸工坊」里打开相册权限"
            }
        }
    }

    /// 保存成功后告诉用户的话。
    static let successMessage = """
    已保存到相册！

    去「照片」打开这张 Live Photo → 点分享 → 「设为墙纸」→ 打开 Live Photo，设为锁屏壁纸后，按压屏幕或解锁时就会播放。
    """

    /// 保存 Live Photo。completion 在任意队列回调，调用方要自己切回主线程更新界面。
    static func save(
        stillJPEGData: Data,
        videoURL: URL,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        let jpegURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try stillJPEGData.write(to: jpegURL)
        } catch {
            completion(false, ExportError.writeFailed)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                completion(false, ExportError.photoAccessDenied)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: jpegURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            }, completionHandler: { success, error in
                completion(success, error)
            })
        }
    }
}
