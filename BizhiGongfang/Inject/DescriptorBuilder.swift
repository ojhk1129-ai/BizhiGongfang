import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import UIKit

/// 描述符生成：把一段 MOV 抽帧，做成 PosterBoard 锁屏画廊能认的描述符文件夹。
///
/// 格式照 Placard 的 VideoWallpaper.swift（GPL-3.0，见 README）自己实现：
/// 描述符文件夹里是 Wallpaper.plist + 背景 .ca 包（main.caml 逐帧 JPEG 动画 +
/// index.xml）+ 前景空白 .ca 包 + providerInfo.plist + userInfo + 两个 identifier 文件。
/// identifier 用 Camlo 的递减 ID（从 19999 开始每次减 1，用到 10100 后回到
/// 19999，见 nextDescendingIdentifier），三处同步写（见 makeDescriptorMetadata）。
/// 递减 ID 让新壁纸在 Collections 里排在前面。
enum DescriptorBuilder {

    enum BuildError: LocalizedError {
        case invalidVideo
        case noVideoTrack
        case frameEncodingFailed
        case writeFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .invalidVideo: return "视频读不出来"
            case .noVideoTrack: return "视频里没有画面轨道"
            case .frameEncodingFailed: return "抽帧失败"
            case .writeFailed(let error): return "写描述符失败：\(error?.localizedDescription ?? "未知错误")"
            }
        }
    }

    /// 变身动画曲线（构建 #25，Camlo 式变身动画）。
    /// 每条曲线定义 CALayer2 的动画属性（keyPath + Locked/Unlock 目标值）+
    /// 时长 + 缓动；twoStateCAML 和 MorphEditorView 的预览 drawer 共用。
    /// 注意：不含丝滑叠化（= 交叉淡化，已删）。
    enum MorphCurve: String, CaseIterable {
        case revealUp   // 上滑揭幕
        case awaken     // 破屏觉醒
        case flash      // 圣光瞬变

        var displayName: String {
            switch self {
            case .revealUp: return "上滑揭幕"
            case .awaken: return "破屏觉醒"
            case .flash: return "圣光瞬变"
            }
        }

        /// 过渡时长（秒）。
        var duration: Double {
            switch self {
            case .revealUp: return 0.6
            case .awaken: return 0.8
            case .flash: return 0.15
            }
        }

        /// 缓动函数（CAML timingFunction 名）。
        var timingFunction: String {
            switch self {
            case .revealUp, .awaken: return "easeInEaseOut"
            case .flash: return "linear"
            }
        }

        /// 动画属性：(keyPath, Locked 态值, Unlock 态值)。
        /// position.y 的值随帧尺寸算，所以用函数而不是计算属性。
        func animatedProperties(width: Int, height: Int) -> [(keyPath: String, locked: String, unlocked: String)] {
            let cy = height / 2
            switch self {
            case .revealUp:
                // B 从底部向上滑入：Locked 时 y 在屏外下方，Unlock 时回中心。
                return [("position.y", "\(cy + height)", "\(cy)")]
            case .awaken:
                // B 从小放大 + 淡入：Locked 时缩 0.6 倍且透明，Unlock 时原大不透明。
                return [("transform.scale", "0.6", "1"), ("opacity", "0", "1")]
            case .flash:
                // B 瞬间出现：只有不透明度 0→1，0.15 秒无缓动。
                return [("opacity", "0", "1")]
            }
        }

        /// CALayer2 在 CAML 里的初始属性（即 Locked 态的样子）。
        /// transform 为 nil 表示不写 transform 属性（单位矩阵）。
        func initialLayerState(width: Int, height: Int) -> (position: String, opacity: String, transform: String?) {
            let cx = width / 2
            let cy = height / 2
            switch self {
            case .revealUp:
                return ("\(cx) \(cy + height)", "1", nil)
            case .awaken:
                // 初始缩 0.6 倍 + 透明；transform 是 16 个数的 CATransform3D。
                return ("\(cx) \(cy)", "0", "0.6 0 0 0 0 0.6 0 0 0 0 1 0 0 0 0 1")
            case .flash:
                return ("\(cx) \(cy)", "0", nil)
            }
        }
    }

    /// 抽帧帧率：3 秒视频 → 45 帧，在 PosterBoard 的安全区内（Camlo 建议最多 150 帧）。
    static let outputFrameRate: Double = 15
    /// 帧长边上限（像素），和 Placard 一致。
    static let maximumLongEdge: CGFloat = 1920
    /// 帧 JPEG 质量，和 Placard 一致。
    static let jpegQuality: CGFloat = 0.7

    static let providerID = "com.apple.WallpaperKit.CollectionsPoster"
    /// 构建 #24（2026-11-21，Camlo 对照）：模板改 iPhone 类 + 3 个 .ca 包。
    /// 原先是 iPad 类（810w-1080h@2x~ipad）+ 2 包（Background/Floating），
    /// Camlo v1.3.0 用 iPhone 类（390w-844h@3x~iphone）+ 3 包
    /// （Background/Floating/Foreground），且它的壁纸能在画廊列出。
    /// 标识仍用我们自己的 9183（Custom），不冒用苹果 7400。
    static let wallpaperFileName = "9183.Custom-390w-844h@3x~iphone.wallpaper"
    static let backgroundFileName = "9183.Custom_Background-390w-844h@3x~iphone.ca"
    static let floatingFileName = "9183.Custom_Floating-390w-844h@3x~iphone.ca"
    static let foregroundFileName = "9183.Custom_Foreground-390w-844h@3x~iphone.ca"
    /// 昼夜双生（构建 #25）：夜间 Dark 变体的 3 个 .ca 包，照 Camlo 的
    /// 7401 WWDC_2022_Dark 变体思路。只在有夜图时写，Wallpaper.plist 里
    /// 的 lockAndHome 加一个 "dark" 入口指向它们（见 makeDescriptorMetadata）。
    static let darkBackgroundFileName = "9183.Custom_Dark_Background-390w-844h@3x~iphone.ca"
    static let darkFloatingFileName = "9183.Custom_Dark_Floating-390w-844h@3x~iphone.ca"
    static let darkForegroundFileName = "9183.Custom_Dark_Foreground-390w-844h@3x~iphone.ca"

    /// 从 MOV 生成一个描述符文件夹（放在 workspace 里），返回文件夹地址。
    /// 调用方负责把文件夹写进 PosterBoard 后清理 workspace。
    /// 输出尺寸强制设备原生竖屏（见 devicePortraitOutputSize），不跟源视频走。
    static func buildDescriptor(
        from videoURL: URL,
        in workspace: URL
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw BuildError.invalidVideo
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BuildError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        guard transformedRect.width > 0, transformedRect.height > 0, nominalFrameRate > 0 else {
            throw BuildError.invalidVideo
        }
        let outputSize = await devicePortraitOutputSize()
        let outputFrameRate = min(Double(nominalFrameRate), outputFrameRate)

        let identifier = nextDescendingIdentifier()
        let descriptorURL = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wallpaperURL = descriptorURL
            .appendingPathComponent("versions/1/contents/\(wallpaperFileName)", isDirectory: true)
        let animationURL = wallpaperURL.appendingPathComponent(backgroundFileName, isDirectory: true)
        let assetsURL = animationURL.appendingPathComponent("assets", isDirectory: true)
        let floatingURL = wallpaperURL.appendingPathComponent(floatingFileName, isDirectory: true)
        let foregroundURL = wallpaperURL.appendingPathComponent(foregroundFileName, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: floatingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: foregroundURL, withIntermediateDirectories: true)

        let frameNames = try await extractFrames(
            asset: asset,
            track: track,
            preferredTransform: preferredTransform,
            outputSize: outputSize,
            outputFrameRate: outputFrameRate,
            to: assetsURL
        )
        guard !frameNames.isEmpty else { throw BuildError.invalidVideo }

        try makeDescriptorMetadata(
            at: descriptorURL,
            identifier: identifier,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        try caml(
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            frameNames: frameNames,
            duration: durationSeconds,
            autoReverses: false
        ).write(to: animationURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: Int(outputSize.width), height: Int(outputSize.height))
            .write(to: animationURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: floatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: floatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: foregroundURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: foregroundURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try seedDescriptorFiles(at: descriptorURL, animationURL: animationURL, floatingURL: floatingURL, foregroundURL: foregroundURL)
        return descriptorURL
    }

    /// 给诊断用的最小描述符：只有 1 帧纯色图，不需要视频。
    /// 用来验证"逃逸 + 写入"本身通不通，跑通了再做真视频。
    static func buildMinimalDescriptor(in workspace: URL) throws -> URL {
        let size = CGSize(width: 1080, height: 1920)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.1, green: 0.15, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            throw BuildError.frameEncodingFailed
        }
        return try buildSingleFrameDescriptor(jpeg: jpeg, size: size, in: workspace)
    }

    /// 单帧真照片描述符（判别实验，排障报告 4 第十节）：和最小描述符走
    /// 完全相同的路径，只把那一帧纯蓝 JPEG 换成给定的真照片
    /// （aspect-fill 裁成 size，JPEG 0.7）。
    /// 探针 A 用 1080×1920（与最小测试只差帧内容），探针 B 用 886×1920
    /// （与视频只差帧数）。
    static func buildSinglePhotoDescriptor(image: UIImage, size: CGSize, in workspace: URL) throws -> URL {
        guard let jpeg = aspectFillJPEG(image: image, size: size) else {
            throw BuildError.frameEncodingFailed
        }
        return try buildSingleFrameDescriptor(jpeg: jpeg, size: size, in: workspace)
    }

    /// 把一张照片按 aspect-fill（居中裁剪）裁成目标尺寸，存成 JPEG 0.7。
    /// 用 UIImage.draw(in:)：UIKit 翻转上下文里方向正确（见 VideoRenderer
    /// 的倒置修复，context.draw(cgImage) 会把图画成上下颠倒的）。
    /// 渲染格式的 scale 固定为 1：输出像素尺寸就是 size 本身，不跟屏幕倍率走
    /// （探针 B 必须是正好 886×1920，不能是 3 倍）。
    private static func aspectFillJPEG(image: UIImage, size: CGSize) -> Data? {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let drawWidth = imageSize.width * scale
        let drawHeight = imageSize.height * scale
        let drawRect = CGRect(
            x: (size.width - drawWidth) / 2,
            y: (size.height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let cropped = renderer.image { _ in
            image.draw(in: drawRect)
        }
        return cropped.jpegData(compressionQuality: jpegQuality)
    }

    /// 单帧描述符的公共路径（最小测试 + 单帧照片共用）：1 帧 JPEG +
    /// 同一套 makeDescriptorMetadata / caml / indexXML / blankCAML /
    /// floatingIndexXML / seedDescriptorFiles。
    private static func buildSingleFrameDescriptor(jpeg: Data, size: CGSize, in workspace: URL) throws -> URL {
        let identifier = nextDescendingIdentifier()
        let descriptorURL = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wallpaperURL = descriptorURL
            .appendingPathComponent("versions/1/contents/\(wallpaperFileName)", isDirectory: true)
        let animationURL = wallpaperURL.appendingPathComponent(backgroundFileName, isDirectory: true)
        let assetsURL = animationURL.appendingPathComponent("assets", isDirectory: true)
        let floatingURL = wallpaperURL.appendingPathComponent(floatingFileName, isDirectory: true)
        let foregroundURL = wallpaperURL.appendingPathComponent(foregroundFileName, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: floatingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: foregroundURL, withIntermediateDirectories: true)
        try jpeg.write(to: assetsURL.appendingPathComponent("0.jpg"), options: .atomic)
        try makeDescriptorMetadata(
            at: descriptorURL,
            identifier: identifier,
            width: Int(size.width),
            height: Int(size.height)
        )
        try caml(
            width: Int(size.width),
            height: Int(size.height),
            frameNames: ["0.jpg"],
            duration: 1.0,
            autoReverses: false
        ).write(to: animationURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: Int(size.width), height: Int(size.height))
            .write(to: animationURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: floatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: floatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: foregroundURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: foregroundURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try seedDescriptorFiles(at: descriptorURL, animationURL: animationURL, floatingURL: floatingURL, foregroundURL: foregroundURL)
        return descriptorURL
    }

    /// 从 drawer 直接一帧一帧画出来做描述符（不经过 MOV）。
    /// 构建 #23（2026-11-20）：走静态写入那条渲染路——每帧用
    /// UIGraphicsImageRenderer（scale 固定 1，和单帧探针的 aspectFillJPEG
    /// 同一套）+ UIImage.draw 直接画出来存 JPEG，不经过视频编解码和
    /// AVAssetReader 抽帧。实测：静态写入（单帧照片探针）的描述符在 13p
    /// 画廊里出现，MOV → 抽帧写出来的变身/景深/视频描述符都不出现，
    /// 所以变身和景深改走这条路。帧数 = duration × 15fps（3 秒 → 45 帧），
    /// 和原来抽帧的帧数一致；CAML / 元数据 / 种子文件和原来完全相同。
    static func buildDescriptorFromDrawer(
        frameCount: Int,
        duration: TimeInterval,
        outputSize: CGSize,
        drawer: @escaping VideoRenderer.FrameDrawer,
        in workspace: URL
    ) throws -> URL {
        let identifier = nextDescendingIdentifier()
        let descriptorURL = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wallpaperURL = descriptorURL
            .appendingPathComponent("versions/1/contents/\(wallpaperFileName)", isDirectory: true)
        let animationURL = wallpaperURL.appendingPathComponent(backgroundFileName, isDirectory: true)
        let assetsURL = animationURL.appendingPathComponent("assets", isDirectory: true)
        let floatingURL = wallpaperURL.appendingPathComponent(floatingFileName, isDirectory: true)
        let foregroundURL = wallpaperURL.appendingPathComponent(foregroundFileName, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: floatingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: foregroundURL, withIntermediateDirectories: true)

        var frameNames: [String] = []
        for i in 0..<frameCount {
            let time = duration * Double(i) / Double(frameCount)
            guard let jpeg = renderFrameJPEG(drawer: drawer, size: outputSize, time: time) else {
                throw BuildError.frameEncodingFailed
            }
            let frameName = "\(i).jpg"
            try jpeg.write(to: assetsURL.appendingPathComponent(frameName), options: .atomic)
            frameNames.append(frameName)
        }
        guard !frameNames.isEmpty else { throw BuildError.invalidVideo }

        try makeDescriptorMetadata(
            at: descriptorURL,
            identifier: identifier,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        try caml(
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            frameNames: frameNames,
            duration: duration,
            autoReverses: false
        ).write(to: animationURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: Int(outputSize.width), height: Int(outputSize.height))
            .write(to: animationURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: floatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: floatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: foregroundURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: foregroundURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try seedDescriptorFiles(at: descriptorURL, animationURL: animationURL, floatingURL: floatingURL, foregroundURL: foregroundURL)
        return descriptorURL
    }

    /// 把变身的两张照片各渲染成一张 1080×1920 的 JPEG（aspect-fill，
    /// 和单帧探针的 aspectFillJPEG 同一套），供 2 态变身描述符用。
    /// 返回 (lockJPEG, unlockJPEG)，任一张渲染失败返回 nil。
    static func renderTwoStateJPEGs(imageA: UIImage, imageB: UIImage, size: CGSize) -> (Data, Data)? {
        guard let lockJPEG = aspectFillJPEG(image: imageA, size: size),
              let unlockJPEG = aspectFillJPEG(image: imageB, size: size) else {
            return nil
        }
        return (lockJPEG, unlockJPEG)
    }

    /// 把一张照片渲染成一张指定尺寸的 JPEG（aspect-fill，同 aspectFillJPEG），
    /// 供熄屏常显图等单张图用。渲染失败返回 nil。
    static func renderSingleJPEG(image: UIImage, size: CGSize) -> Data? {
        aspectFillJPEG(image: image, size: size)
    }

    /// 2 态滑动解锁变身描述符（构建 #24，Camlo 式“真变身”；构建 #25 加
    /// 动画曲线 / AI 抠图 / 昼夜双生 / 熄屏常显图）。
    /// 不再是 45 帧视频：Background .ca 的 assets 里只有两张图
    /// （lock.jpg = 照片 A，unlock.jpg = 照片 B），CAML 用 LKState 状态机：
    /// Locked 态显示 A，Unlock 态显示 B，解锁时在两者之间做过渡动画。
    /// 画廊能列出 2 态描述符、列不出 45 帧视频描述符（见 Camlo 对照），
    /// 所以变身改走这条路。size 是帧尺寸（1080×1920，已证实能渲染）。
    /// - curve：变身动画曲线（默认上滑揭幕）。
    /// - foregroundPNG：AI 主体抠图（带透明通道的 PNG），有就写进 Floating.ca，
    ///   盖在锁屏时钟前面；没有就保持空白 Floating。
    /// - nightLockJPEG / nightUnlockJPEG：夜间图（都要有才生效），写进 Dark
    ///   变体包，Wallpaper.plist 里加 "dark" 入口，深色模式自动换图。
    /// - alwaysOnJPEG：熄屏常显图，写到 versions/1/contents/alwaysOn.jpg。
    static func buildTwoStateMorphDescriptor(
        lockJPEG: Data,
        unlockJPEG: Data,
        size: CGSize,
        curve: MorphCurve = .revealUp,
        foregroundPNG: Data? = nil,
        nightLockJPEG: Data? = nil,
        nightUnlockJPEG: Data? = nil,
        alwaysOnJPEG: Data? = nil,
        in workspace: URL
    ) throws -> URL {
        let identifier = nextDescendingIdentifier()
        let descriptorURL = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wallpaperURL = descriptorURL
            .appendingPathComponent("versions/1/contents/\(wallpaperFileName)", isDirectory: true)
        let animationURL = wallpaperURL.appendingPathComponent(backgroundFileName, isDirectory: true)
        let assetsURL = animationURL.appendingPathComponent("assets", isDirectory: true)
        let floatingURL = wallpaperURL.appendingPathComponent(floatingFileName, isDirectory: true)
        let foregroundURL = wallpaperURL.appendingPathComponent(foregroundFileName, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: floatingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: foregroundURL, withIntermediateDirectories: true)
        try lockJPEG.write(to: assetsURL.appendingPathComponent("lock.jpg"), options: .atomic)
        try unlockJPEG.write(to: assetsURL.appendingPathComponent("unlock.jpg"), options: .atomic)

        // AI 抠图：foreground.png 写进 Floating.ca 的 assets，Floating 包的
        // main.caml 换成带抠图图层的 floatingCAML（1080×1920，和 lock.jpg 对齐）。
        // 没有抠图时保持原来的空白 Floating。
        if let foregroundPNG = foregroundPNG {
            let floatingAssetsURL = floatingURL.appendingPathComponent("assets", isDirectory: true)
            try fileManager.createDirectory(at: floatingAssetsURL, withIntermediateDirectories: true)
            try foregroundPNG.write(to: floatingAssetsURL.appendingPathComponent("foreground.png"), options: .atomic)
            try floatingCAML(width: Int(size.width), height: Int(size.height))
                .write(to: floatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
            try indexXML(width: Int(size.width), height: Int(size.height))
                .write(to: floatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        } else {
            try blankCAML()
                .write(to: floatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
            try floatingIndexXML()
                .write(to: floatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        }
        try blankCAML()
            .write(to: foregroundURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: foregroundURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)

        // 昼夜双生：夜图成对才生效，写一套 Dark 变体包（同 3 包结构，
        // 内容是夜图 + 同一条曲线的 CAML），Wallpaper.plist 里加 "dark" 入口。
        let hasNight = nightLockJPEG != nil && nightUnlockJPEG != nil
        if hasNight {
            let darkAnimationURL = wallpaperURL.appendingPathComponent(darkBackgroundFileName, isDirectory: true)
            let darkAssetsURL = darkAnimationURL.appendingPathComponent("assets", isDirectory: true)
            let darkFloatingURL = wallpaperURL.appendingPathComponent(darkFloatingFileName, isDirectory: true)
            let darkForegroundURL = wallpaperURL.appendingPathComponent(darkForegroundFileName, isDirectory: true)
            try fileManager.createDirectory(at: darkAssetsURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: darkFloatingURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: darkForegroundURL, withIntermediateDirectories: true)
            try nightLockJPEG!.write(to: darkAssetsURL.appendingPathComponent("night_lock.jpg"), options: .atomic)
            try nightUnlockJPEG!.write(to: darkAssetsURL.appendingPathComponent("night_unlock.jpg"), options: .atomic)
            try twoStateCAML(
                width: Int(size.width),
                height: Int(size.height),
                curve: curve,
                lockSrc: "assets/night_lock.jpg",
                unlockSrc: "assets/night_unlock.jpg"
            ).write(to: darkAnimationURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
            try indexXML(width: Int(size.width), height: Int(size.height))
                .write(to: darkAnimationURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
            try blankCAML()
                .write(to: darkFloatingURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
            try floatingIndexXML()
                .write(to: darkFloatingURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
            try blankCAML()
                .write(to: darkForegroundURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
            try floatingIndexXML()
                .write(to: darkForegroundURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
            // 每个 .ca 包都要有 assetManifest.caml（见 seedDescriptorFiles）。
            try assetManifestCAML.write(to: darkAnimationURL.appendingPathComponent("assetManifest.caml"), atomically: true, encoding: .utf8)
            try assetManifestCAML.write(to: darkFloatingURL.appendingPathComponent("assetManifest.caml"), atomically: true, encoding: .utf8)
            try assetManifestCAML.write(to: darkForegroundURL.appendingPathComponent("assetManifest.caml"), atomically: true, encoding: .utf8)
        }

        try makeDescriptorMetadata(
            at: descriptorURL,
            identifier: identifier,
            width: Int(size.width),
            height: Int(size.height),
            darkBackgroundFileName: hasNight ? darkBackgroundFileName : nil,
            darkFloatingFileName: hasNight ? darkFloatingFileName : nil,
            darkForegroundFileName: hasNight ? darkForegroundFileName : nil
        )
        try twoStateCAML(
            width: Int(size.width),
            height: Int(size.height),
            curve: curve
        ).write(to: animationURL.appendingPathComponent("main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: Int(size.width), height: Int(size.height))
            .write(to: animationURL.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try seedDescriptorFiles(at: descriptorURL, animationURL: animationURL, floatingURL: floatingURL, foregroundURL: foregroundURL)

        // 熄屏常显图：写到 versions/1/contents/alwaysOn.jpg。
        // 注意：不往 otherMetadata 里记——它是 NSKeyedArchiver 的
        // PRPosterMetadata 归档，加顶层键会把它写坏，只留文件本身。
        if let alwaysOnJPEG = alwaysOnJPEG {
            let contentsURL = descriptorURL.appendingPathComponent("versions/1/contents", isDirectory: true)
            try alwaysOnJPEG.write(to: contentsURL.appendingPathComponent("alwaysOn.jpg"), options: .atomic)
        }
        return descriptorURL
    }

    /// 按 drawer 画一帧（静态写入那条路）：UIGraphicsImageRenderer，
    /// scale 固定 1，输出像素尺寸就是 size 本身（1080×1920），
    /// 和单帧探针的 aspectFillJPEG 同一套渲染。
    private static func renderFrameJPEG(
        drawer: VideoRenderer.FrameDrawer,
        size: CGSize,
        time: TimeInterval
    ) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            drawer(ctx, size, time)
        }
        return image.jpegData(compressionQuality: jpegQuality)
    }

    // MARK: - 抽帧

    /// 输出尺寸：固定 1080×1920（构建 #22，见下）。
    /// 原先是 Placard VideoWallpaper.swift 的算法：iPhone 按
    /// UIScreen.main.nativeBounds 的长短边比例，长边上限 maximumLongEdge，
    /// 短边向下取偶数；iPhone 13 Pro（native 1170×2532）→ 886×1920。
    /// 但单帧照片探针实测（2026-11-20 19:57–19:59 CST）证明 886×1920
    /// 不渲染：探针 A（1080×1920）显示为照片 tile，探针 B（886×1920）
    /// 直接黑屏；两者只差尺寸，走同一条写入路径。所以视频/变身的输出
    /// 尺寸改成和探针 A 一样的 1080×1920。iPad 仍按 810:1080 的比例。
    /// 取 UIScreen.main 必须在 MainActor 上，buildDescriptor 不在 MainActor 上，
    /// 所以这里包一层 await MainActor.run。
    private static func devicePortraitOutputSize() async -> CGSize {
        await MainActor.run {
            if UIDevice.current.userInterfaceIdiom == .pad {
                let longEdge = maximumLongEdge
                let shortEdge = (longEdge * 810 / 1080 / 2).rounded(.down) * 2
                return CGSize(width: shortEdge, height: longEdge)
            }
            return CGSize(width: 1080, height: 1920)
        }
    }

    private static func extractFrames(
        asset: AVURLAsset,
        track: AVAssetTrack,
        preferredTransform: CGAffineTransform,
        outputSize: CGSize,
        outputFrameRate: Double,
        to assetsURL: URL
    ) async throws -> [String] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BuildError.invalidVideo }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? BuildError.invalidVideo
        }

        let context = CIContext()
        var frameNames: [String] = []
        var lastFrameTime: CMTime?
        let frameInterval = CMTime(seconds: 1 / outputFrameRate, preferredTimescale: 600)
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let lastFrameTime,
               CMTimeCompare(CMTimeSubtract(presentationTime, lastFrameTime), frameInterval) < 0 {
                continue
            }
            let frameName = "\(frameNames.count).jpg"
            let jpeg = try autoreleasepool { () throws -> Data in
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw BuildError.frameEncodingFailed
                }
                let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                    .transformed(by: preferredTransform)
                let normalizedImage = sourceImage.transformed(
                    by: CGAffineTransform(
                        translationX: -sourceImage.extent.minX,
                        y: -sourceImage.extent.minY
                    )
                )
                let scale = max(
                    outputSize.width / normalizedImage.extent.width,
                    outputSize.height / normalizedImage.extent.height
                )
                let scaledImage = normalizedImage.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
                let cropRect = CGRect(
                    x: scaledImage.extent.midX - outputSize.width / 2,
                    y: scaledImage.extent.midY - outputSize.height / 2,
                    width: outputSize.width,
                    height: outputSize.height
                )
                let outputImage = scaledImage.cropped(to: cropRect).transformed(
                    by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
                )
                guard let cgImage = context.createCGImage(
                    outputImage,
                    from: CGRect(origin: .zero, size: outputSize)
                ),
                      let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality) else {
                    throw BuildError.frameEncodingFailed
                }
                return data
            }
            try jpeg.write(to: assetsURL.appendingPathComponent(frameName), options: .atomic)
            frameNames.append(frameName)
            lastFrameTime = presentationTime
        }
        guard reader.status == .completed else {
            throw reader.error ?? BuildError.invalidVideo
        }
        return frameNames
    }

    // MARK: - 描述符元数据

    /// 三处同步写同一个递减 identifier（见 nextDescendingIdentifier）：
    /// 1. com.apple.posterkit.provider.descriptor.identifier 文件内容
    /// 2. userInfo 里的 wallpaperRepresentingIdentifier
    /// 3. Wallpaper.plist 里的 identifier
    /// darkBackgroundFileName 等：昼夜双生（构建 #25）时传 Dark 变体包名，
    /// Wallpaper.plist 里 lockAndHome 加一个 "dark" 入口（照 Camlo 的
    /// 7401 Dark 变体思路，appearanceAware 已是 true）；不传就是只有白天。
    private static func makeDescriptorMetadata(
        at descriptorURL: URL,
        identifier: Int,
        width: Int,
        height: Int,
        darkBackgroundFileName: String? = nil,
        darkFloatingFileName: String? = nil,
        darkForegroundFileName: String? = nil
    ) throws {
        do {
            try Data(String(identifier).utf8).write(
                to: descriptorURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"),
                options: .atomic
            )
            try Data("PRPosterRoleLockScreen".utf8).write(
                to: descriptorURL.appendingPathComponent("com.apple.posterkit.role.identifier"),
                options: .atomic
            )

            let providerInfo = try NSKeyedArchiver.archivedData(
                withRootObject: ["kConfigurationLastUseDateKey": Date()],
                requiringSecureCoding: false
            )
            try providerInfo.write(to: descriptorURL.appendingPathComponent("providerInfo.plist"), options: .atomic)

            let contentsURL = descriptorURL.appendingPathComponent("versions/1/contents", isDirectory: true)
            let userInfo: [String: Any] = [
                "posterEnvironmentOverrides": Data("{}".utf8),
                "wallpaperRepresentingFileName": wallpaperFileName,
                "wallpaperRepresentingIdentifier": identifier
            ]
            try writePlist(
                userInfo,
                to: contentsURL.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
            )

            // 名字和 family 用模板常量 "Chip"（和 Placard 的模板一致）；
            // 用户起的名字存在我们自己的"我的壁纸"记录里。
            // 构建 #24：logicalScreenClass 改 iPhone 类（390w-844h@3x~iphone，
            // 见 Camlo 对照），并加 foregroundAnimationFileName（3 个包）。
            // 构建 #25：有 Dark 变体时 lockAndHome 加 "dark" 入口（深色模式用）。
            var lockAndHome: [String: Any] = [
                "default": [
                    "backgroundAnimationFileName": backgroundFileName,
                    "floatingAnimationFileNameKey": floatingFileName,
                    "foregroundAnimationFileName": foregroundFileName,
                    "identifier": 9183,
                    "name": "Chip",
                    "type": "LayeredAnimation"
                ]
            ]
            if let darkBackgroundFileName = darkBackgroundFileName,
               let darkFloatingFileName = darkFloatingFileName,
               let darkForegroundFileName = darkForegroundFileName {
                lockAndHome["dark"] = [
                    "backgroundAnimationFileName": darkBackgroundFileName,
                    "floatingAnimationFileNameKey": darkFloatingFileName,
                    "foregroundAnimationFileName": darkForegroundFileName,
                    "identifier": 9183,
                    "name": "Chip",
                    "type": "LayeredAnimation"
                ]
            }
            let wallpaper: [String: Any] = [
                "appearanceAware": true,
                "assets": [
                    "lockAndHome": lockAndHome
                ],
                "contentVersion": 2.01,
                "family": "Chip",
                "identifier": identifier,
                "logicalScreenClass": "390w-844h@3x~iphone",
                "name": "Chip",
                "preferredProminentColor": ["dark": "#000000", "default": "#FFFFFF"],
                "version": 1
            ]
            try writePlist(
                wallpaper,
                to: contentsURL.appendingPathComponent(wallpaperFileName, isDirectory: true)
                    .appendingPathComponent("Wallpaper.plist")
            )
        } catch {
            throw BuildError.writeFailed(error)
        }
    }

    private static func writePlist(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 描述符骨架种子（排障报告 2，修复 1 + 修复 4）

    /// Camlo 的递减 ID：从 19999 开始每次减 1，用到 10100 后回到 19999。
    /// 只影响新壁纸在 Collections 里的排序，不影响生死。存在 UserDefaults 里。
    /// internal（不是 private）：对照测试（ControlDescriptor）共用同一个计数器，
    /// 保证它和正常注入的 ID 不会撞上。
    static func nextDescendingIdentifier() -> Int {
        let key = "BizhiGongfang.nextDescendingWallpaperID"
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: key) // 没存过是 0
        let current: Int
        if stored >= 10_100 && stored <= 19_999 {
            current = stored
        } else {
            current = 19_999
        }
        let next = current - 1 < 10_100 ? 19_999 : current - 1
        defaults.set(next, forKey: key)
        return current
    }

    /// 每个 .ca 包里的 assetManifest.caml：空 MicaAssetManifest，177 字节。
    /// index.xml 声明了这个文件，缺了它 PosterKit 加载 .ca 包失败，
    /// 描述符会在 PosterBoard 重启扫描时被当成坏描述符清掉。
    /// 内容逐字照真 .tendies 包（Cipher）和 Camlo 的模板；
    /// 注意末尾有一个换行（文件共 177 字节）。
    private static let assetManifestCAML =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\n" +
        "<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\">\n" +
        "  <MicaAssetManifest>\n" +
        "    <modules type=\"NSArray\"/>\n" +
        "  </MicaAssetManifest>\n" +
        "</caml>\n"

    // 7 个种子文件的 base64（内容原样取自 Camlo 的 PosterSeed.bundle，
    // GPL-3.0，与本项目 LICENSE 一致；以常量嵌在代码里，不依赖 bundle 资源）。
    private static let seedRuntimeSnapshotMetadataHome = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwTHSNVJG51bGzTDQ4PEBESViRjbGFzc1xhdmVyYWdlQ29sb3JfEA9hdmVyYWdlQ29udHJhc3SABIACIz/EFBQUFBQU1RQVFhcNGBkaGxxRclFiUWdRYSM/1YCOxlYX5yM/3U1qL1HIayM/36N+otqTvyM/8AAAAAAAAIAD0h4fICFaJGNsYXNzbmFtZVgkY2xhc3Nlc1dCU0NvbG9yoiAiWE5TT2JqZWN00h4fJCVfEBNQQlVJQ29sb3JTdGF0aXN0aWNzoiYiXxATUEJVSUNvbG9yU3RhdGlzdGljcwAIABEAGgAkACkAMgA3AEkATABRAFMAWQBfAGYAbQB6AIwAjgCQAJkApACmAKgAqgCsALUAvgDHANAA0gDXAOIA6wDzAPYA/wEEARoBHQAAAAAAAAIBAAAAAAAAACcAAAAAAAAAAAAAAAAAAAEz"
    private static let seedRuntimeSnapshotMetadataLock = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwTHSNVJG51bGzTDQ4PEBESViRjbGFzc1xhdmVyYWdlQ29sb3JfEA9hdmVyYWdlQ29udHJhc3SABIACIz/ElJSUlJSV1RQVFhcNGBkaGxxRclFiUWdRYSM/1hUGP1VT5yM/3fDZyUErayM/38Dg+kNtOyM/8AAAAAAAAIAD0h4fICFaJGNsYXNzbmFtZVgkY2xhc3Nlc1dCU0NvbG9yoiAiWE5TT2JqZWN00h4fJCVfEBNQQlVJQ29sb3JTdGF0aXN0aWNzoiYiXxATUEJVSUNvbG9yU3RhdGlzdGljcwAIABEAGgAkACkAMgA3AEkATABRAFMAWQBfAGYAbQB6AIwAjgCQAJkApACmAKgAqgCsALUAvgDHANAA0gDXAOIA6wDzAPYA/wEEARoBHQAAAAAAAAIBAAAAAAAAACcAAAAAAAAAAAAAAAAAAAEz"
    private static let seedComplicationLayout = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwTFx1VJG51bGzTDQ4PEBESViRjbGFzc18QEmlubGluZUNvbXBsaWNhdGlvbl1jb21wbGljYXRpb25zgASAAIAC0hQNFRZaTlMub2JqZWN0c6CAA9IYGRobWiRjbGFzc25hbWVYJGNsYXNzZXNXTlNBcnJheaIaHFhOU09iamVjdNIYGR4fXxAaUFJQb3N0ZXJDb21wbGljYXRpb25MYXlvdXSiIBxfEBpQUlBvc3RlckNvbXBsaWNhdGlvbkxheW91dAAIABEAGgAkACkAMgA3AEkATABRAFMAWQBfAGYAbQCCAJAAkgCUAJYAmwCmAKcAqQCuALkAwgDKAM0A1gDbAPgA+wAAAAAAAAIBAAAAAAAAACEAAAAAAAAAAAAAAAAAAAEY"
    private static let seedTitleStyleConfiguration = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGoCwwdISIqKyxVJG51bGzYDQ4PEBESExQVFhcYGRYbGVYkY2xhc3NadGl0bGVDb2xvcl8QEWNvbnRlbnRzTHVtaW5lbmNlWWdyb3VwTmFtZV8QFGFsdGVybmF0ZURhdGVFbmFibGVkXxATdGltZU51bWJlcmluZ1N5c3RlbV8QFXRpbWVGb250Q29uZmlndXJhdGlvbl51c2VyQ29uZmlndXJlZIAHgACABYAGCIAAgAII0h4NHyBfEBJ0aW1lRm9udElkZW50aWZpZXKAA4AEXxAYUFJUaW1lRm9udElkZW50aWZpZXJTb2Z00iMkJSZaJGNsYXNzbmFtZVgkY2xhc3Nlc18QI1BSUG9zdGVyU3lzdGVtVGltZUZvbnRDb25maWd1cmF0aW9uoycoKV8QI1BSUG9zdGVyU3lzdGVtVGltZUZvbnRDb25maWd1cmF0aW9uXxAdUFJQb3N0ZXJUaW1lRm9udENvbmZpZ3VyYXRpb25YTlNPYmplY3QjAAAAAAAAAABdUFJFZGl0aW5nTG9va9IjJC0uXxAfUFJQb3N0ZXJUaXRsZVN0eWxlQ29uZmlndXJhdGlvbqIvKV8QH1BSUG9zdGVyVGl0bGVTdHlsZUNvbmZpZ3VyYXRpb24ACAARABoAJAApADIANwBJAEwAUQBTAFwAYgBzAHoAhQCZAKMAugDQAOgA9wD5APsA/QD/AQABAgEEAQUBCgEfASEBIwE+AUMBTgFXAX0BgQGnAccB0AHZAecB7AIOAhEAAAAAAAACAQAAAAAAAAAwAAAAAAAAAAAAAAAAAAACMw=="
    private static let seedHomescreenConfiguration = "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cmVlbkFwcGVhcmFuY2VfEBxQUlBvc3RlckhvbWVTY3JlZW5BcHBlYXJhbmNl0wAaABEAGwAcAocAHgmAhgjSACAAIQKKAotfECZQUlBvc3RlckhvbWVQb3N0ZXJIb21lU2NyZWVuQXBwZWFyYW5jZaMCjAKNACZfECZQUlBvc3RlckhvbWVQb3N0ZXJIb21lU2NyZWVuQXBwZWFyYW5jZV8QHFBSUG9zdGVySG9tZVNjcmVlbkFwcGVhcmFuY2XSACAAIQKPApBfEB9QUlBvc3RlckhvbWVTY3JlZW5Db25maWd1cmF0aW9uogKRACZfEB9QUlBvc3RlckhvbWVTY3JlZW5Db25maWd1cmF0aW9uAAgAGQAiACwAMQA6AD8AUQBWAFsAXQFwAXYBjwGoAb8B1gHrAfICCQILAg0CDwIRAhMCFQIiAkICWgJbAl0CXgJnAnICewKkAqsC1ALzAvwDCQMPAyoDLAMuAzADUQNYA28DdwODA44DnAOkA6YDqAOqA6wDrQOvA7EDswPPA+MD+AP/BAsEIgQwBDIENAQ2BDcEOQRCBE0EdAR2BHgEegR8BH4EgASCBIQEhgSIBIoEjASOBJAEkgSUBJYEmASaBKsEugS8BL4EwATCBOkFFgUuBTYFPQVLBVMFWQVmBWwFeQWIBYoFjwWUBZ0FogW2Bb8FxAXGBcgF0QXeBeoF8gX3BfoGAgYLBhkGHgYsBj0GPwZBBkMGRQZsBo0GkgagBqIGpwa4BroGvAa+BsAG5wcUBxkHHgcnBzsHRAdJB0sHVAdlB2cHaQdrB20HlAfBB8YHywfUB+gH8Qf2B/gIAQgSCBQIFggYCBoIQQhuCHMIeAiBCJQInQiiCKQIrQi+CMAIwgjECMYI7QkOCRMJGAkmCSgJOQk7CT0JPwlBCWgJkQmWCZsJpAmxCbMJvAnNCc8J0QnTCdUJ/AodCiIKJwo6CjwKQQpSClQKVgpYCloKgQqqCq8KtAq9CssKzQrWCucK6QrrCu0K7wsWCz8LRAtJC1ILXwthC2oLewt9C38LgQuDC6oL1wvcC+EL6gv+DAcMDAwODBcMKAwqDCwMLgwwDFcMhAyJDI4MlwyrDLQMuQy7DMQM1QzXDNkM2wzdDQQNJQ0qDS8NQw1FDUoNWw1dDV8NYQ1jDYoNqw2wDbUNyA3KDc8N4A3iDeQN5g3oDg8OMA41DjoOTg5QDlUOZg5oDmoObA5uDpUOtg67DsAO1A7WDtsO7A7uDvAO8g70DxsPOA9AD1QPXA9eD2APYg9kD2YPcQ+CD4QPhg+ID4oPsQ/OD9MP1Q/XD9kP5A/tD/wQAxALEA0QFhAtEDIQSRBSEHUQehCdEKYQzxDWEP8RHhErES0RLxExEVIRVBFWEVgRWhFbEV0RXxFhEYARlRGXEZkRmxGcEZ4RpxHOEdAR0hHUEdYR2BHaEdwR3hHgEeIR5BHmEegR6hHsEe4R8BHyEfQSBRIHEgkSCxINEjQSYRJmEmsSdBKIEpESlhKYEqESshK0ErYSuBK6EuETAhMHExUTFxMcEy0TLxMxEzMTNRNcE4kTjhOTE5wTsBO5E74TwBPJE9oT3BPeE+AT4hQJFDYUOxRAFEkUXRRmFGsUbRR2FIcUiRSLFI0UjxS2FOMU6BTtFPYVCRUSFRcVGRUiFTMVNRU3FTkVOxViFYMViBWNFZsVnRWuFbAVshW0FbYV3RYGFgsWEBYZFiYWKBYxFkIWRBZGFkgWShZxFpIWlxacFq8WsRa2FscWyRbLFs0Wzxb2Fx8XJBcpFzIXQBdCF0sXXBdeF2AXYhdkF4sXtBe5F74XxxfUF9YX3xfwF/IX9Bf2F/gYHxhMGFEYVhhfGHMYfBiBGIMYjBidGJ8YoRijGKUYzBj5GP4ZAxkMGSAZKRkuGTAZORlKGUwZThlQGVIZeRmaGZ8ZpBm4GboZvxnQGdIZ1BnWGdgZ/xogGiUaKho9Gj8aRBpVGlcaWRpbGl0ahBqlGqoarxrDGsUayhrbGt0a3xrhGuMbChsrGzAbNRtJG0sbUBthG2MbZRtnG2kbkBuhG6MbpRunG6kb0BvZHAAcBxwuHE0cWhxbHF0cXhxnHJAclxzAHN8c6B0KHQ8AAAAAAAACAgAAAAAAAAKSAAAAAAAAAAAAAAAAAAAdMQ=="
    private static let seedConfigurableOptions = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGoCwwXGyErLDBVJG51bGzVDQ4PEBESExQVFV8QIHByZWZlcnJlZEhvbWVTY3JlZW5Db25maWd1cmF0aW9uXxAaZGlzcGxheU5hbWVMb2NhbGl6YXRpb25LZXlWJGNsYXNzXxAfcHJlZmVycmVkVGltZUZvbnRDb25maWd1cmF0aW9uc18QFHByZWZlcnJlZFRpdGxlQ29sb3JzgASAAIAHgAKAAtIYDxkaWk5TLm9iamVjdHOggAPSHB0eH1okY2xhc3NuYW1lWCRjbGFzc2VzV05TQXJyYXmiHiBYTlNPYmplY3TVIiMPJCUmEygTKl5wcmVmZXJyZWRTdHlsZV8QFHByZWZlcnJlZFNvbGlkQ29sb3JzXxAXcHJlZmVycmVkR3JhZGllbnRDb2xvcnNfEB1hbGxvd3NNb2RpZnlpbmdMZWdpYmlsaXR5Qmx1coAFgACABoAACRAA0hwdLS5fEClQUlBvc3RlckRlc2NyaXB0b3JIb21lU2NyZWVuQ29uZmlndXJhdGlvbqIvIF8QKVBSUG9zdGVyRGVzY3JpcHRvckhvbWVTY3JlZW5Db25maWd1cmF0aW9u0hwdMTJfEBtQUlBvc3RlckNvbmZpZ3VyYWJsZU9wdGlvbnOiMyBfEBtQUlBvc3RlckNvbmZpZ3VyYWJsZU9wdGlvbnMACAARABoAJAApADIANwBJAEwAUQBTAFwAYgBtAJAArQC0ANYA7QDvAPEA8wD1APcA/AEHAQgBCgEPARoBIwErAS4BNwFCAVEBaAGCAaIBpAGmAagBqgGrAa0BsgHeAeECDQISAjACMwAAAAAAAAIBAAAAAAAAADQAAAAAAAAAAAAAAAAAAAJR"
    private static let seedOtherMetadata = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGjCwwRVSRudWxs0g0ODxBfEBpkaXNwbGF5TmFtZUxvY2FsaXphdGlvbktleVYkY2xhc3OAAIAC0hITFBVaJGNsYXNzbmFtZVgkY2xhc3Nlc18QEFBSUG9zdGVyTWV0YWRhdGGiFhdfEBBQUlBvc3Rlck1ldGFkYXRhWE5TT2JqZWN0CBEaJCkyN0lMUVNXXWJ/hoiKj5qjtrnMAAAAAAAAAQEAAAAAAAAAGAAAAAAAAAAAAAAAAAAAANU="

    private static func seedData(_ base64: String) -> Data? {
        Data(base64Encoded: base64)
    }

    /// 补全描述符骨架：每个 .ca 包补 assetManifest.caml，再补 7 个种子文件。
    /// 缺了这些文件，PosterKit 加载 .ca 包失败，描述符会在 PosterBoard
    /// 重启扫描时被当成坏描述符清掉。
    /// 注意：不种子 suggestionMetadata.plist——它含苹果 7400 模板值，
    /// 写错比不写更糟，Camlo 自己都会在冲突时删掉它。
    /// 构建 #24：Foreground 包也补 assetManifest.caml（3 个包都要）。
    private static func seedDescriptorFiles(
        at descriptorURL: URL,
        animationURL: URL,
        floatingURL: URL,
        foregroundURL: URL
    ) throws {
        let fileManager = FileManager.default
        // 1a. 每个 .ca 包补 assetManifest.caml（内容完全相同）。
        try assetManifestCAML.write(to: animationURL.appendingPathComponent("assetManifest.caml"), atomically: true, encoding: .utf8)
        try assetManifestCAML.write(to: floatingURL.appendingPathComponent("assetManifest.caml"), atomically: true, encoding: .utf8)
        try assetManifestCAML.write(to: foregroundURL.appendingPathComponent("assetManifest.caml"), atomically: true, encoding: .utf8)

        // 1b. 7 个种子文件。
        let verDir = descriptorURL.appendingPathComponent("versions/1", isDirectory: true)
        let contentsDir = verDir.appendingPathComponent("contents", isDirectory: true)
        let supplementsDir = verDir.appendingPathComponent("supplements/0", isDirectory: true)
        try fileManager.createDirectory(at: supplementsDir, withIntermediateDirectories: true)

        let seeds: [(data: Data?, url: URL)] = [
            (seedData(seedRuntimeSnapshotMetadataHome), verDir.appendingPathComponent("RuntimeSnapshotMetadata-home.plist")),
            (seedData(seedRuntimeSnapshotMetadataLock), verDir.appendingPathComponent("RuntimeSnapshotMetadata-lock.plist")),
            (seedData(seedComplicationLayout), verDir.appendingPathComponent("com.apple.posterkit.provider.instance.complicationLayout.plist")),
            (seedData(seedTitleStyleConfiguration), verDir.appendingPathComponent("com.apple.posterkit.provider.instance.titleStyleConfiguration.plist")),
            (seedData(seedHomescreenConfiguration), supplementsDir.appendingPathComponent("com.apple.posterkit.provider.supplementURL.homescreenConfiguration.plist")),
            (seedData(seedConfigurableOptions), contentsDir.appendingPathComponent(".com.apple.posterkit.provider.contents.configurableOptions.plist")),
            (seedData(seedOtherMetadata), contentsDir.appendingPathComponent("com.apple.posterkit.provider.contents.otherMetadata.plist")),
        ]
        for (data, url) in seeds {
            guard let data else { throw BuildError.writeFailed(nil) }
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - CAML（Core Animation 描述文件）

    /// 背景动画：一个 CALayer，第一帧是 assets/0.jpg，挂一个 CAKeyframeAnimation
    /// 按 contents 逐帧切换；必须带 Locked / Unlock / Sleep 三态和六组状态切换，
    /// 否则 PosterBoard 不认。
    private static func caml(
        width: Int,
        height: Int,
        frameNames: [String],
        duration: Double,
        autoReverses: Bool
    ) -> String {
        let values = frameNames
            .map { "        <CGImage src=\"assets/\($0)\"/>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_FLOATING" position="\(width / 2) \(height / 2)">
            <sublayers>
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Chip" position="\(width / 2) \(height / 2)">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer1" position="\(width / 2) \(height / 2)">
                    <contents type="CGImage" src="assets/0.jpg"/>
                    <animations>
                      <animation type="CAKeyframeAnimation" calculationMode="discrete" keyPath="contents" beginTime="1e-100" duration="\(duration)" removedOnCompletion="0" repeatCount="inf" repeatDuration="0" speed="1" timeOffset="0" autoreverses="\(autoReverses ? 1 : 0)">
                        <values>
        \(values)
                        </values>
                      </animation>
                    </animations>
                  </CALayer>
                </sublayers>
              </CATransformLayer>
            </sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    /// 2 态变身的 CAML（构建 #24，Camlo 式“真变身”；构建 #25 加动画曲线）。
    /// Chip 里叠两层：CALayer1 是照片 A（lock.jpg），CALayer2 是照片 B
    /// （unlock.jpg）。曲线决定 CALayer2 的动画属性：
    /// 上滑揭幕 position.y、破屏觉醒 transform.scale + opacity、圣光瞬变 opacity。
    /// LKState 只写 Locked / Unlock / Sleep 三态（和原来一样），
    /// 但每态里用 LKStateSetValue 把每个动画属性定下来；
    /// Locked→Unlock 与 Unlock→Locked 两组切换里放过渡动画，
    /// 其余切换留空（和原来一样）。targetId 用图层的 id。
    /// lockSrc / unlockSrc 是两张图在 assets 里的路径（白天 lock/unlock，
    /// 夜间 night_lock/night_unlock）。
    /// 注意：这里的 LKStateSetValue / LKStateTransitionElement 写法
    /// 照 Camlo 二进制里的模板片段（见 ~/workspace/camlo-research/CAMLO_ANALYSIS.md），
    /// 不是 Placard 的空 <elements/>。
    private static func twoStateCAML(
        width: Int,
        height: Int,
        curve: MorphCurve = .revealUp,
        lockSrc: String = "assets/lock.jpg",
        unlockSrc: String = "assets/unlock.jpg"
    ) -> String {
        let cx = width / 2
        let cy = height / 2
        let props = curve.animatedProperties(width: width, height: height)
        let initial = curve.initialLayerState(width: width, height: height)
        let duration = curve.duration
        let timing = curve.timingFunction

        // 三态：Locked / Sleep 用 Locked 值，Unlock 用 Unlock 值。
        func stateElements(value: (String, String, String) -> String) -> String {
            props.map { prop in
                """
                                  <LKStateSetValue targetId="CALayer2" keyPath="\(prop.keyPath)">
                                    <value type="real" value="\(value(prop.keyPath, prop.locked, prop.unlocked))"/>
                                  </LKStateSetValue>
                """
            }.joined(separator: "\n")
        }
        let lockedElements = stateElements { _, locked, _ in locked }
        let unlockElements = stateElements { _, _, unlocked in unlocked }

        // 两组过渡动画：每组里每个属性一条 CABasicAnimation。
        func transitionAnimations(from: (String, String, String) -> String, to: (String, String, String) -> String) -> String {
            props.map { prop in
                """
                                  <animation type="CABasicAnimation" keyPath="\(prop.keyPath)" fromValue="\(from(prop.keyPath, prop.locked, prop.unlocked))" toValue="\(to(prop.keyPath, prop.locked, prop.unlocked))" duration="\(duration)" timingFunction="\(timing)"/>
                """
            }.joined(separator: "\n")
        }
        let forwardAnims = transitionAnimations(from: { _, locked, _ in locked }, to: { _, _, unlocked in unlocked })
        let backwardAnims = transitionAnimations(from: { _, _, unlocked in unlocked }, to: { _, locked, _ in locked })

        // CALayer2 的初始属性：position / opacity，破屏觉醒再加 transform（缩 0.6 倍）。
        let transformAttr = initial.transform.map { " transform=\"\($0)\"" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_FLOATING" position="\(cx) \(cy)">
            <sublayers>
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Chip" position="\(cx) \(cy)">
                <sublayers>
                  <CALayer id="CALayer1" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer1" position="\(cx) \(cy)">
                    <contents type="CGImage" src="\(lockSrc)"/>
                  </CALayer>
                  <CALayer id="CALayer2" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer2" opacity="\(initial.opacity)" position="\(initial.position)"\(transformAttr)>
                    <contents type="CGImage" src="\(unlockSrc)"/>
                  </CALayer>
                </sublayers>
              </CATransformLayer>
            </sublayers>
            <states>
              <LKState name="Locked">
                <elements>
        \(lockedElements)
                </elements>
              </LKState>
              <LKState name="Unlock">
                <elements>
        \(unlockElements)
                </elements>
              </LKState>
              <LKState name="Sleep">
                <elements>
        \(lockedElements)
                </elements>
              </LKState>
            </states>
            <stateTransitions>
              <LKStateTransition fromState="Locked" toState="Unlock">
                <elements>
                  <LKStateTransitionElement targetId="CALayer2">
        \(forwardAnims)
                  </LKStateTransitionElement>
                </elements>
              </LKStateTransition>
              <LKStateTransition fromState="Unlock" toState="Locked">
                <elements>
                  <LKStateTransitionElement targetId="CALayer2">
        \(backwardAnims)
                  </LKStateTransitionElement>
                </elements>
              </LKStateTransition>
              <LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition>
              <LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition>
              <LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition>
              <LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition>
              <LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition>
              <LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition>
            </stateTransitions>
          </CALayer>
        </caml>
        """
    }

    /// 前景抠图层的 CAML（构建 #25，AI 主体抠图）。
    /// Floating.ca 里放一个全幅图层显示 assets/foreground.png（带透明通道），
    /// 盖在锁屏时钟前面（Floating 层在时钟前面，见 Camlo 对照）。
    /// 用和 Background 一样的 1080×1920 画布（不是 blankCAML 的 3176），
    /// 保证抠图和 lock.jpg 像素对齐；调用方同时用 indexXML 写 index.xml。
    private static func floatingCAML(width: Int, height: Int) -> String {
        let cx = width / 2
        let cy = height / 2
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_FLOATING" position="\(cx) \(cy)">
            <sublayers>
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Chip" position="\(cx) \(cy)">
                <sublayers>
                  <CALayer id="ForegroundCutout" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="ForegroundCutout" position="\(cx) \(cy)">
                    <contents type="CGImage" src="assets/foreground.png"/>
                  </CALayer>
                </sublayers>
              </CATransformLayer>
            </sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    /// 前景包用空白 CAML（一个空图层），和 Placard 的模板一致。
    private static func blankCAML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 3176 3176" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_BACKGROUND" position="1588 1588">
            <sublayers><CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" anchorPoint="0 0" bounds="0 0 0 0" contentsFormat="RGBA8" cornerCurve="circular" name="_CENTER_BACKGROUND" position="1588 1588"/></sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    private static func indexXML(width: Int, height: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>\(height)</real>
          <key>documentResizesToView</key><true/>
          <key>documentWidth</key><real>\(width)</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>0.0</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><false/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><true/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }

    private static func floatingIndexXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>3176</real>
          <key>documentResizesToView</key><false/>
          <key>documentWidth</key><real>3176</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>0.0</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><false/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><false/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }
}
