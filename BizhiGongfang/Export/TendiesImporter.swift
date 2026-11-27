import Foundation
import UIKit

/// 安装 .tendies（构建 #32，云端壁纸库用）：把一个 .tendies 文件
/// （改了后缀的 ZIP）解开，找出里面的描述符文件夹，randomize
/// identifier 后直接写进 PosterBoard 锁屏画廊，并记一条“导入壁纸”
/// 记录到我的壁纸（可删锁屏里的这一张）。
///
/// ZIP 解压纯 Swift 手写，不引第三方库：stored（method 0）直接拷；
/// deflate（method 8）用自己写的 inflate 解（RFC 1951；外部工具的
/// .tendies 可能是 deflate，必须能解）。inflate 算法已在 Python 里
/// 用同一套逻辑对 Python zipfile 生成的 deflate ZIP 验证过
/// （条目大小、CRC 全对）。
/// （不用 FileManager.unzipItem——它在工作流用的 Xcode 16.4 SDK 里
/// 不存在，构建 #24 第一次编就因为它失败。）
enum TendiesImporter {

    enum ImportError: LocalizedError {
        case notZip
        case noDescriptors
        case descriptorInvalid(String)
        case unsupportedMethod(UInt16)
        case corrupt(String)
        case readFailed(Error?)
        case missingAppGroup
        case writeFailed(Error?)
        case noIPhoneVariant

        var errorDescription: String? {
            switch self {
            case .notZip: return "不是有效的 .tendies 文件（解不开 ZIP）"
            case .noDescriptors: return "这个 .tendies 里没有描述符，找不到壁纸"
            case .descriptorInvalid(let name): return "描述符 \(name) 里没有 Wallpaper.plist，不是有效的壁纸包"
            case .unsupportedMethod(let method): return "不支持的 ZIP 压缩方式（method \(method)），只支持 stored 和 deflate"
            case .corrupt(let detail): return "文件损坏：\(detail)"
            case .readFailed(let error): return "读文件失败：\(error?.localizedDescription ?? "未知错误")"
            case .missingAppGroup: return "直写不可用：找不到 PosterBoard 容器（App Group 不可用）"
            case .writeFailed(let error): return "写入锁屏失败：\(error?.localizedDescription ?? "未知错误")"
            case .noIPhoneVariant: return "这张壁纸只有 iPad 版，没有 iPhone 版，装不到 iPhone 上"
            }
        }
    }

    /// 安装步骤标记（构建 #34）：每一步开始前先写进 UserDefaults，成功清掉。
    /// 万一安装中途闪退（Swift 的 do/catch 抓不到的死法），下次打开壁纸库
    /// 就能看到上次死在哪一步，不用再猜。正常的失败会走 catch 弹提示，
    /// 调用方负责清掉标记，只留真正的闪退。
    enum InstallStepMarker {
        private static let stepKey = "BizhiGongfang.lastInstallStep"
        private static let nameKey = "BizhiGongfang.lastInstallName"

        static func set(step: String, name: String) {
            let defaults = UserDefaults.standard
            defaults.set(step, forKey: stepKey)
            defaults.set(name, forKey: nameKey)
        }

        static func clear() {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: stepKey)
            defaults.removeObject(forKey: nameKey)
        }

