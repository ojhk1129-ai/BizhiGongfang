import AVFoundation
import CoreGraphics
import SwiftUI
import UIKit

/// Drift 风格渐变壁纸（构建 #31）：在 App 内生成一段 12 秒渐变动画视频，
/// 再走现成的视频写入/导出流程（和视频壁纸同一条路：裁剪 → 抽帧 → 注入）。
/// 注意：锁屏壁纸是写死的一组帧，不会自己联网跟天气/时间变；
/// 这里是“打开 App 时按当前天气/时间生成一张”，想换就重新生成一张。
enum GradientRenderer {

    /// 渐变视频：12 秒，12 fps → 144 帧（DescriptorBuilder 自适应抽帧上限
    /// 是 150 帧，144 帧正好全取，不用再抽稀）。
    static let duration: Double = 12.0
    static let fps: Int = 12
    static let outputWidth = 1080
    static let outputHeight = 2338

    enum RenderError: LocalizedError {
        case cannotCreateWriter(Error?)
        case cannotAddInput
        case noPixelBufferPool
        case pixelBufferFailed
        case appendFailed(Error?)
        case writeFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let error): return "渐变视频创建失败：\(error?.localizedDescription ?? "未知错误")"
            case .cannotAddInput: return "渐变视频无法添加画面轨道"
            case .noPixelBufferPool: return "渐变视频没有像素缓冲池"
            case .pixelBufferFailed: return "渐变视频帧缓冲创建失败"
            case .appendFailed(let error): return "渐变视频帧写入失败：\(error?.localizedDescription ?? "未知错误")"
            case .writeFailed(let error): return "渐变视频写入失败：\(error?.localizedDescription ?? "未知错误")"
            }
        }
    }

    /// 一套配色：4 个颜色（渐变用）。
    struct Palette: Identifiable, Equatable {
        let id: String
        let name: String
        /// 4 个十六进制颜色。
        let hexes: [String]

        var uiColors: [UIColor] {
            hexes.map { UIColor(hex: $0) }
        }

        var swiftUIColors: [Color] {
            hexes.map { Color(UIColor(hex: $0)) }
        }
    }

    /// 9 套配色（照 Drift 的思路：按时间/天气分）。
    static let palettes: [Palette] = [
        Palette(id: "dawn", name: "晨曦", hexes: ["#FFB75E", "#FF7E9D", "#B388FF", "#6A5CFF"]),
        Palette(id: "sky", name: "晴空", hexes: ["#7DD3FC", "#38BDF8", "#818CF8", "#C084FC"]),
        Palette(id: "dusk", name: "黄昏", hexes: ["#FB923C", "#F472B6", "#A855F7", "#6366F1"]),
        Palette(id: "night", name: "星夜", hexes: ["#1E1B4B", "#312E81", "#7C3AED", "#DB2777"]),
        Palette(id: "rain", name: "雨天", hexes: ["#475569", "#64748B", "#38BDF8", "#0EA5E9"]),
        Palette(id: "snow", name: "雪天", hexes: ["#E0E7FF", "#C7D2FE", "#93C5FD", "#FFFFFF"]),
        Palette(id: "ocean", name: "海洋", hexes: ["#06B6D4", "#0891B2", "#2563EB", "#1E40AF"]),
        Palette(id: "forest", name: "森林", hexes: ["#4ADE80", "#22C55E", "#059669", "#065F46"]),
        Palette(id: "sakura", name: "樱花", hexes: ["#FDA4AF", "#F9A8D4", "#F0ABFC", "#C4B5FD"]),
    ]

    /// 天气（手动选）：每种天气推荐一套配色。
    enum Weather: String, CaseIterable, Identifiable {
        case sunny = "晴"
        case cloudy = "多云"
        case rainy = "雨"
        case snowy = "雪"

        var id: String { rawValue }

        var paletteID: String {
            switch self {
            case .sunny: return "sky"
            case .cloudy: return "dawn"
            case .rainy: return "rain"
            case .snowy: return "snow"
            }
        }
    }

    /// 当前时段（按钟点）：清晨 / 白天 / 黄昏 / 夜晚。
    static func currentPeriodName() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<8: return "清晨"
        case 8..<17: return "白天"
        case 17..<19: return "黄昏"
        default: return "夜晚"
        }
    }

    /// 按当前时段推荐的配色。
    static func paletteForCurrentTime() -> Palette {
        let hour = Calendar.current.component(.hour, from: Date())
        let id: String
        switch hour {
        case 5..<8: id = "dawn"
        case 8..<17: id = "sky"
        case 17..<19: id = "dusk"
        default: id = "night"
        }
        return palettes.first { $0.id == id } ?? palettes[1]
    }

    /// 生成渐变动画视频（.mov，H.264），返回文件地址。
    static func renderVideo(palette: Palette) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradient-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw RenderError.cannotCreateWriter(error)
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        guard writer.canAdd(input) else { throw RenderError.cannotAddInput }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(duration * Double(fps))
        for frameIndex in 0..<totalFrames {
            let time = Double(frameIndex) / Double(fps)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw RenderError.writeFailed(writer.error)
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard writer.status != .failed else {
                throw RenderError.writeFailed(writer.error)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw RenderError.noPixelBufferPool
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw RenderError.pixelBufferFailed
            }
            drawGradient(into: buffer, palette: palette, time: time)
            let presentationTime = CMTime(seconds: time, preferredTimescale: 600)
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw RenderError.appendFailed(writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.writeFailed(writer.error)
        }
        return outputURL
    }

    /// 把一帧渐变画进像素缓冲。12 秒一个完整周期（首尾相接，锁屏循环播放不断档）。
    /// 画两层：对角线性渐变（角度和色标缓慢摆动）+ 一个亮色光晕（沿慢速圆周漂移）。
    private static func drawGradient(into pixelBuffer: CVPixelBuffer, palette: Palette, time: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let phase = time / duration * 2.0 * Double.pi
        let colors = palette.uiColors.map { $0.cgColor }

        // 背景：最深的那个颜色打底。
        ctx.setFillColor(colors.last ?? UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 对角线性渐变：角度在 ±25° 间摆动，色标位置轻微漂移。
        let baseAngle = Double.pi * 0.75
        let angle = baseAngle + 0.44 * sin(phase)
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = sqrt(cx * cx + cy * cy)
        let startPoint = CGPoint(x: cx - radius * CGFloat(cos(angle)), y: cy - radius * CGFloat(sin(angle)))
        let endPoint = CGPoint(x: cx + radius * CGFloat(cos(angle)), y: cy + radius * CGFloat(sin(angle)))
        let baseLocations: [CGFloat] = [0, 0.35, 0.7, 1.0]
        let locations = baseLocations.enumerated().map { index, base in
            min(1.0, max(0.0, base + 0.06 * CGFloat(sin(phase + Double(index) * 1.3))))
        }
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) {
            ctx.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
        }

        // 亮色光晕：最亮的颜色，沿慢速圆周漂移，低透明度。
        let glowColor = palette.uiColors.first ?? .white
        let glowX = cx + 0.28 * size.width * CGFloat(cos(phase * 0.9))
        let glowY = cy + 0.28 * size.height * CGFloat(sin(phase * 0.9))
        let glowRadius = 0.55 * max(size.width, size.height)
        if let glow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [glowColor.withAlphaComponent(0.35).cgColor, glowColor.withAlphaComponent(0.0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: glowX, y: glowY), startRadius: 0,
                endCenter: CGPoint(x: glowX, y: glowY), endRadius: glowRadius,
                options: []
            )
        }
    }
}

private extension UIColor {
    /// "#RRGGBB" 转 UIColor（解析失败时返回黑色）。
    convenience init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
