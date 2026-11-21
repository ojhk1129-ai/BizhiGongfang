import CoreImage
import UIKit
import Vision

/// AI 主体抠图（构建 #25，Camlo 式“破框遮挡时钟”）：
/// 用 Vision 的 VNGenerateForegroundInstanceMaskRequest 对锁屏图生成主体 mask，
/// 再用 CIBlendWithAlphaMask 把主体抠出来（主体保留、背景透明），
/// 写进 Floating.ca，盖在锁屏时钟前面。
/// 找不到主体 / Vision 失败返回 nil，调用方跳过抠图（不报错）。
enum ForegroundCutout {

    /// 对一张照片做主体抠图，返回带透明通道的抠图。
    /// 先按 aspect-fill 裁成目标尺寸（默认 1080×1920，和 lock.jpg 完全对齐），
    /// 再在这张图上做 mask，抠出来的主体位置才和锁屏图一致。
    /// Vision 请求是同步的、比较耗时（约 0.5–2 秒），所以包在 detached Task 里跑，
    /// 不卡主线程；调用方用 await 等结果。
    static func cutoutForeground(
        from image: UIImage,
        size: CGSize = CGSize(width: 1080, height: 1920)
    ) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            cutoutSync(from: image, size: size)
        }.value
    }

    /// 同步抠图（在后台线程调用）。
    private static func cutoutSync(from image: UIImage, size: CGSize) -> UIImage? {
        // 先归一化（保证有 cgImage、方向 .up）再 aspect-fill 到目标尺寸。
        let flat = image.flattenedForDrawing()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let filled = renderer.image { _ in
            flat.draw(in: aspectFillRect(imageSize: flat.size, canvas: size))
        }
        guard let filledCG = filled.cgImage else { return nil }

        // Vision：生成前景 instance mask（取全部 instance 的并集——
        // 壁纸里有几个人就抠几个人，都遮挡时钟）。
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: filledCG, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNInstanceMaskObservation,
              !observation.allInstances.isEmpty else { return nil }
        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
        } catch {
            return nil
        }

        // 合成：mask 是灰度图，先用 CIMaskToAlpha 把亮度转成 alpha，
        // 再用 CIBlendWithAlphaMask 把原图按 mask 盖到透明背景上。
        var maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let foreground = CIImage(cgImage: filledCG)
        if maskImage.extent.size != foreground.extent.size {
            let sx = foreground.extent.width / max(1, maskImage.extent.width)
            let sy = foreground.extent.height / max(1, maskImage.extent.height)
            maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        let alphaMask = maskImage.applyingFilter("CIMaskToAlpha")
        let composited = foreground.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputMaskImageKey: alphaMask,
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: foreground.extent),
            ]
        )
        let context = CIContext()
        guard let outCG = context.createCGImage(composited, from: foreground.extent) else {
            return nil
        }
        return UIImage(cgImage: outCG)
    }

    /// aspect-fill 的绘制矩形（图片居中裁剪铺满 canvas）。
    private static func aspectFillRect(imageSize: CGSize, canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let drawWidth = imageSize.width * scale
        let drawHeight = imageSize.height * scale
        return CGRect(
            x: (canvas.width - drawWidth) / 2,
            y: (canvas.height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
    }
}