        /// 上次中断的步骤（闪退留下的），没有返回 nil。
        static func read() -> (step: String, name: String)? {
            guard let step = UserDefaults.standard.string(forKey: stepKey),
                  let name = UserDefaults.standard.string(forKey: nameKey) else { return nil }
            return (step, name)
        }
    }

    /// 安装结果：写进 PosterBoard 的第一个描述符 UUID + 它的 provider，
    /// 以及一张静态图（描述符第一帧，供我的壁纸记录用）。
    struct InstalledTendies {
        let posterUUID: String
        let provider: String
        let stillJPEGData: Data?
        let descriptorCount: Int
    }

    /// 安装一个已下载好的 .tendies 文件到锁屏，并记一条导入记录。
    /// packageURL 是本地文件（库浏览器下载到临时目录的 .tendies）。
    /// 返回写进去的 poster UUID。失败时抛 ImportError。
    static func installTendies(
        from packageURL: URL,
        name: String,
        store: WallpaperStore
    ) async throws -> InstalledTendies {
        guard PosterBoardStore.isAvailable else {
            throw ImportError.missingAppGroup
        }
        InstallStepMarker.set(step: "解压 .tendies", name: name)
        let data: Data
        do {
            data = try Data(contentsOf: packageURL)
        } catch {
            throw ImportError.readFailed(error)
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let extractionDir = workspace.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        try extractZip(data: data, to: extractionDir)

        let descriptorGroups = try findDescriptorGroups(in: extractionDir)
        guard !descriptorGroups.isEmpty else {
            throw ImportError.noDescriptors
        }
        // 只有 iPad 版的包直接拦下（构建 #34）：装上去在 iPhone 上也显示不了，
        // 比如 Nugget 的 FrutigerAeroV1，里面只有一个 810w-1080h@2x~ipad 的壁纸。
        // 没有 .wallpaper 文件夹的描述符（比如视频描述符）不拦。
        let allDescriptors = descriptorGroups.values.flatMap { $0 }
        guard allDescriptors.contains(where: { iphoneCapable(in: $0) }) else {
            throw ImportError.noIPhoneVariant
        }
        InstallStepMarker.set(step: "换编号", name: name)
        for descriptors in allDescriptors
            where shouldRandomizeIdentifier(in: descriptors) {
            try randomizeIdentifier(in: descriptors)
        }

        let appHash = try PosterBoardStore.findPosterBoardHash()
        InstallStepMarker.set(step: "写入锁屏", name: name)
        var writtenPaths: [String] = []
        var firstProvider: String?
        for (extensionID, descriptors) in descriptorGroups {
            do {
                let written = try PosterBoardStore.writeDescriptors(
                    appHash: appHash,
                    provider: extensionID,
                    descriptorFolders: descriptors
                )
                if firstProvider == nil, !written.isEmpty {
                    firstProvider = extensionID
                }
                writtenPaths.append(contentsOf: written)
            } catch {
                throw ImportError.writeFailed(error)
            }
        }
        guard let firstPath = writtenPaths.first, let provider = firstProvider else {
            throw ImportError.writeFailed(nil)
        }
        let posterUUID = URL(fileURLWithPath: firstPath).lastPathComponent

        // 静态图：第一个描述符的第一帧（完整 JPEG，供记录用）。
        InstallStepMarker.set(step: "记记录", name: name)
        var stillJPEGData: Data?
        if let firstGroup = descriptorGroups.values.first?.first,
           let wallpaperDir = findWallpaperDir(in: firstGroup) {
            stillJPEGData = firstFrameJPEGData(wallpaperDir: wallpaperDir)
        }

        // 记一条导入记录到我的壁纸（可删锁屏里的这一张）。
        // store 是 ObservableObject，改 @Published 必须在主线程，
        // 不然在 LiveContainer 里可能闪退。
        let thumbnail: UIImage?
        if let stillJPEGData = stillJPEGData, let image = UIImage(data: stillJPEGData) {
            thumbnail = WallpaperStore.makeThumbnail(from: image)
        } else {
            thumbnail = nil
        }
        let item = await MainActor.run {
            store.addImported(
                name: name,
                stillJPEGData: stillJPEGData,
                packageURL: packageURL,
                thumbnail: thumbnail
            )
        }
        await MainActor.run {
            store.markInjected(id: item.id, posterUUID: posterUUID, provider: provider)
        }

        InstallStepMarker.clear()
        return InstalledTendies(
            posterUUID: posterUUID,
            provider: provider,
            stillJPEGData: stillJPEGData,
            descriptorCount: descriptorGroups.values.flatMap({ $0 }).count
        )
    }

    // MARK: - 从解压结果找描述符组（Placard 的 findDescriptorGroups）

    /// 枚举解压目录，找描述符文件夹，按 extensionID 分组。
    /// - `Extensions/<extensionID>/descriptors/` 下的子文件夹 → 那个 extensionID。
    /// - `descriptor` / `descriptors` / `ordered-descriptor(s)` → CollectionsPoster。
    /// - `video-descriptor(s)` → PhotosPosterProvider。
    private static func findDescriptorGroups(in root: URL) throws -> [String: [URL]] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.corrupt("解压目录读不出来")
        }
        var groups: [String: [URL]] = [:]
        for case let directory as URL in enumerator {
            let values = try directory.resourceValues(forKeys: Set(resourceKeys))
            guard values.isDirectory == true else { continue }
            if directory.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            let name = directory.lastPathComponent.lowercased()
            let extensionID: String?
            if name == "descriptors",
               let extensionsIndex = directory.pathComponents.lastIndex(of: "Extensions"),
               directory.pathComponents.indices.contains(extensionsIndex + 1) {
                extensionID = directory.pathComponents[extensionsIndex + 1]
            } else if ["descriptor", "descriptors", "ordered-descriptor", "ordered-descriptors"].contains(name) {
                extensionID = "com.apple.WallpaperKit.CollectionsPoster"
            } else if ["video-descriptor", "video-descriptors"].contains(name) {
                extensionID = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            } else {
                extensionID = nil
            }
            guard let extensionID else { continue }
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && $0.lastPathComponent != "__MACOSX"
            }
            if !children.isEmpty {
                groups[extensionID, default: []].append(contentsOf: children)
            }
            enumerator.skipDescendants()
        }
        return groups
    }

    /// 只有路径里不含 Container 的描述符才 randomize（Placard 同款判断）。
    private static func shouldRandomizeIdentifier(in descriptor: URL) -> Bool {
        !descriptor.pathComponents.contains {
            $0.caseInsensitiveCompare("Container") == .orderedSame
        }
    }

    /// 给一个描述符换一个新的随机 identifier（20000–99999，
    /// 避开我们自己视频壁纸的 10100–19999 下降号段，免得撞号）。
    /// 改三处：identifier 文件、contents.userInfo 的
    /// wallpaperRepresentingIdentifier、Wallpaper.plist 的 identifier。
    private static func randomizeIdentifier(in descriptor: URL) throws {
        let identifier = Int.random(in: 20_000...99_999)
        guard let enumerator = FileManager.default.enumerator(
            at: descriptor,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.corrupt("描述符读不出来")
        }
        for case let fileURL as URL in enumerator {
            guard (try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            switch fileURL.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try Data(String(identifier).utf8).write(to: fileURL, options: .atomic)
            case "com.apple.posterkit.provider.contents.userInfo":
                try setPlistValue(identifier, key: "wallpaperRepresentingIdentifier", at: fileURL)
            case "Wallpaper.plist":
                try setPlistValue(identifier, key: "identifier", at: fileURL)
            default:
                continue
            }
        }
    }

    /// 读一个 plist，改一个 Int 值，原格式写回。
    private static func setPlistValue(_ value: Int, key: String, at url: URL) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw ImportError.corrupt("plist 读不出来：\(url.lastPathComponent)")
        }
        plist[key] = value
        let newData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
        try newData.write(to: url, options: .atomic)
    }

    // MARK: - 从描述符取静态图

    // MARK: - iPhone 版检查（构建 #34）

    /// 这个描述符里有没有 iPhone 版壁纸：任意一个 .wallpaper 文件夹的
    /// 名字含 ~iphone，或它的 Wallpaper.plist 里 logicalScreenClass 含 iphone。
    /// 没有 .wallpaper 文件夹的描述符（比如视频描述符）不拦，返回 true。
    private static func iphoneCapable(in descriptor: URL) -> Bool {
        let dirs = allWallpaperDirs(in: descriptor)
        if dirs.isEmpty { return true }
        return dirs.contains { isIPhoneWallpaper($0) }
    }

    /// 描述符里全部 .wallpaper 文件夹（versions/*/contents/ 下）。
    private static func allWallpaperDirs(in descriptor: URL) -> [URL] {
        let fileManager = FileManager.default
        let versionsDir = descriptor.appendingPathComponent("versions", isDirectory: true)
        guard let versionDirs = try? fileManager.contentsOfDirectory(
            at: versionsDir, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        var result: [URL] = []
        for versionDir in versionDirs {
            guard (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let contentsDir = versionDir.appendingPathComponent("contents", isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(
                at: contentsDir, includingPropertiesForKeys: [.isDirectoryKey], options: []
            ) else { continue }
            for child in children where child.lastPathComponent.hasSuffix(".wallpaper") {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                result.append(child)
            }
        }
        return result
    }

    /// 一个 .wallpaper 文件夹是不是 iPhone 版：文件夹名含 ~iphone，
    /// 或 Wallpaper.plist 的 logicalScreenClass 含 iphone。
    private static func isIPhoneWallpaper(_ dir: URL) -> Bool {
        if dir.lastPathComponent.localizedCaseInsensitiveContains("~iphone") {
            return true
        }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Wallpaper.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let screenClass = plist["logicalScreenClass"] as? String else { return false }
        return screenClass.localizedCaseInsensitiveContains("iphone")
    }

    /// 描述符里找 <*.wallpaper> 文件夹。
    /// 社区包有的用 versions/1/，有的用 versions/0/（比如 Nugget 的
    /// A$AP ROCKY），两个都找；都没有再扫一遍 versions/ 下所有版本。
    private static func findWallpaperDir(in descriptorURL: URL) -> URL? {
        let fileManager = FileManager.default
        let versionsDir = descriptorURL.appendingPathComponent("versions", isDirectory: true)
        // 先按常见顺序找 versions/1/、versions/0/。
        for version in ["1", "0"] {
            let contentsDir = versionsDir
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("contents", isDirectory: true)
            if let found = wallpaperDir(in: contentsDir) {
                return found
            }
        }
        // 兜底：扫 versions/ 下所有版本文件夹。
        guard let versionDirs = try? fileManager.contentsOfDirectory(
            at: versionsDir, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return nil }
        for versionDir in versionDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let contentsDir = versionDir.appendingPathComponent("contents", isDirectory: true)
            if let found = wallpaperDir(in: contentsDir) {
                return found
            }
        }
        return nil
    }

    /// 一个 contents/ 文件夹里找带 Wallpaper.plist 的 <*.wallpaper> 文件夹。
    private static func wallpaperDir(in contentsDir: URL) -> URL? {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: contentsDir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return nil
        }
        for child in children {
            guard child.lastPathComponent.hasSuffix(".wallpaper"),
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let plist = child.appendingPathComponent("Wallpaper.plist")
            if fileManager.fileExists(atPath: plist.path) {
                return child
            }
        }
        return nil
    }

    /// 第一帧完整图片数据：Background .ca 的 assets 里找。
    /// 社区包的图不一定是 .jpg（有 .jpeg、.png，比如 A$AP ROCKY 的
    /// 全是 .png），三种都接受；0.jpg/0.png 优先，否则按名字排第一张。
    /// 找不到返回 nil（记录就不带静态图）。
    private static func firstFrameJPEGData(wallpaperDir: URL) -> Data? {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: wallpaperDir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return nil
        }
        let caDirs = children.filter { $0.lastPathComponent.hasSuffix(".ca") }
        let ordered = caDirs.sorted { a, b in
            let aIsBackground = a.lastPathComponent.contains("Background")
            let bIsBackground = b.lastPathComponent.contains("Background")
            if aIsBackground != bIsBackground { return aIsBackground }
            return a.lastPathComponent < b.lastPathComponent
        }
        for caDir in ordered {
            let assetsDir = caDir.appendingPathComponent("assets", isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil, options: []) else { continue }
            let images = files.filter {
                let lower = $0.lastPathComponent.lowercased()
                return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !images.isEmpty else { continue }
            let first = images.first { $0.lastPathComponent == "0.jpg" }
                ?? images.first { $0.lastPathComponent == "0.png" }
                ?? images[0]
            return try? Data(contentsOf: first)
        }
        return nil
    }

    // MARK: - ZIP 解压

    /// 中央目录里的一条记录。
    private struct CentralEntry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let isDirectory: Bool
    }

    /// 解一个 ZIP 到目标目录（不存在则创建）：读中央目录，逐条按
    /// local header 定位数据，stored 直接拷，deflate 用 inflate 解，
    /// 每条校验 CRC32 和解压后大小。目录条目只建目录。
    private static func extractZip(data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let entries = try readCentralDirectory(data: data)
        guard !entries.isEmpty else { throw ImportError.notZip }
        for entry in entries {
            if entry.isDirectory {
                let dirURL = destination.appendingPathComponent(entry.name, isDirectory: true)
                try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
                continue
            }
            let rawData = try readLocalData(data: data, entry: entry)
            let content: Data
            switch entry.method {
            case 0:
                content = rawData
            case 8:
                content = try inflate(data: rawData)
            default:
                throw ImportError.unsupportedMethod(entry.method)
            }
            guard content.count == Int(entry.uncompressedSize) else {
                throw ImportError.corrupt("条目 \(entry.name) 解压后大小不对")
            }
            guard crc32(content) == entry.crc else {
                throw ImportError.corrupt("条目 \(entry.name) CRC 校验失败")
            }
            let fileURL = destination.appendingPathComponent(entry.name)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, options: .atomic)
        }
    }

    /// 读中央目录：先找 EOCD（签名 0x06054b50，从文件尾往前最多搜 64KB），
    /// 再按 EOCD 里的条目数和起始偏移逐条读（签名 0x02014b50）。
    private static func readCentralDirectory(data: Data) throws -> [CentralEntry] {
        guard data.count >= 22 else { throw ImportError.notZip }
        let eocdSignature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let searchStart = data.count > 65557 ? data.count - 65557 : 0
        var eocdOffset: Int?
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == eocdSignature[0], data[i + 1] == eocdSignature[1],
               data[i + 2] == eocdSignature[2], data[i + 3] == eocdSignature[3] {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ImportError.notZip }
        // EOCD +10 是总条目数（UInt16 小端）。
        let totalEntries = Int(try u16(data, eocd + 10))
        guard totalEntries > 0 else { throw ImportError.notZip }
        let centralOffset = Int(try u32(data, eocd + 16))
        var entries: [CentralEntry] = []
        var offset = centralOffset
        for _ in 0..<totalEntries {
            guard offset + 46 <= data.count,
                  data[offset] == 0x50, data[offset + 1] == 0x4b,
                  data[offset + 2] == 0x01, data[offset + 3] == 0x02 else {
                throw ImportError.corrupt("中央目录损坏")
            }
            let method = try u16(data, offset + 10)
            let crc = try u32(data, offset + 16)
            let compressedSize = try u32(data, offset + 20)
            let uncompressedSize = try u32(data, offset + 24)
            let nameLength = Int(try u16(data, offset + 28))
            let extraLength = Int(try u16(data, offset + 30))
            let commentLength = Int(try u16(data, offset + 32))
            let localHeaderOffset = try u32(data, offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else {
                throw ImportError.corrupt("中央目录文件名越界")
            }
            let nameData = data[nameStart..<(nameStart + nameLength)]
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ImportError.corrupt("中央目录文件名不是 UTF-8")
            }
            entries.append(CentralEntry(
                name: name,
                method: method,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                isDirectory: name.hasSuffix("/")
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// 按 local header 定位一条记录的压缩数据：local header 签名
    /// 0x04034b50，文件名长在 +26，extra 长在 +28，数据从
    /// +30+文件名长+extra长 开始，长度取中央目录的 compressedSize
    /// （不依赖 local header 里的尺寸——带 data descriptor 的包
    /// local header 里尺寸是 0）。返回压缩数据的原始字节。
    private static func readLocalData(data: Data, entry: CentralEntry) throws -> Data {
        let offset = Int(entry.localHeaderOffset)
        guard offset + 30 <= data.count,
              data[offset] == 0x50, data[offset + 1] == 0x4b,
              data[offset + 2] == 0x03, data[offset + 3] == 0x04 else {
            throw ImportError.corrupt("local header 损坏：\(entry.name)")
        }
        let nameLength = Int(try u16(data, offset + 26))
        let extraLength = Int(try u16(data, offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataStart <= data.count, dataEnd <= data.count else {
            throw ImportError.corrupt("条目数据越界：\(entry.name)")
        }
        return data[dataStart..<dataEnd]
    }

    /// 小端读 UInt16，越界抛错。
    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset + 2 <= data.count else { throw ImportError.corrupt("ZIP 结构越界") }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// 小端读 UInt32，越界抛错。
    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ImportError.corrupt("ZIP 结构越界") }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - CRC32

    /// CRC-32（IEEE，多项式 0xEDB88320），和 TendiesExporter 里的同一套。
    private static let crc32Table: [UInt32] = {
        (0..<256).map { i in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
            }
            return crc
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - inflate（RFC 1951，纯 Swift）

    private enum InflateError: LocalizedError {
        case truncated
        case badBlockType
        case badCode
        case badDistance

        var errorDescription: String? {
            switch self {
            case .truncated: return "deflate 数据截断"
            case .badBlockType: return "deflate 块类型无效"
            case .badCode: return "deflate 哈夫曼码无效"
            case .badDistance: return "deflate 距离超出已解压范围"
            }
        }
    }

    /// 按位读（低位在前，和 DEFLATE 的位序一致）。
    private struct BitReader {
        let data: Data
        var pos: Int
        var bitBuffer: UInt32 = 0
        var bitCount: Int = 0

        mutating func bits(_ count: Int) throws -> Int {
            guard count > 0 else { return 0 }
            while bitCount < count {
                guard pos < data.count else { throw InflateError.truncated }
                bitBuffer |= UInt32(data[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            let value = Int(bitBuffer & UInt32((1 << count) - 1))
            bitBuffer >>= count
            bitCount -= count
            return value
        }

        /// stored 块要求对齐到字节边界：丢掉当前字节里剩下的位。
        mutating func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }
    }

    /// 规范哈夫曼表：counts[码长] 是该长度的码字数，symbols 按码长
    /// 分组、按码值升序排（canonical 排序）。
    private struct HuffmanTable {
        let counts: [Int]
        let symbols: [Int]
    }

    private static func buildTable(lengths: [Int]) throws -> HuffmanTable {
        var counts = [Int](repeating: 0, count: 16)
        for len in lengths {
            guard len >= 0 && len <= 15 else { throw InflateError.badCode }
            if len > 0 { counts[len] += 1 }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
        let total = counts.reduce(0, +)
        var symbols = [Int](repeating: 0, count: total)
        for (sym, len) in lengths.enumerated() where len > 0 {
            symbols[offsets[len]] = sym
            offsets[len] += 1
        }
        return HuffmanTable(counts: counts, symbols: symbols)
    }

    /// 规范哈夫曼解码：逐位累加码值，和各长度的首个码值比较定位。
    private static func decodeSymbol(reader: inout BitReader, table: HuffmanTable) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for len in 1..<16 {
            code |= try reader.bits(1)
            let count = table.counts[len]
            if code >= first, code - first < count {
                return table.symbols[index + (code - first)]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw InflateError.badCode
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    private static let fixedLiteralLengths = [Int](repeating: 8, count: 144)
        + [Int](repeating: 9, count: 112)
        + [Int](repeating: 7, count: 24)
        + [Int](repeating: 8, count: 8)

    /// 解一个压缩块：字面量直接输出，256 结束，257+ 是长度/距离对
    /// （从已输出的窗口里复制，支持重叠复制）。
    private static func inflateBlock(reader: inout BitReader, output: inout [UInt8], litTable: HuffmanTable, distTable: HuffmanTable) throws {
        while true {
            let sym = try decodeSymbol(reader: &reader, table: litTable)
            if sym == 256 { return }
            if sym < 256 {
                output.append(UInt8(sym))
            } else {
                let li = sym - 257
                guard li < lengthBase.count else { throw InflateError.badCode }
                let length = lengthBase[li] + (try reader.bits(lengthExtra[li]))
                let dsym = try decodeSymbol(reader: &reader, table: distTable)
                guard dsym < distanceBase.count else { throw InflateError.badCode }
                let distance = distanceBase[dsym] + (try reader.bits(distanceExtra[dsym]))
                guard distance <= output.count else { throw InflateError.badDistance }
                var start = output.count - distance
                for _ in 0..<length {
                    output.append(output[start])
                    start += 1
                }
            }
        }
    }

    /// 解 raw deflate 流：循环读块（BFINAL/BTYPE），0 = stored，
    /// 1 = 固定哈夫曼，2 = 动态哈夫曼，3 非法。
    private static func inflate(data: Data) throws -> Data {
        var reader = BitReader(data: data, pos: 0)
        var output: [UInt8] = []
        while true {
            let bfinal = try reader.bits(1)
            let btype = try reader.bits(2)
            switch btype {
            case 0:
                reader.alignToByte()
                guard reader.pos + 4 <= data.count else { throw InflateError.truncated }
                let len = Int(data[reader.pos]) | (Int(data[reader.pos + 1]) << 8)
                reader.pos += 4
                guard reader.pos + len <= data.count else { throw InflateError.truncated }
                output.append(contentsOf: data[reader.pos..<(reader.pos + len)])
                reader.pos += len
            case 1:
                let litTable = try buildTable(lengths: fixedLiteralLengths)
                let distTable = try buildTable(lengths: [Int](repeating: 5, count: 30))
                try inflateBlock(reader: &reader, output: &output, litTable: litTable, distTable: distTable)
            case 2:
                let hlit = try reader.bits(5) + 257
                let hdist = try reader.bits(5) + 1
                let hclen = try reader.bits(4) + 4
                var codeLengths = [Int](repeating: 0, count: 19)
                for i in 0..<hclen {
                    codeLengths[codeLengthOrder[i]] = try reader.bits(3)
                }
                let clTable = try buildTable(lengths: codeLengths)
                var lengths = [Int](repeating: 0, count: hlit + hdist)
                var i = 0
                while i < hlit + hdist {
                    let s = try decodeSymbol(reader: &reader, table: clTable)
                    if s < 16 {
                        lengths[i] = s
                        i += 1
                    } else if s == 16 {
                        guard i > 0 else { throw InflateError.badCode }
                        let repeatCount = 3 + (try reader.bits(2))
                        let value = lengths[i - 1]
                        for _ in 0..<repeatCount {
                            guard i < lengths.count else { throw InflateError.badCode }
                            lengths[i] = value
                            i += 1
                        }
                    } else if s == 17 {
                        let repeatCount = 3 + (try reader.bits(3))
                        for _ in 0..<repeatCount {
                            guard i < lengths.count else { throw InflateError.badCode }
                            lengths[i] = 0
                            i += 1
                        }
                    } else {
                        let repeatCount = 11 + (try reader.bits(7))
                        for _ in 0..<repeatCount {
                            guard i < lengths.count else { throw InflateError.badCode }
                            lengths[i] = 0
                            i += 1
                        }
                    }
                }
                let litTable = try buildTable(lengths: Array(lengths[0..<hlit]))
                let distTable = try buildTable(lengths: Array(lengths[hlit...]))
                try inflateBlock(reader: &reader, output: &output, litTable: litTable, distTable: distTable)
            default:
                throw InflateError.badBlockType
            }
            if bfinal == 1 { break }
        }
        return Data(output)
    }
}
