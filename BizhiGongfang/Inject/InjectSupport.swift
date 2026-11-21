import Foundation
import UIKit

/// 一键写入锁屏的版本门禁 + 共用注入流程。
///
/// 直写只在 iOS 26.0 – 27.3 beta 1 上可用：苹果在 27.3 beta 2（build 24C5049d）
/// 封堵了 worse_query。判断用 kern.osversion 的 build 号（24C5037i 是最后一个
/// 可用版本），光看 marketing 版本分不出 beta 1 和 beta 2。
enum InjectSupport {

    /// App Group：直写功能要求 App 带这个 entitlement。
    /// 注意：在 LiveContainer 里跑时，起作用的是 LiveContainer 自己的签名，
    /// 客 App 自己的 entitlement 不生效（见 PosterBoardStore.usableGroups）。
    static let appGroupID = "group.com.wallpaperstudio.app"

    enum Availability {
        /// 可以直写
        case available
        /// 系统太老（iOS 26 以下）：只能导出 Live Photo
        case tooOld
        /// 已被封堵（iOS 27.3 beta 2 及以上）：只能导出 Live Photo / .tendies
        case patched
        /// 模拟器：直写一定不行
        case simulator

        var canInject: Bool {
            if case .available = self { return true }
            return false
        }

        var reason: String {
            switch self {
            case .available:
                return ""
            case .tooOld:
                return "一键写入锁屏需要 iOS 26 或更高版本，当前系统太老，只能导出 Live Photo 到相册。"
            case .patched:
                return "当前系统版本已封堵一键写入（苹果在 iOS 27.3 beta 2 堵了这个口子），只能导出 Live Photo 到相册。"
            case .simulator:
                return "模拟器上不能一键写入，请在真机上用。"
            }
        }
    }

    /// 当前设备能不能一键写入。
    static func availability() -> Availability {
        #if targetEnvironment(simulator)
        return .simulator
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else { return .tooOld }
        // 27.3 beta 2（build 24C5049d）起封堵；beta 1（24C5037i）还可用。
        // build 号从 kern.osversion 读，比 marketing 版本准。
        if bizhi_worse_query_patched_build(bizhi_os_build()) {
            return .patched
        }
        return .available
        #endif
    }

    /// 当前系统版本 + build 号（诊断里显示用）。
    static func systemDescription() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let build = bizhi_os_build()
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)（build \(build.isEmpty ? "未知" : build)）"
    }

    /// 升级警告：显示在直写入口和诊断页顶部。
    static let upgradeWarning = "别升级到 iOS 27.3 beta 2 或更高版本，也请关闭「自动更新」，否则一键写入会永久失效（苹果已封堵，只能导出文件）。"

    /// 成功写入后的引导：先讲注销桌面（画廊要重建索引才会出现新壁纸），
    /// 再讲长按锁屏点 +、滑到底部「收藏」里找。
    /// 三个编辑器注入成功后弹出的注销提示、诊断页「写入成功后怎么查看」用的都是这段。
    static let successGuidance = """
    已写入锁屏画廊！

    画廊要注销一次桌面才会出现这张壁纸（只划掉 PosterBoard 不够）：
    1. 点「立即注销桌面生效」——屏幕会黑一下、桌面重启一次，属于正常现象。
    2. 注销后长按锁屏，点 + 添加新墙纸。
    3. 在画廊里找到刚写入的壁纸（滑到底部「收藏」里找），添加即可。

    如果现在不想注销，点「不用了」——壁纸已经写进去了，之后只要注销一次桌面，画廊里就会出现它。
    """
}

/// 一键写入的共用流程：描述符 → 找 PosterBoard → 写进去 → 记到"我的壁纸"。
enum InjectFlow {

    /// 单帧照片探针的 poster UUID（UserDefaults 键）：探针 A（1080×1920）、
    /// 探针 B（886×1920）。诊断第 7 步用它们核对快照状态，诊断页也能删掉它们。
    static let singlePhotoProbeAKey = "BizhiGongfang.singlePhotoProbeA"
    static let singlePhotoProbeBKey = "BizhiGongfang.singlePhotoProbeB"

