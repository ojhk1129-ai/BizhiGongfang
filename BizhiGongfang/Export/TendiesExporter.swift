import Foundation
import UIKit

/// .tendies 导出：把一个 PosterBoard 描述符文件夹打成 .tendies 文件。
///
/// .tendies 就是改了后缀的 ZIP（Camlo / Nugget / Pocket Poster / Placard
/// 的约定）：里面是 `descriptors/<UUID>/`，UUID 文件夹就是
/// DescriptorBuilder 生成的描述符文件夹原样。导入方（Camlo“导入外部
/// .tendies 壁纸包”、Nugget、Pocket Poster、Placard）解压后按
/// `descriptors` 文件夹找描述符，写进 PosterBoard（见 Placard 的
/// WallpaperInstaller.findDescriptorGroups / extract）。
///
/// 导出不依赖直写可用性：不用 App Group，不走 worse_query，不找
/// PosterBoard 容器——iOS 版本太老、直写被封堵时也能导出（Camlo 原话：
/// “App Group entitlement missing; direct apply unavailable,
/// .tendies export works normally”）。
///
/// ZIP 用纯 Swift 手写（stored，不压缩，不引第三方库）：JPEG 本身已压缩，
/// 存了也不大；格式按 ZIP 规范（local file header + central directory +
/// end of central directory，CRC32 算对，目录项以 / 结尾，文件名 UTF-8），
/// ZIPFoundation / FileManager.unzipItem / Camlo 都能解。写完用
/// FileManager.unzipItem 自检一次，解不开或缺 Wallpaper.plist 就抛错，
/// 不返回坏文件。
enum TendiesExporter {

