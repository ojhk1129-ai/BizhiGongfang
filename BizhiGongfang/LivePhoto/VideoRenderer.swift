import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import UIKit

/// 用 AVAssetWriter 逐帧绘制生成 H.264 MOV（1080x1920，30fps），
/// 并写入 Live Photo 配对元数据。
enum VideoRenderer {

    static let outputSize = CGSize(width: 1080, height: 1920)
    static let framesPerSecond: Int32 = 30
    static let duration: TimeInterval = 3.0

    /// 画一帧：context 已是 UIKit 坐标（原点在左上角），canvas 是画布大小，
    /// time 是这一帧在视频里的时刻（0...3 秒）。
    typealias FrameDrawer = (CGContext, CGSize, TimeInterval) -> Void

    enum RenderError: LocalizedError {
        case cannotAddInput
        case metadataTrackFailed
        case pixelBufferFailed
        case appendFailed(Error?)
        case writeFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "无法添加视频输入"
            case .metadataTrackFailed: return "无法创建元数据轨道"
            case .pixelBufferFailed: return "无法创建视频帧"
            case .appendFailed(let error): return "写入视频帧失败：\(error?.localizedDescription ?? "未知错误")"
            case .writeFailed(let error): return "视频写入失败：\(error?.localizedDescription ?? "未知错误")"
            }
        }
    }

    /// 按 drawer 画一帧静态图（用于预览和静态图）。
    static func renderStill(size: CGSize, at time: TimeInterval, drawer: FrameDrawer) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            drawer(ctx, size, time)
        }
    }

    /// 把图片按 aspect fill 画到 context 里，可整体缩放和平移。
    /// 坐标是 UIKit 坐标（原点左上角），由调用方保证 context 已经是这个方向。
    /// 注意：必须用 UIImage.draw，不能用 context.draw(cgImage) —— 后者在翻转过的
    /// UIKit 坐标 context 里会把图画成上下颠倒的。图片进来时方向已经转正过，
    /// 所以用 image.size 算比例和用 cgImage 的像素尺寸是一回事。
    static func drawAspectFill(
        _ image: UIImage,
        in context: CGContext,
        canvas: CGSize,
        scale: CGFloat = 1.0,
        offset: CGPoint = .zero,
        alpha: CGFloat = 1.0
    ) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let canvasAspect = canvas.width / canvas.height
        let imageAspect = imageSize.width / imageSize.height
        var drawWidth: CGFloat
        var drawHeight: CGFloat
        if imageAspect > canvasAspect {
            drawHeight = canvas.height
            drawWidth = drawHeight * imageAspect
        } else {
            drawWidth = canvas.width
            drawHeight = drawWidth / imageAspect
        }
        drawWidth *= scale
        drawHeight *= scale
        let rect = CGRect(
            x: (canvas.width - drawWidth) / 2 + offset.x,
            y: (canvas.height - drawHeight) / 2 + offset.y,
            width: drawWidth,
            height: drawHeight
        )
        context.saveGState()
        context.setAlpha(alpha)
        image.draw(in: rect)
        context.restoreGState()
    }

    /// 生成 3 秒 MOV。identifier 会写进视频的顶层元数据；
    /// stillImageTime 会写进定时元数据轨道（样本时间戳就是静态图时刻）。
    /// completion 在任意队列回调，调用方要自己切回主线程更新界面。
    static func renderVideo(
        identifier: String,
        stillImageTime: TimeInterval,
        drawer: @escaping FrameDrawer,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let size = outputSize
        let fps = framesPerSecond
        let totalFrames = Int(duration * Double(fps))

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            completion(.failure(error))
            return
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(videoInput) else {
            completion(.failure(RenderError.cannotAddInput))
            return
        }
        writer.add(videoInput)

        guard let (metadataInput, metadataAdaptor) = LivePhotoMetadata.makeStillImageTimeTrack() else {
            completion(.failure(RenderError.metadataTrackFailed))
            return
        }
        guard writer.canAdd(metadataInput) else {
            completion(.failure(RenderError.cannotAddInput))
            return
        }
        writer.add(metadataInput)

        writer.metadata = [LivePhotoMetadata.contentIdentifierItem(identifier)]

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // 写 still-image-time 样本（时间戳就是静态图时刻）
        _ = metadataAdaptor.append(LivePhotoMetadata.stillImageTimeGroup(at: stillImageTime))

        let queue = DispatchQueue(label: "com.wallpaperstudio.video.render")
        var frameIndex = 0
        var didFinish = false

        videoInput.requestMediaDataWhenReady(on: queue) {
            while videoInput.isReadyForMoreMediaData && frameIndex < totalFrames {
                let time = TimeInterval(frameIndex) / TimeInterval(fps)
                let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                guard let pixelBuffer = makePixelBuffer(size: size, time: time, drawer: drawer) else {
                    if !didFinish {
                        didFinish = true
                        videoInput.markAsFinished()
                        writer.cancelWriting()
                        completion(.failure(RenderError.pixelBufferFailed))
                    }
                    return
                }
                if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                    if !didFinish {
                        didFinish = true
                        videoInput.markAsFinished()
                        writer.cancelWriting()
                        completion(.failure(RenderError.appendFailed(writer.error)))
                    }
                    return
                }
                frameIndex += 1
            }
            if frameIndex >= totalFrames && !didFinish {
                didFinish = true
                videoInput.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        completion(.success(outputURL))
                    } else {
                        completion(.failure(RenderError.writeFailed(writer.error)))
                    }
                }
            }
        }
    }

    /// 画一帧到 CVPixelBuffer。context 先翻转为 UIKit 坐标，
    /// 和预览、静态图的画法保持一致。
    private static func makePixelBuffer(size: CGSize, time: TimeInterval, drawer: FrameDrawer) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        drawer(context, size, time)
        return buffer
    }
}