    /// 把一段视频（MOV）写成锁屏壁纸。返回写进去的 poster UUID。
    /// still 用于在"我的壁纸"里留一条记录（和导出 Live Photo 的记录一样，
    /// 只是多标了已写入锁屏，之后可以只删这一张）。
    static func injectVideo(
        videoURL: URL,
        name: String,
        kind: WallpaperItem.Kind,
        still: UIImage,
        stillJPEGData: Data,
        store: WallpaperStore
    ) async throws -> String {
        guard PosterBoardStore.isAvailable else {
            throw InjectError.missingAppGroup
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let descriptor = try await DescriptorBuilder.buildDescriptor(from: videoURL, in: workspace)
        let appHash = try PosterBoardStore.findPosterBoardHash()
        let written = try PosterBoardStore.writeDescriptors(
            appHash: appHash,
            provider: DescriptorBuilder.providerID,
            descriptorFolders: [descriptor]
        )
        guard let writtenPath = written.first else {
            throw InjectError.wallpaperNotFound
        }
        let posterUUID = URL(fileURLWithPath: writtenPath).lastPathComponent
        let thumbnail = WallpaperStore.makeThumbnail(from: still)
        let item = store.add(
            name: name,
            kind: kind,
            stillImageTime: 0,
            stillJPEGData: stillJPEGData,
            videoURL: videoURL,
            thumbnail: thumbnail
        )
        store.markInjected(id: item.id, posterUUID: posterUUID, provider: DescriptorBuilder.providerID)
        return posterUUID
    }

    /// 变身 / 景深：一键写入锁屏，不经过 MOV，直接按 drawer 一帧一帧画出来
    /// 做描述符（构建 #23：走静态写入那条渲染路，画廊能认；MOV → 抽帧那条路
    /// 写出来的多帧描述符在 13p 画廊里不显示）。
    /// videoURL 是调用方先渲染好的 3 秒 MOV（供“我的壁纸”记录和详情页
    /// 播放动态用）；still / stillJPEGData 是静态图。
    static func injectFromDrawer(
        drawer: @escaping VideoRenderer.FrameDrawer,
        duration: TimeInterval,
        stillImageTime: TimeInterval,
        videoURL: URL,
        name: String,
        kind: WallpaperItem.Kind,
        still: UIImage,
        stillJPEGData: Data,
        store: WallpaperStore
    ) async throws -> String {
        guard PosterBoardStore.isAvailable else {
            throw InjectError.missingAppGroup
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outputSize = CGSize(width: 1080, height: 1920)
        let frameCount = Int(duration * DescriptorBuilder.outputFrameRate)
        let descriptor = try DescriptorBuilder.buildDescriptorFromDrawer(
            frameCount: frameCount,
            duration: duration,
            outputSize: outputSize,
            drawer: drawer,
            in: workspace
        )
        let appHash = try PosterBoardStore.findPosterBoardHash()
        let written = try PosterBoardStore.writeDescriptors(
            appHash: appHash,
            provider: DescriptorBuilder.providerID,
            descriptorFolders: [descriptor]
        )
        guard let writtenPath = written.first else {
            throw InjectError.wallpaperNotFound
        }
        let posterUUID = URL(fileURLWithPath: writtenPath).lastPathComponent
        let thumbnail = WallpaperStore.makeThumbnail(from: still)
        let item = store.add(
            name: name,
            kind: kind,
            stillImageTime: stillImageTime,
            stillJPEGData: stillJPEGData,
            videoURL: videoURL,
            thumbnail: thumbnail
        )
        store.markInjected(id: item.id, posterUUID: posterUUID, provider: DescriptorBuilder.providerID)
        return posterUUID
    }

    /// 变身：一键写入锁屏，走 2 态滑动解锁描述符（构建 #24，Camlo 式“真变身”）。
    /// 不再是 45 帧视频：只把照片 A（lock）和照片 B（unlock）各渲染一张
    /// 1080×1920，写进 2 态描述符（Locked 显示 A，Unlock 显示 B）。
    /// videoURL 是调用方先渲染好的 3 秒 MOV（供“我的壁纸”记录和详情页
    /// 播放动态用）；still / stillJPEGData 是静态图。
    static func injectTwoStateMorph(
        imageA: UIImage,
        imageB: UIImage,
        slide: Bool,
        videoURL: URL,
        name: String,
        kind: WallpaperItem.Kind,
        still: UIImage,
        stillJPEGData: Data,
        store: WallpaperStore
    ) async throws -> String {
        guard PosterBoardStore.isAvailable else {
            throw InjectError.missingAppGroup
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outputSize = CGSize(width: 1080, height: 1920)
        guard let (lockJPEG, unlockJPEG) = DescriptorBuilder.renderTwoStateJPEGs(
            imageA: imageA, imageB: imageB, size: outputSize
        ) else {
            throw DescriptorBuilder.BuildError.frameEncodingFailed
        }
        let descriptor = try DescriptorBuilder.buildTwoStateMorphDescriptor(
            lockJPEG: lockJPEG,
            unlockJPEG: unlockJPEG,
            size: outputSize,
            slide: slide,
            in: workspace
        )
        let appHash = try PosterBoardStore.findPosterBoardHash()
        let written = try PosterBoardStore.writeDescriptors(
            appHash: appHash,
            provider: DescriptorBuilder.providerID,
            descriptorFolders: [descriptor]
        )
        guard let writtenPath = written.first else {
            throw InjectError.wallpaperNotFound
        }
        let posterUUID = URL(fileURLWithPath: writtenPath).lastPathComponent
        let thumbnail = WallpaperStore.makeThumbnail(from: still)
        let item = store.add(
            name: name,
            kind: kind,
            stillImageTime: 0,
            stillJPEGData: stillJPEGData,
            videoURL: videoURL,
            thumbnail: thumbnail
        )
        store.markInjected(id: item.id, posterUUID: posterUUID, provider: DescriptorBuilder.providerID)
        return posterUUID
    }

    /// 对照测试写入：把一份完整的真实 Cipher.tendies 描述符原样写进 PosterBoard，
    /// 只改文件夹 UUID 和三处 identifier（见 ControlDescriptor）。
    /// 走和正常注入完全相同的 writeDescriptors 路径（同样享受 postWriteRefresh
    /// 的镜像 + 清缓存 + 写偏好）。返回写进去的 poster UUID（调用方负责记下来，
    /// 方便之后在诊断第 7 步核对和删掉）。
    static func injectControlTest() async throws -> String {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let descriptor = try ControlDescriptor.buildControlDescriptor(in: workspace)
        let appHash = try PosterBoardStore.findPosterBoardHash()
        let written = try PosterBoardStore.writeDescriptors(
            appHash: appHash,
            provider: DescriptorBuilder.providerID,
            descriptorFolders: [descriptor]
        )
        guard let writtenPath = written.first else {
            throw InjectError.wallpaperNotFound
        }
        return URL(fileURLWithPath: writtenPath).lastPathComponent
    }

    /// 单帧真照片判别实验（排障报告 4 第十节）：用同一张照片写两个描述符——
    /// 探针 A（1080×1920，与最小测试只差帧内容）和探针 B（886×1920，
    /// 与视频只差帧数）。返回两个写进去的 poster UUID（顺序：A、B），
    /// 调用方负责记到 UserDefaults 里，方便之后在诊断第 7 步核对和删掉。
    /// 走和正常注入完全相同的 writeDescriptors 路径（同样享受写后改权限 +
    /// 镜像 + 清缓存 + 写偏好）。
    static func injectSinglePhoto(image: UIImage) async throws -> (probeA: String, probeB: String) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let descriptorA = try DescriptorBuilder.buildSinglePhotoDescriptor(
            image: image, size: CGSize(width: 1080, height: 1920), in: workspace)
        let descriptorB = try DescriptorBuilder.buildSinglePhotoDescriptor(
            image: image, size: CGSize(width: 886, height: 1920), in: workspace)
        let appHash = try PosterBoardStore.findPosterBoardHash()
        let written = try PosterBoardStore.writeDescriptors(
            appHash: appHash,
            provider: DescriptorBuilder.providerID,
            descriptorFolders: [descriptorA, descriptorB]
        )
        guard written.count == 2 else {
            throw InjectError.wallpaperNotFound
        }
        let uuidA = URL(fileURLWithPath: written[0]).lastPathComponent
        let uuidB = URL(fileURLWithPath: written[1]).lastPathComponent
        return (probeA: uuidA, probeB: uuidB)
    }

    /// 诊断用的最小写入：不依赖视频，只写一个 1 帧的空白描述符。
    /// 返回写进去的 poster UUID（调用方负责记下来，方便之后删掉）。
    static func injectMinimalTest() async throws -> String {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let descriptor = try DescriptorBuilder.buildMinimalDescriptor(in: workspace)
        let appHash = try PosterBoardStore.findPosterBoardHash()
        let written = try PosterBoardStore.writeDescriptors(
            appHash: appHash,
            provider: DescriptorBuilder.providerID,
            descriptorFolders: [descriptor]
        )
        guard let writtenPath = written.first else {
            throw InjectError.wallpaperNotFound
        }
        return URL(fileURLWithPath: writtenPath).lastPathComponent
    }
}
