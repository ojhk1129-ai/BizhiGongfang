import Foundation

/// 对照测试描述符：完整的真实 Cipher.tendies 描述符原样嵌进 App，只改两处。
///
/// 来源：SerStars/nugget-wallpapers 的 Cipher.tendies，描述符
/// 09E9B685-7456-4856-9C10-47DF26B76C33（源自苹果 WWDC22 模板）。
/// 数据在 ControlDescriptorData.swift 里（机器生成，80 个文件，逐文件 base64；
/// __MACOSX / .DS_Store / ._* 已剔除，Camlo 归一化时也会删掉它们）。
///
/// 写入时只改：
/// 1. 描述符文件夹换一个新的随机 UUID（写路径 writeDescriptors 本来就会换）；
/// 2. 三个地方的 identifier 换成同一个新的递减 ID（照 DescriptorBuilder 的
///    三处同步逻辑：描述符 identifier 文件、userInfo 的
///    wallpaperRepresentingIdentifier、Wallpaper.plist 的 identifier）。
/// 其余一律不动：suggestionMetadata.plist 原样保留（7400.DYNAMIC），assets 里
/// 的 identifier（7400）也不动（它跟 .ca 文件名绑定，Camlo 的做法），文件名、
/// logicalScreenClass（390w-844h@3x~iphone）、CAML、种子文件全部原样。
/// 这和 Placard 安装社区 .tendies 包的做法一致。
///
/// 用途：分清「画廊不显示」是描述符内容的问题，还是写入环境 / 画廊刷新的问题。
/// - 对照描述符在画廊「收藏」里出现了 → 我们的描述符内容有问题（下一步按
///   INJECT_DIAGNOSIS3.md 的排序逐项改：logicalScreenClass、Foreground 包等）。
/// - 对照描述符也没出现 → 问题不在描述符内容，在写入环境或画廊刷新（再查
///   LiveContainer 文件权限、PosterBoard 是不是真的重启了、画廊索引等）。
enum ControlDescriptor {

    /// 从嵌好的数据重建一份对照描述符文件夹（放在 workspace 里），返回文件夹地址。
    /// 调用方负责把文件夹写进 PosterBoard 后清理 workspace。
    static func buildControlDescriptor(in workspace: URL) throws -> URL {
        let identifier = DescriptorBuilder.nextDescendingIdentifier()
        let descriptorURL = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        for (path, base64) in ControlDescriptorData.files {
            guard let data = Data(base64Encoded: base64) else {
                throw DescriptorBuilder.BuildError.writeFailed(nil)
            }
            let url = descriptorURL.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        // 三处同步改 identifier（与 DescriptorBuilder.makeDescriptorMetadata 相同逻辑）。
        do {
            try Data(String(identifier).utf8).write(
                to: descriptorURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"),
                options: .atomic
            )
            let contentsURL = descriptorURL.appendingPathComponent("versions/1/contents", isDirectory: true)
            try updatePlistValue(
                identifier,
                key: "wallpaperRepresentingIdentifier",
                at: contentsURL.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
            )
            // Wallpaper.plist 在 contents/<名字>.wallpaper 目录下。
            let wallpaperDirs = (try? fileManager.contentsOfDirectory(
                at: contentsURL,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            var updated = false
            for dir in wallpaperDirs where dir.lastPathComponent.hasSuffix(".wallpaper") {
                let wallpaperPlist = dir.appendingPathComponent("Wallpaper.plist")
                if fileManager.fileExists(atPath: wallpaperPlist.path) {
                    try updatePlistValue(identifier, key: "identifier", at: wallpaperPlist)
                    updated = true
                }
            }
            guard updated else { throw DescriptorBuilder.BuildError.writeFailed(nil) }
        } catch let error as DescriptorBuilder.BuildError {
            throw error
        } catch {
            throw DescriptorBuilder.BuildError.writeFailed(error)
        }
        return descriptorURL
    }

    private static func updatePlistValue(_ value: Int, key: String, at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw DescriptorBuilder.BuildError.writeFailed(nil)
        }
        plist[key] = value
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try updated.write(to: url, options: .atomic)
    }
}