    enum ExportError: LocalizedError {
        case descriptorMissing
        case stillImageMissing
        case frameEncodingFailed
        case writeFailed(Error?)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .descriptorMissing: return "描述符文件夹不存在"
            case .stillImageMissing: return "找不到静态图文件"
            case .frameEncodingFailed: return "图片渲染失败"
            case .writeFailed(let error): return "写 .tendies 失败：\(error?.localizedDescription ?? "未知错误")"
            case .verificationFailed: return ".tendies 自检失败（解不开或缺 Wallpaper.plist）"
            }
        }
    }

    /// 帧尺寸：和直写一致，1080×1920（单帧探针已证实能渲染）。
    static let frameSize = CGSize(width: 1080, height: 1920)

    // MARK: - 入口

    /// 主入口：把一个描述符文件夹（UUID 命名）打成 .tendies。
    /// ZIP 内结构：`descriptors/<UUID>/...`（描述符文件夹全部内容，
    /// 含隐藏文件——contents 里有个以点开头的
    /// `.com.apple.posterkit.provider.contents.configurableOptions.plist`，
    /// 必须包含；空目录也写入目录项）。返回 .tendies 文件地址
    /// （在临时目录里，分享面板用完系统会自己清理）。
    static func exportDescriptor(_ descriptorURL: URL, name: String) throws -> URL {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: descriptorURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw ExportError.descriptorMissing
        }
        let uuid = descriptorURL.lastPathComponent
        let exportDir = fileManager.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Tendies-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let tendiesURL = exportDir.appendingPathComponent("\(sanitizedFileName(name)).tendies")
        do {
            let entries = try collectEntries(descriptorURL: descriptorURL, uuid: uuid)
            let zipData = buildZip(entries: entries)
            try zipData.write(to: tendiesURL, options: .atomic)
            try verify(tendiesURL: tendiesURL, uuid: uuid)
        } catch let error as ExportError {
            try? fileManager.removeItem(at: tendiesURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tendiesURL)
            throw ExportError.writeFailed(error)
        }
        return tendiesURL
    }

    /// 变身：两张照片 → 2 态滑动解锁描述符 → .tendies。
    /// 和一键写入（injectTwoStateMorph）是同一个描述符，只是最后一步
    /// 改成打包分享，不写进 PosterBoard。
    static func exportTwoStateMorph(
        imageA: UIImage,
        imageB: UIImage,
        slide: Bool,
        name: String
    ) throws -> URL {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        guard let (lockJPEG, unlockJPEG) = DescriptorBuilder.renderTwoStateJPEGs(
            imageA: imageA, imageB: imageB, size: frameSize
        ) else {
            throw ExportError.frameEncodingFailed
        }
        let descriptor = try DescriptorBuilder.buildTwoStateMorphDescriptor(
            lockJPEG: lockJPEG,
            unlockJPEG: unlockJPEG,
            size: frameSize,
            slide: slide,
            in: workspace
        )
        return try exportDescriptor(descriptor, name: name)
    }

    /// 单张照片：静态 .tendies（1080×1920 单帧描述符）。
    /// 变身记录没有原图 B 时也用这条路降级导出（静态版）。
    static func exportSinglePhoto(image: UIImage, name: String) throws -> URL {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let descriptor = try DescriptorBuilder.buildSinglePhotoDescriptor(
            image: image, size: frameSize, in: workspace
        )
        return try exportDescriptor(descriptor, name: name)
    }

    /// 景深：按 drawer 一帧一帧画出来的描述符 → .tendies，
    /// 和一键写入（injectFromDrawer）同一套 drawer、帧数、尺寸。
    static func exportFromDrawer(
        frameCount: Int,
        duration: TimeInterval,
        outputSize: CGSize,
        drawer: @escaping VideoRenderer.FrameDrawer,
        name: String
    ) throws -> URL {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let descriptor = try DescriptorBuilder.buildDescriptorFromDrawer(
            frameCount: frameCount,
            duration: duration,
            outputSize: outputSize,
            drawer: drawer,
            in: workspace
        )
        return try exportDescriptor(descriptor, name: name)
    }

    /// 视频 MOV → 45 帧描述符 → .tendies（记录页的视频/景深记录用）。
    static func exportVideo(videoURL: URL, name: String) async throws -> URL {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let descriptor = try await DescriptorBuilder.buildDescriptor(from: videoURL, in: workspace)
        return try exportDescriptor(descriptor, name: name)
    }

    // MARK: - 打包

    /// 临时工作目录：描述符先建在这里，打完包就删（.tendies 文件本身
    /// 在另一个临时目录里，不受影响）。
    private static func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Tendies-Work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// 文件名清理：去掉 / \ : * ? " < > | 和控制字符，首尾去空白；
    /// 清完是空的就用“壁纸”。默认名“变身壁纸 11-21 15:30”里的冒号会变“-”。
    private static func sanitizedFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(100))
        return trimmed.isEmpty ? "壁纸" : trimmed
    }

    /// 一个 ZIP 条目：路径是 ZIP 内的相对路径（/ 分隔，目录以 / 结尾），
    /// data 是文件内容（目录为空）。
    private struct ZipEntry {
        let path: String
        let data: Data
        let isDirectory: Bool
    }

    /// 递归收描述符文件夹的全部内容：每个文件一条，含隐藏文件
    /// （不用 .skipsHiddenFiles，点开头的文件也要）；每个目录也一条
    /// （含空目录）。按路径排好序，保证父目录排在子项前面。
    private static func collectEntries(descriptorURL: URL, uuid: String) throws -> [ZipEntry] {
        let fileManager = FileManager.default
        var entries: [ZipEntry] = [ZipEntry(path: "descriptors/\(uuid)/", data: Data(), isDirectory: true)]
        guard let enumerator = fileManager.enumerator(
            at: descriptorURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            throw ExportError.writeFailed(nil)
        }
        let baseCount = descriptorURL.pathComponents.count
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let relative = url.pathComponents.dropFirst(baseCount).joined(separator: "/")
            guard !relative.isEmpty else { continue }
            let zipPath = "descriptors/\(uuid)/" + relative
            if values.isDirectory == true {
                entries.append(ZipEntry(path: zipPath + "/", data: Data(), isDirectory: true))
            } else if values.isRegularFile == true {
                let data = try Data(contentsOf: url)
                entries.append(ZipEntry(path: zipPath, data: data, isDirectory: false))
            }
            // 符号链接等其他类型直接跳过（描述符里不应该有）
        }
        entries.sort { $0.path < $1.path }
        return entries
    }

    /// 纯 Swift 写 ZIP（stored，method 0，不压缩）：
    /// 每个条目一个 local file header + 内容，最后是 central directory +
    /// end of central directory。CRC32 和尺寸直接写进 local header
    /// （不设 data descriptor 标志位），文件名 UTF-8（flag bit 11）。
    private static func buildZip(entries: [ZipEntry]) -> Data {
        var zip = Data()
        var central: [(entry: ZipEntry, offset: UInt32, crc: UInt32)] = []
        let (dosTime, dosDate) = dosDateTime(Date())
        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = entry.isDirectory ? 0 : crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(zip.count)
            zip.appendUInt32(0x04034b50)   // local file header signature
            zip.appendUInt16(20)           // version needed to extract
            zip.appendUInt16(0x0800)       // general purpose flag: UTF-8
            zip.appendUInt16(0)            // method: stored
            zip.appendUInt16(dosTime)
            zip.appendUInt16(dosDate)
            zip.appendUInt32(crc)
            zip.appendUInt32(size)         // compressed size（= 原大小）
            zip.appendUInt32(size)         // uncompressed size
            zip.appendUInt16(UInt16(nameData.count))
            zip.appendUInt16(0)            // extra field length
            zip.append(nameData)
            zip.append(entry.data)
            central.append((entry, offset, crc))
        }
        let centralOffset = UInt32(zip.count)
        for (entry, offset, crc) in central {
            let nameData = Data(entry.path.utf8)
            let size = UInt32(entry.data.count)
            zip.appendUInt32(0x02014b50)   // central file header signature
            zip.appendUInt16(20)           // version made by
            zip.appendUInt16(20)           // version needed to extract
            zip.appendUInt16(0x0800)
            zip.appendUInt16(0)
            zip.appendUInt16(dosTime)
            zip.appendUInt16(dosDate)
            zip.appendUInt32(crc)
            zip.appendUInt32(size)
            zip.appendUInt32(size)
            zip.appendUInt16(UInt16(nameData.count))
            zip.appendUInt16(0)            // extra field length
            zip.appendUInt16(0)            // comment length
            zip.appendUInt16(0)            // disk number start
            zip.appendUInt16(0)            // internal attributes
            zip.appendUInt32(entry.isDirectory ? 0x10 : 0)  // external attributes（目录置位）
            zip.appendUInt32(offset)
            zip.append(nameData)
        }
        let centralSize = UInt32(zip.count) - centralOffset
        zip.appendUInt32(0x06054b50)       // end of central directory signature
        zip.appendUInt16(0)                // disk number
        zip.appendUInt16(0)                // central directory start disk
        zip.appendUInt16(UInt16(central.count))
        zip.appendUInt16(UInt16(central.count))
        zip.appendUInt32(centralSize)
        zip.appendUInt32(centralOffset)
        zip.appendUInt16(0)                // comment length
        return zip
    }

    /// 自检：用系统 API 把刚生成的 .tendies 解到临时目录，
    /// 确认能解出 descriptors/<UUID>/ 且里面有 Wallpaper.plist，
    /// 否则抛错，不返回坏文件。
    private static func verify(tendiesURL: URL, uuid: String) throws {
        let fileManager = FileManager.default
        let checkDir = fileManager.temporaryDirectory
            .appendingPathComponent("BizhiGongfang-Tendies-Check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: checkDir) }
        do {
            try fileManager.createDirectory(at: checkDir, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: tendiesURL, to: checkDir)
        } catch {
            throw ExportError.verificationFailed
        }
        let plistURL = checkDir
            .appendingPathComponent("descriptors/\(uuid)/versions/1/contents/\(DescriptorBuilder.wallpaperFileName)/Wallpaper.plist")
        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw ExportError.verificationFailed
        }
    }

    // MARK: - CRC32 / DOS 时间

    /// CRC-32（IEEE，多项式 0xEDB88320），ZIP 校验用。
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

    /// ZIP 里的 DOS 日期时间（年从 1980 起，秒只存一半精度）。
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, dosDate)
    }
}

private extension Data {
    /// 小端写一个 UInt16。
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    /// 小端写一个 UInt32。
    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }
}
