import CoreImage
import UIKit

/// 粒子样式（构建 #27）：贴图层 + CAML 动画，不是真的 CAEmitterLayer，
/// Camlo 就是这么做的（它的粒子素材是 particle_aurora_silk_a.png、
/// particle_sunbeam_veil.png）。
enum ParticleStyle: String, CaseIterable {
    case none   // 无
    case stream // 流光
    case rain   // 雨
    case snow   // 雪

    var displayName: String {
        switch self {
        case .none: return "无"
        case .stream: return "流光"
        case .rain: return "雨"
        case .snow: return "雪"
        }
    }

    /// 粒子贴图在 Floating.ca/assets 里的文件名。
    var assetFileName: String {
        switch self {
        case .none: return ""
        case .stream: return "particle.png"
        case .rain: return "rain.png"
        case .snow: return "snow.png"
        }
    }
}

/// 滤镜色调（构建 #27）：CoreImage 滤镜，做描述符之前套在图上。
enum WallpaperFilter: String, CaseIterable {
    case none    // 无
    case warm    // 暖阳
    case cool    // 冷月
    case vintage // 复古
    case mono    // 黑白
    case vivid   // 鲜艳

    var displayName: String {
        switch self {
        case .none: return "无"
        case .warm: return "暖阳"
        case .cool: return "冷月"
        case .vintage: return "复古"
        case .mono: return "黑白"
        case .vivid: return "鲜艳"
        }
    }
}

/// 一组特效开关（构建 #27）：粒子 + 环境浮动 + 缓慢缩放 + 滤镜。
/// 特效分两类：
/// - 图层类（粒子、浮动、缩放）：写进 .ca 包的 CAML，是独立图层，和底下
///   是照片还是视频无关，所以视频壁纸一样能用。
/// - 滤镜类：做描述符之前套在图上；变身/景深是给源图套一次，视频是抽帧时
///   逐帧套。
/// 传给 DescriptorBuilder / InjectFlow / TendiesExporter，全都有默认值，
/// 老调用不用改。Equatable 供编辑器的 onChange(of: effects) 用。
struct WallpaperEffects: Equatable {
    var particle: ParticleStyle = .none
    var ambient: Bool = false
    var slowZoom: Bool = false
    var filter: WallpaperFilter = .none

    /// 四个全关时为 true，调用方用来跳过特效。
    var isEmpty: Bool {
        particle == .none && !ambient && !slowZoom && filter == .none
    }

    // MARK: - 滤镜

    /// 共享 CIContext（建一个很贵，复用；CIContext 是线程安全的）。
    private static let ciContext = CIContext()

    /// 给一张 CIImage 套滤镜（返回过滤后的 CIImage；.none 返回原图）。
    /// 供视频预览的 AVVideoComposition 和逐帧滤镜共用。
    static func filteredCIImage(_ image: CIImage, filter: WallpaperFilter) -> CIImage {
        switch filter {
        case .none:
            return image
        case .warm:
            // 目标色温低 = 偏暖（4500K 偏橙）；中性白点 6500K。
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 4500, y: 0)
            ])
        case .cool:
            // 目标色温高 = 偏冷（8500K 偏蓝）。
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 8500, y: 0)
            ])
        case .vintage:
            // 复古：棕褐 0.6 + 暗角。
            let sepia = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.6])
            return sepia.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 1.0,
                kCIInputRadiusKey: 1.5
            ])
        case .mono:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .vivid:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.4,
                kCIInputContrastKey: 1.15,
                kCIInputBrightnessKey: 0.0
            ])
        }
    }

    /// 给 UIImage 套滤镜（.none 返回原图；失败返回原图）。
    /// 方向保留（用原图的 scale 和 orientation 重建）。
    static func apply(_ filter: WallpaperFilter, to image: UIImage) -> UIImage {
        guard filter != .none, let cgImage = image.cgImage else { return image }
        let filtered = apply(filter, to: cgImage)
        return UIImage(cgImage: filtered, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 给 CGImage 套滤镜（.none 返回原图；失败返回原图）。
    /// 供视频抽帧逐帧套滤镜用。
    static func apply(_ filter: WallpaperFilter, to cgImage: CGImage) -> CGImage {
        guard filter != .none else { return cgImage }
        let input = CIImage(cgImage: cgImage)
        let output = filteredCIImage(input, filter: filter)
        return ciContext.createCGImage(output, from: input.extent) ?? cgImage
    }

    // MARK: - 粒子 / 光晕贴图（运行时现画，不往仓库里传图片文件）

    /// 粒子贴图：流光/雪是 64×64 柔和圆点（白色径向渐变，中心亮、边缘透明）；
    /// 雨是 8×64 细竖条（白色竖向渐变）。返回 PNG Data；none 返回 nil。
    static func particleImage(for style: ParticleStyle) -> Data? {
        switch style {
        case .none:
            return nil
        case .stream, .snow:
            return radialGlowImage(size: 64, stops: [(0, 1.0), (0.4, 0.4), (1, 0)])
        case .rain:
            return rainStreakImage()
        }
    }

    /// 环境浮动的光晕贴图：512×512 大号径向渐变（中心亮白、边缘透明），返回 PNG Data。
    static func glowImage() -> Data? {
        radialGlowImage(size: 512, stops: [(0, 0.9), (0.5, 0.45), (1, 0)])
    }

    /// 径向渐变圆（stops 是 (位置 0...1, 透明度) 的列表）。
    private static func radialGlowImage(size: CGFloat, stops: [(CGFloat, CGFloat)]) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { context in
            let ctx = context.cgContext
            let colors = stops.map { UIColor(white: 1, alpha: $0.1).cgColor } as CFArray
            let locations = stops.map { $0.0 }
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) else { return }
            let center = CGPoint(x: size / 2, y: size / 2)
            ctx.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size / 2,
                options: []
            )
        }
        return image.pngData()
    }

    /// 雨丝：8×64 细竖条，白色竖向渐变（两头透明、中间亮）。
    private static func rainStreakImage() -> Data? {
        let size = CGSize(width: 8, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let ctx = context.cgContext
            let colors = [
                UIColor(white: 1, alpha: 0).cgColor,
                UIColor(white: 1, alpha: 0.9).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0, 0.5, 1]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) else { return }
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: size.width / 2, y: 0),
                end: CGPoint(x: size.width / 2, y: size.height),
                options: []
            )
        }
        return image.pngData()
    }
}
