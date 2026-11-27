import Foundation

/// 直写（注入）的错误，中文提示。
/// 错误码对应 worse_query 的返回值（Placard 的 WorseQueryError.from 映射）。
enum InjectError: LocalizedError {
    case invalidPath
    case missingPath
    case resolveFailed
    case createFailed
    case outsideSandbox
    case kernelRejected
    case missingAppGroup
    case cacheUnavailable
    case listFailed
    case containerNotFound
    case queryFailed(Int64)
    case invalidConfiguration
    case wallpaperNotFound
    case wallpaperDeleteFailed

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "目标路径不对（不是绝对路径）"
        case .missingPath: return "目标路径不存在"
        case .resolveFailed: return "系统容器服务加载失败（这个系统版本可能不支持）"
        case .createFailed: return "创建容器查询失败"
        case .outsideSandbox: return "系统拒绝了这次访问（可能已被封堵，或 App Group 不对）"
        case .kernelRejected: return "系统内核拒绝签发读写权（可能已被封堵）"
        case .missingAppGroup: return "没有可用的 App Group：App 必须用带 App Group 的签名安装（SideStore / AltStore 可以，Sideloadly 不行）；在 LiveContainer 里则要看 LiveContainer 本身的签名"
        case .cacheUnavailable: return "App Group 缓存被占用或损坏（可能上次没恢复好），重启 App 再试"
        case .listFailed: return "枚举系统容器失败"
        case .containerNotFound: return "没找到 PosterBoard（锁屏）的容器"
        case .queryFailed(let code): return "直写失败（错误码 \(code)）"
        case .invalidConfiguration: return "壁纸配置路径校验失败"
        case .wallpaperNotFound: return "这张壁纸已经不在了"
        case .wallpaperDeleteFailed: return "系统没有删掉这张壁纸"
        }
    }

    static func from(_ code: Int64) -> InjectError {
        switch code {
        case -255: return .missingPath
        case -1: return .missingAppGroup
        case -2: return .resolveFailed
        case -3: return .createFailed
        case -4: return .cacheUnavailable
        case -5: return .outsideSandbox
        case -6: return .kernelRejected
        default: return .queryFailed(code)
        }
    }
}

/// 一次 worse_query 拿到的读写权句柄；不用时自动释放。
/// 注意：句柄只在持有期间有效，读写操作必须在释放前做完。
private final class WorseQueryHandle {
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    deinit { release() }

    func release() {
        guard value >= 0 else { return }
        worse_query_release(value)
        value = -1
    }
}

/// PosterBoard（系统锁屏画廊）直写：找容器、读写描述符。
/// 逻辑照 Placard 的 WorseQuery.swift（GPL-3.0）改写，并加了 LiveContainer
/// 的替身 App Group 修正（用 token 反推真实 group 路径）。
enum PosterBoardStore {

    static let posterBoardBundleID = "com.apple.PosterBoard"
    static let providerID = DescriptorBuilder.providerID

    private static let metadataName = ".com.apple.mobile_container_manager.metadata.plist"
    private static let cachedPathKey = "PosterBoardContainerPath"
    private static let cachedHashKey = "PosterBoardContainerHash"

    private static let containerRoots = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/mobile/Containers/Data/PluginKitPlugin"
    ]

    /// 直写是否可能可用：真机 + iOS 26 以上。模拟器上一定不行。
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard #available(iOS 26.0, *) else { return false }
        return true
        #endif
    }

    // MARK: - App Group

    /// 签名里带的 App Group（按 GestaltAppGroupResolver 的顺序）。
    static func signedGroups() -> [String] {
        GestaltAppGroupResolver.usableAppGroups()
    }

    /// 可用的 (group, 真实 group 根目录) 列表。
    /// 排序：NSFileManager 路径和 token 路径一致的 group 排在前面——在
    /// LiveContainer 里，那通常就是 LiveContainer 自己用的 group（WQFiles 的做法）。
    static func usableGroups() -> [(group: String, root: String)] {
        var result: [(group: String, root: String, agrees: Bool)] = []
        for group in signedGroups() {
            guard let root = bizhi_group_root(group) else { continue }
            let fmPath = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group)?.path
            let agrees = fmPath.map { bizhi_canonical_var_path($0) == root } ?? false
            result.append((group, root, agrees))
        }
        return result
            .sorted { $0.agrees && !$1.agrees }
            .map { ($0.group, $0.root) }
    }

    // MARK: - 启动恢复：修好上次崩溃留下的缓存交换

    /// App 启动时调一次：如果上次查询中途崩溃，Library/Caches 可能还留着
    /// 一个指向别处的符号链接，导致之后所有直写都被拒绝。这里把它拆掉，
    /// 把备份的原缓存移回来（没有备份就新建一个空目录）。
    /// 返回修好的情况说明（空数组 = 没什么要修的）。
    @discardableResult
    static func recoverBrokenCacheSwap() -> [String] {
        var fixed: [String] = []
        let fileManager = FileManager.default
        for (group, root) in usableGroups() {
            let libraryURL = URL(fileURLWithPath: root)
                .appendingPathComponent("Library", isDirectory: true)
            let cachesURL = libraryURL.appendingPathComponent("Caches", isDirectory: true)
            guard let attrs = try? fileManager.attributesOfItem(atPath: cachesURL.path),
                  let type = attrs[.type] as? FileAttributeType,
                  type == .typeSymbolicLink else { continue }
            // Caches 还是个链接：上次没恢复好
            try? fileManager.removeItem(at: cachesURL)
            let entries = (try? fileManager.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )) ?? []
            let backups = entries
                .filter { $0.lastPathComponent.hasPrefix(".bizhigongfang-cache-") }
                .sorted {
                    let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            if let newest = backups.first,
               (try? fileManager.moveItem(at: newest, to: cachesURL)) != nil {
                fixed.append("\(group)：缓存已从备份恢复")
            } else {
                try? fileManager.createDirectory(at: cachesURL, withIntermediateDirectories: false)
                fixed.append("\(group)：残留的缓存链接已清理，新建了空缓存目录")
            }
            for extra in backups.dropFirst() {
                try? fileManager.removeItem(at: extra)
            }
        }
        return fixed
    }

    // MARK: - 找 PosterBoard 容器

    /// 找到 PosterBoard 容器的 UUID（hash），找不到就抛错。
    /// 结果会缓存到 UserDefaults，下次先验证缓存（仍有效就直接用）。
    static func findPosterBoardHash() throws -> String {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        guard !signedGroups().isEmpty else {
            throw InjectError.missingAppGroup
        }
        let defaults = UserDefaults.standard
        let cachedPath = defaults.string(forKey: cachedPathKey)
            ?? defaults.string(forKey: cachedHashKey).map { containerRoots[0] + "/" + $0 }
        if let path = cachedPath, isContainerPath(path),
           (try? bundleID(at: path)) == posterBoardBundleID {
            defaults.set(path, forKey: cachedPathKey)
            return URL(fileURLWithPath: path).lastPathComponent
        }
        defaults.removeObject(forKey: cachedPathKey)
        defaults.removeObject(forKey: cachedHashKey)
        var accessError: Error?
        var foundHash: String?
        let result = placard_visit_containers { path in
            guard isContainerPath(path) else { return false }
            do {
                guard try bundleID(at: path) == posterBoardBundleID else { return false }
                let hash = URL(fileURLWithPath: path).lastPathComponent
                defaults.set(path, forKey: cachedPathKey)
                defaults.set(hash, forKey: cachedHashKey)
                foundHash = hash
                return true
            } catch {
                accessError = error
                return false
            }
        }
        if let foundHash { return foundHash }
        if result < 0 { throw InjectError.listFailed }
        throw accessError ?? InjectError.containerNotFound
    }

    private static let discoveryLock = NSLock()

    private static func isContainerPath(_ path: String) -> Bool {
        containerRoots.contains { root in
            let prefix = root + "/"
            guard path.hasPrefix(prefix) else { return false }
            return UUID(uuidString: String(path.dropFirst(prefix.count))) != nil
        }
    }

    private static func applicationContainerPath(hash: String) -> String {
        if let path = UserDefaults.standard.string(forKey: cachedPathKey),
           isContainerPath(path), URL(fileURLWithPath: path).lastPathComponent == hash {
            return path
        }
        return containerRoots[0] + "/" + hash
    }

    /// 读容器的 bundle ID：先试 xattr（不用读写权就能读），不行再拿读写权读
    /// metadata plist。返回 nil 表示读不到（不一定是错）。
    private static func bundleID(at containerPath: String) throws -> String? {
        if let identifier = placard_container_identifier(containerPath) { return identifier }
        var accessError: Error?
        do {
            let handle = try consume(path: containerPath, create: true)
            defer { handle.release() }
            if let identifier = placard_container_identifier(containerPath) { return identifier }
        } catch { accessError = error }
        for name in [metadataName, "com.apple.mobile_container_manager.metadata.plist"] {
            let path = (containerPath as NSString).appendingPathComponent(name)
            do {
                let handle = try consume(path: path, create: true)
                defer { handle.release() }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = plist["MCMMetadataIdentifier"] as? String else { continue }
                return identifier
            } catch { accessError = error }
        }
        if let accessError { throw accessError }
        return nil
    }

    // MARK: - 描述符存放位置

    /// PRBPosterExtensionDataStore 下的版本目录（取最大的、有 Extensions 的那个）。
    static func storeRoots(appHash: String) throws -> [String] {
        let base = applicationContainerPath(hash: appHash)
            + "/Library/Application Support/PRBPosterExtensionDataStore"
        let handle = try consume(path: base, create: false)
        defer { handle.release() }
        let versions = try FileManager.default.contentsOfDirectory(atPath: base)
            .compactMap(Int.init).filter { $0 >= 0 }.sorted(by: >)
        return versions.compactMap { version in
            let root = base + "/\(version)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root + "/Extensions", isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return root
        }
    }

    /// 某个 provider 的 descriptors 目录（第一个有这个 provider 的版本目录）。
    static func descriptorDestination(appHash: String, provider: String) throws -> String {
        guard !provider.isEmpty, !provider.contains("/"), ![".", ".."].contains(provider) else {
            throw InjectError.invalidConfiguration
        }
        for root in try storeRoots(appHash: appHash) {
            let handle = try consume(path: root, create: false)
            defer { handle.release() }
            let path = root + "/Extensions/" + provider
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return path + "/descriptors"
            }
        }
        throw InjectError.missingPath
    }

    /// 本 App 写入标记的文件名（构建 #34）：写描述符时放一个 0 字节文件进去，
    /// 已装锁屏靠它认出是自己写的。重装 App 会清掉本地记录，但描述符还
    /// 在磁盘上，靠这个标记删按钮就不会丢。社区包里本来就有 .DS_Store
    /// 这类杂文件，PosterBoard 不在乎描述符文件夹里多一个空文件。
    static let writtenMarkerFileName = ".bizhigongfang-written"

    /// 把做好的描述符文件夹写进 PosterBoard，返回写进去后的完整路径。
    /// 每个描述符文件夹都会换成一个全新的 UUID 文件夹名。
    static func writeDescriptors(
        appHash: String,
        provider: String,
        descriptorFolders: [URL]
    ) throws -> [String] {
        let destination = try descriptorDestination(appHash: appHash, provider: provider)
        let handle = try consume(path: destination, create: true)
        defer { handle.release() }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination) {
            try fileManager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        }

        var writtenPaths: [String] = []
        for descriptor in descriptorFolders {
            let target = URL(fileURLWithPath: destination, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.copyItem(at: descriptor, to: target)
            // 打写入标记（构建 #34）：0 字节文件，证明这张是本 App 写的。
            // 失败也不阻塞——标记只是方便认，描述符本身已经写进去了。
            try? Data().write(to: target.appendingPathComponent(Self.writtenMarkerFileName))
            // 写后改权限（构建 #19）：苹果自带的描述符文件夹是 777，我们写的是 755；
            // 快照文件（RuntimeSnapshot-lock.atx）要写进描述符文件夹里，如果快照服务
            // 不是以 mobile 身份写，755 就写不进去。目录 0777、文件 0644。
            // 不抛错：失败只记日志，绝不把一次已成功的写入变成失败。
            fixPermissionsRecursively(at: target.path)
            // 写后设备份排除（构建 #21）：苹果自带的描述符文件夹都有
            // com.apple.metadata:com_apple_backup_excludeItem，我们写的
            // 没有——这是文件权限对照里剩下的最后一个差别。
            setBackupExclude(at: target.path)
            writtenPaths.append(target.path)
        }
        // 写后收尾（镜像、清缓存、写偏好）：在持有的读写权释放前做完。
        // 收尾失败不阻塞——描述符本身已经写进主容器了。
        postWriteRefresh(appHash: appHash, provider: provider, writtenPaths: writtenPaths)
        return writtenPaths
    }

    /// 设备份排除扩展属性（构建 #21）：isExcludedFromBackup 是公开 API，
    /// 设的就是 com.apple.metadata:com_apple_backup_excludeItem——苹果
    /// 自带描述符文件夹上都有的那个。不是伪造系统标记，只是让我们的
    /// 文件夹在备份属性上和苹果的一致。不抛错：失败只记日志。
    private static func setBackupExclude(at path: String) {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            NSLog("[BizhiGongfang] 设备份排除失败 \(path)：\(error)")
        }
    }

    /// 递归改权限：目录 0777、文件 0644（构建 #19，见 writeDescriptors）。
    /// 不抛错：失败只记日志。这里只改权限位，不碰扩展属性；备份排除
    /// xattr 由构建 #21 的 setBackupExclude 另行设置。
    /// 符号链接跳过（不跟过去改目标，避免改到描述符文件夹外面去）。
    /// 隐藏文件也改（比如点号开头的 configurableOptions），所以不用
    /// skipsHiddenFiles。
    private static func fixPermissionsRecursively(at path: String) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                NSLog("[BizhiGongfang] 改权限遍历失败 \(url.path)：\(error)")
                return true
            }
        ) else { return }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            let perms: Int = (values.isDirectory == true) ? 0o777 : 0o644
            do {
                try fileManager.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            } catch {
                NSLog("[BizhiGongfang] 改权限失败 \(url.path)：\(error)")
            }
        }
    }

    /// 写完描述符后的收尾（排障报告 2，修复 2）：镜像到所有含 CollectionsPoster
    /// 的扩展目录、清 GalleryCache、写 PosterBoard 持久化偏好。
    /// 不抛错：收尾失败只记日志，绝不把一次已成功的写入变成失败；
    /// 诊断第 7 步会分容器显示实际状态。
    static func postWriteRefresh(
        appHash: String,
        provider: String,
        writtenPaths: [String]
    ) {
        guard !writtenPaths.isEmpty else { return }
        do {
            let root = try storeRoot(from: writtenPaths, appHash: appHash)
            mirrorDescriptors(provider: provider, writtenPaths: writtenPaths, storeRoot: root)
            clearGalleryCache(storeRoot: root)
        } catch {
            NSLog("[BizhiGongfang] 写后收尾失败（描述符本身已写进）：\(error)")
        }
        writePosterBoardPreferences(appHash: appHash)
    }

    /// 从已写入的描述符路径反推版本目录（storeRoot）：
    /// writtenPath = <storeRoot>/Extensions/<provider>/descriptors/<uuid>，
    /// 往上 4 层就是 storeRoot。结构不对时退回 storeRoots 的第一个。
    private static func storeRoot(from writtenPaths: [String], appHash: String) throws -> String {
        if let first = writtenPaths.first, first.contains("/Extensions/") {
            var url = URL(fileURLWithPath: first)
            for _ in 0..<4 { url.deleteLastPathComponent() }
            return url.path
        }
        guard let root = try storeRoots(appHash: appHash).first else {
            throw InjectError.missingPath
        }
        return root
    }

    /// 2a. 镜像：把同一批描述符文件夹（同一个 UUID 文件夹名，原样复用，
    /// 不要换新 UUID）复制到 Extensions/ 下所有名字含 CollectionsPoster
    /// （大小写不敏感）且不等于当前 provider 的扩展目录的 descriptors/ 下。
    /// 至少覆盖 com.apple.Posters.CollectionsPosterApp；枚举式镜像能覆盖
    /// 带后缀的变体目录。单个目标失败只记日志，不阻塞其他目标。
    private static func mirrorDescriptors(provider: String, writtenPaths: [String], storeRoot: String) {
        let extensionsRoot = storeRoot + "/Extensions"
        guard let handle = try? consume(path: extensionsRoot, create: false) else {
            NSLog("[BizhiGongfang] 镜像失败：拿不到 Extensions 目录读写权")
            return
        }
        defer { handle.release() }
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: extensionsRoot)) ?? []
        for name in names where name.localizedCaseInsensitiveContains("CollectionsPoster") && name != provider {
            var isDirectory: ObjCBool = false
            let dir = extensionsRoot + "/" + name
            guard fileManager.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let targetDescriptors = dir + "/descriptors"
            if !fileManager.fileExists(atPath: targetDescriptors) {
                try? fileManager.createDirectory(atPath: targetDescriptors, withIntermediateDirectories: true)
            }
            for sourcePath in writtenPaths {
                let folderName = URL(fileURLWithPath: sourcePath).lastPathComponent
                let target = targetDescriptors + "/" + folderName
                if fileManager.fileExists(atPath: target) {
                    try? fileManager.removeItem(atPath: target)
                }
                do {
                    try fileManager.copyItem(atPath: sourcePath, toPath: target)
                    // 镜像过去的也改权限（构建 #19，和主容器一样：目录 0777、文件 0644）。
                    fixPermissionsRecursively(at: target)
                } catch {
                    NSLog("[BizhiGongfang] 镜像到 \(name) 失败：\(error)")
                }
            }
        }
    }

    /// 2b. 清 GalleryCache：删掉 <storeRoot>/GalleryCache 里的全部内容，
    /// 不删目录本身；目录不存在就跳过。
    private static func clearGalleryCache(storeRoot: String) {
        let cachePath = storeRoot + "/GalleryCache"
        guard let handle = try? consume(path: cachePath, create: false) else { return }
        defer { handle.release() }
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: cachePath)) ?? []
        for entry in entries {
            try? fileManager.removeItem(atPath: cachePath + "/" + entry)
        }
    }

    /// 2c. 写 PosterBoard 持久化偏好（Camlo / AirCard 的做法，iOS 26.4+/27）：
    /// PBF_RESET_FILE_PROTECTIONS、PBF_LOCALE_DID_CHANGE、
    /// PersistedPosterContainerBundleIdentifiers、
    /// CompletedPosterBundleIdentifierMigrations。
    /// 写两个位置：PosterBoard 容器内 Library/Preferences 和
    /// /var/mobile/Library/Preferences。已存在的文件先读出合并，
    /// 只增改这几个键，不删已有键。写失败只记日志，不阻塞。
    /// PBF_LOCALE_DID_CHANGE 取 false（Camlo 的值；构建 #15 用的是 AirCard
    /// 的 true）：对照实验——构建 #16 的对照测试证明连原样真包都不渲染，
    /// 原因 5 的怀疑是 true 触发了「地区变更后的全量迁移」，跳过了未登记的
    /// 描述符。改完若画廊出现，说明 true 是问题；若仍不出现，原因 5 排除。
    private static func writePosterBoardPreferences(appHash: String) {
        let fileName = "com.apple.PosterBoard.unprotectedUserDefaults.plist"
        let newKeys: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": false,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
            ]
        ]
        let containerPath = applicationContainerPath(hash: appHash)
            + "/Library/Preferences/" + fileName
        writeMergedPreferences(at: containerPath, merging: newKeys)
        writeMergedPreferences(at: "/var/mobile/Library/Preferences/" + fileName, merging: newKeys)
    }

    /// 把 newKeys 合并进 path 处的 binary plist（已存在先读出，只增改键，
    /// 不删已有键）。拿不到读写权或写失败只记日志，不阻塞。
    private static func writeMergedPreferences(at path: String, merging newKeys: [String: Any]) {
        let parentDir = (path as NSString).deletingLastPathComponent
        guard let handle = try? consume(path: parentDir, create: true) else {
            NSLog("[BizhiGongfang] 写 PosterBoard 偏好失败：拿不到读写权：\(path)")
            return
        }
        defer { handle.release() }
        let fileManager = FileManager.default
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            dict = existing
        }
        for (key, value) in newKeys { dict[key] = value }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) else {
            NSLog("[BizhiGongfang] 写 PosterBoard 偏好失败：plist 编码失败：\(path)")
            return
        }
        do {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("[BizhiGongfang] 写 PosterBoard 偏好失败：\(error)")
        }
    }

    /// Extensions/ 下所有名字含 CollectionsPoster 的 provider 及其描述符张数
    /// （主容器 + 镜像容器），供诊断第 5 步显示和第 7 步分容器核对。
    static func collectionPosterProviderCounts(appHash: String) throws -> [(provider: String, count: Int)] {
        let roots = try storeRoots(appHash: appHash)
        guard let root = roots.first else { throw InjectError.missingPath }
        let extensionsRoot = root + "/Extensions"
        let handle = try consume(path: extensionsRoot, create: false)
        defer { handle.release() }
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: extensionsRoot)) ?? []
        var result: [(provider: String, count: Int)] = []
        for name in names where name.localizedCaseInsensitiveContains("CollectionsPoster") {
            var isDirectory: ObjCBool = false
            let dir = extensionsRoot + "/" + name
            guard fileManager.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let descriptors = dir + "/descriptors"
            let entries = (try? fileManager.contentsOfDirectory(atPath: descriptors)) ?? []
            let count = entries.filter { UUID(uuidString: $0) != nil }.count
            result.append((provider: name, count: count))
        }
        return result.sorted { $0.provider < $1.provider }
    }

    /// 描述符文件夹里有没有系统渲染后生成的快照（RuntimeSnapshot-lock.atx）。
    /// 有 = PosterBoard 加载并渲染过这张描述符（画廊就有了显示它的素材）；
    /// 没有 = 还没渲染过，或者渲染失败了。只读检查，供诊断第 7 步显示。
    /// 注意：这个文件是系统渲染时生成的，描述符本身不带它（真 .tendies 包里
    /// 也没有）；Camlo 归一化时会清掉外来的 .atx，但系统自己生成的这份会留下来。
    static func hasSnapshot(posterUUID: String, provider: String) -> Bool {
        guard UUID(uuidString: posterUUID) != nil,
              let appHash = try? findPosterBoardHash(),
              let destination = try? descriptorDestination(appHash: appHash, provider: provider),
              let handle = try? consume(path: destination, create: false) else { return false }
        defer { handle.release() }
        let versionsURL = URL(fileURLWithPath: destination, isDirectory: true)
            .appendingPathComponent(posterUUID, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return false }
        for version in versions {
            if fileManager.fileExists(atPath: version.appendingPathComponent("RuntimeSnapshot-lock.atx").path) {
                return true
            }
        }
        return false
    }

    /// 描述符文件夹的文件属性（只读）：所有者、POSIX 权限位、扩展属性名。
    /// 供诊断「文件权限对照」区显示——用来判断 LiveContainer 写出的文件
    /// 和苹果自带的是不是同一种所有者/权限（原因 4：快照服务读不到文件）。
    /// 读不到属性时对应字段为 nil，界面显示「读不到」，不抛错、不崩。
    struct DescriptorFileAttributes {
        let uuid: String
        let owner: String?
        let permissions: Int?
        let xattrNames: [String]?
    }

    /// 列出某个 provider 下每个描述符文件夹的文件属性（只读）。
    /// 沿用 hasSnapshot 的读路径：先拿读写权再读，读完释放。
    static func descriptorFileAttributes(provider: String) -> [DescriptorFileAttributes] {
        guard let appHash = try? findPosterBoardHash(),
              let destination = try? descriptorDestination(appHash: appHash, provider: provider),
              let handle = try? consume(path: destination, create: false) else { return [] }
        defer { handle.release() }
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: destination)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted().map { uuid in
            let path = destination + "/" + uuid
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            let owner = attrs?[.ownerAccountName] as? String
            let permissions = (attrs?[.posixPermissions] as? NSNumber)?.intValue
            let xattrs = extendedAttributeNames(atPath: path)
            return DescriptorFileAttributes(uuid: uuid, owner: owner, permissions: permissions, xattrNames: xattrs)
        }
    }

    /// 容器里一张描述符的只读对照信息：Wallpaper.plist 的名字/编号/
    /// 屏幕类、.ca 包（Background/Floating/Foreground 有无）、Background
    /// .ca 里 assets/*.jpg 的帧数、main.caml 的 calculationMode、快照
    /// RuntimeSnapshot-lock.atx 是否存在、文件夹权限和扩展属性。
    /// 读不到的字段为 nil，界面显示「读不到」，不抛错、不崩。
    struct DescriptorSummary {
        let uuid: String
        let name: String?
        let identifier: Int?
        let logicalScreenClass: String?
        let hasBackgroundPackage: Bool
        let hasFloatingPackage: Bool
        let hasForegroundPackage: Bool
        let frameCount: Int?
        let calculationMode: String?
        let hasSnapshot: Bool
        let hasOurMarker: Bool
        let owner: String?
        let permissions: Int?
        let xattrNames: [String]?
    }

    /// 枚举主容器里全部描述符，逐个读出对照字段（只读）。
    /// 拿一次读写权、一次遍历读完。拿不到读写权返回空数组。
    /// 用途：找出那张 iOS 26 时装的、现在还能动的动漫壁纸——它会是
    /// 唯一一个「多帧 + 快照已生成」的描述符，和我们的逐项对照，
    /// 看看到底差在哪（27.0.1 上新写的多帧描述符都拿不到快照）。
    static func allDescriptorSummaries(provider: String) -> [DescriptorSummary] {
        guard let appHash = try? findPosterBoardHash(),
              let destination = try? descriptorDestination(appHash: appHash, provider: provider),
              let handle = try? consume(path: destination, create: false) else { return [] }
        defer { handle.release() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted().map { uuid in
            summarizeDescriptor(uuid: uuid, destination: destination)
        }
    }

    /// 读一张已装描述符的缩略图（只读）：Background .ca 包 assets 里
    /// 的 0.jpg，没有就读第一张 .jpg。读不到返回 nil。
    /// 和 allDescriptorSummaries 一样自己拿 consume 句柄。
    static func thumbnailJPEG(for posterUUID: String, provider: String) -> Data? {
        guard UUID(uuidString: posterUUID) != nil,
              let appHash = try? findPosterBoardHash(),
              let destination = try? descriptorDestination(appHash: appHash, provider: provider),
              let handle = try? consume(path: destination, create: false) else { return nil }
        defer { handle.release() }
        let fileManager = FileManager.default
        let folderPath = destination + "/" + posterUUID

        // 版本目录（按数字从大到小）
        let versionsURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        var versionDirs: [URL] = []
        if let entries = try? fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            versionDirs = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        versionDirs.sort { (Int($0.lastPathComponent) ?? -1) > (Int($1.lastPathComponent) ?? -1) }

        // .wallpaper 文件夹 → Background .ca 包 → assets 里读 0.jpg
        for dir in versionDirs {
            let contentsURL = dir.appendingPathComponent("contents", isDirectory: true)
            let entries = (try? fileManager.contentsOfDirectory(
                at: contentsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            guard let wallpaperURL = entries.first(where: {
                $0.lastPathComponent.hasSuffix(".wallpaper")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) else { continue }
            let packageEntries = (try? fileManager.contentsOfDirectory(
                at: wallpaperURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            guard let backgroundPackage = packageEntries.first(where: {
                $0.lastPathComponent.hasSuffix(".ca")
                    && $0.lastPathComponent.localizedCaseInsensitiveContains("Background")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) else { return nil }
            let assetsURL = backgroundPackage.appendingPathComponent("assets", isDirectory: true)
            let assets = (try? fileManager.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil, options: [])) ?? []
            let jpgs = assets
                .filter { $0.lastPathComponent.lowercased().hasSuffix(".jpg") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let target = jpgs.first(where: { $0.lastPathComponent == "0.jpg" }) ?? jpgs.first
            if let target = target, let data = try? Data(contentsOf: target) {
                return data
            }
            return nil
        }
        return nil
    }

    /// 读一张描述符文件夹的对照字段（只读，句柄由调用方持有）。
    /// 布局：<uuid>/versions/<n>/contents/<名字>.wallpaper/ 里是
    /// Wallpaper.plist 和 *.ca 包；快照在 versions/<n>/ 下。
    /// 版本目录取最大的数字版本；.wallpaper 文件夹取第一个含它的版本。
    private static func summarizeDescriptor(uuid: String, destination: String) -> DescriptorSummary {
        let fileManager = FileManager.default
        let folderPath = destination + "/" + uuid
        let attrs = try? fileManager.attributesOfItem(atPath: folderPath)
        let owner = attrs?[.ownerAccountName] as? String
        let permissions = (attrs?[.posixPermissions] as? NSNumber)?.intValue
        let xattrs = extendedAttributeNames(atPath: folderPath)
        // 本 App 写入标记（构建 #34）：描述符文件夹里有没有那个 0 字节文件。
        let hasOurMarker = fileManager.fileExists(atPath: folderPath + "/" + writtenMarkerFileName)

        // 版本目录（按数字从大到小）
        let versionsURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        var versionDirs: [URL] = []
        if let entries = try? fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            versionDirs = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        versionDirs.sort { (Int($0.lastPathComponent) ?? -1) > (Int($1.lastPathComponent) ?? -1) }

        // 快照：任意版本目录下有 RuntimeSnapshot-lock.atx 就算已生成
        // （和 hasSnapshot 同一套判断）。
        var hasSnapshot = false
        for dir in versionDirs where fileManager.fileExists(
            atPath: dir.appendingPathComponent("RuntimeSnapshot-lock.atx").path) {
            hasSnapshot = true
            break
        }

        // .wallpaper 文件夹：从最新的版本开始找，第一个含它的为准
        var wallpaperURL: URL?
        for dir in versionDirs {
            let contentsURL = dir.appendingPathComponent("contents", isDirectory: true)
            let entries = (try? fileManager.contentsOfDirectory(
                at: contentsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            if let found = entries.first(where: {
                $0.lastPathComponent.hasSuffix(".wallpaper")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) {
                wallpaperURL = found
                break
            }
        }
        guard let wallpaperURL = wallpaperURL else {
            return DescriptorSummary(
                uuid: uuid, name: nil, identifier: nil, logicalScreenClass: nil,
                hasBackgroundPackage: false, hasFloatingPackage: false, hasForegroundPackage: false,
                frameCount: nil, calculationMode: nil, hasSnapshot: hasSnapshot,
                hasOurMarker: hasOurMarker,
                owner: owner, permissions: permissions, xattrNames: xattrs)
        }

        // Wallpaper.plist：名字 / 编号 / 屏幕类
        var plistName: String?
        var plistIdentifier: Int?
        var plistScreenClass: String?
        if let data = try? Data(contentsOf: wallpaperURL.appendingPathComponent("Wallpaper.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plistName = plist["name"] as? String
            plistIdentifier = (plist["identifier"] as? NSNumber)?.intValue
            plistScreenClass = plist["logicalScreenClass"] as? String
        }

        // .ca 包：按文件夹名含 Background / Floating / Foreground 判断
        let packageEntries = (try? fileManager.contentsOfDirectory(
            at: wallpaperURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        let caPackages = packageEntries.filter {
            $0.lastPathComponent.hasSuffix(".ca")
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let backgroundPackage = caPackages.first {
            $0.lastPathComponent.localizedCaseInsensitiveContains("Background")
        }
        let hasFloating = caPackages.contains {
            $0.lastPathComponent.localizedCaseInsensitiveContains("Floating")
        }
        let hasForeground = caPackages.contains {
            $0.lastPathComponent.localizedCaseInsensitiveContains("Foreground")
        }

        // Background .ca 里的帧数（assets/*.jpg）和 CAML 动画模式
        var frameCount: Int?
        var calculationMode: String?
        if let backgroundPackage = backgroundPackage {
            let assetsURL = backgroundPackage.appendingPathComponent("assets", isDirectory: true)
            if let assets = try? fileManager.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil, options: []) {
                frameCount = assets.filter { $0.lastPathComponent.lowercased().hasSuffix(".jpg") }.count
            }
            calculationMode = Self.calculationMode(
                inCAMLAtPath: backgroundPackage.appendingPathComponent("main.caml").path)
        }

        return DescriptorSummary(
            uuid: uuid, name: plistName, identifier: plistIdentifier,
            logicalScreenClass: plistScreenClass,
            hasBackgroundPackage: backgroundPackage != nil,
            hasFloatingPackage: hasFloating, hasForegroundPackage: hasForeground,
            frameCount: frameCount, calculationMode: calculationMode,
            hasSnapshot: hasSnapshot, hasOurMarker: hasOurMarker, owner: owner,
            permissions: permissions, xattrNames: xattrs)
    }

    /// 从 main.caml 文本里读第一个 calculationMode 的值（linear/discrete）。
    /// 找不到返回 nil。真包里 26 个动画全是 discrete，取第一个就够代表；
    /// 我们的模板里第一个就是 contents 逐帧动画。
    private static func calculationMode(inCAMLAtPath path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let range = text.range(of: "calculationMode=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// 列出 path 上的扩展属性名（只读，不读值）。
    /// listxattr 是公开的 BSD API（ObjC 层 ContainerEnumeration.m 也用
    /// 同一头文件 <sys/xattr.h> 的 getxattr 读容器标识）。
    /// 失败返回 nil（读不到），没有扩展属性返回空数组。
    /// 注意：万一 Swift 编译器认不出 listxattr，改走 ObjC 层加一个同名
    /// 的小 helper（getxattr 已在用，listxattr 同一头文件），不用改逻辑。
    private static func extendedAttributeNames(atPath path: String) -> [String]? {
        let size = path.withCString { listxattr($0, nil, 0, 0) }
        guard size >= 0 else { return nil }
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = path.withCString { listxattr($0, &buffer, size, 0) }
        guard read >= 0 else { return nil }
        var names: [String] = []
        var offset = 0
        while offset < read {
            var end = offset
            while end < read && buffer[end] != 0 { end += 1 }
            if end > offset {
                let slice = buffer[offset..<end]
                if let name = String(bytes: slice.map { UInt8(bitPattern: $0) }, encoding: .utf8) {
                    names.append(name)
                }
            }
            offset = end + 1
        }
        return names
    }

    /// 列出某个 provider 下所有描述符的文件夹名（UUID），供诊断和管理用。
    static func listDescriptorUUIDs(provider: String) throws -> [String] {
        let appHash = try findPosterBoardHash()
        let destination = try descriptorDestination(appHash: appHash, provider: provider)
        let handle = try consume(path: destination, create: false)
        defer { handle.release() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted()
    }

    /// 只删我们自己写入的那一张壁纸（按 posterUUID 精确匹配路径）。
    /// 路径校验不过就拒绝，绝不删别的。
    static func deleteDescriptor(posterUUID: String, provider: String) throws {
        guard UUID(uuidString: posterUUID) != nil,
              !provider.isEmpty, !provider.contains("/"),
              ![".", ".."].contains(provider) else {
            throw InjectError.invalidConfiguration
        }
        let appHash = try findPosterBoardHash()
        let roots = try storeRoots(appHash: appHash)
        guard !roots.isEmpty else { throw InjectError.wallpaperNotFound }
        // 先对整个 PRBPosterExtensionDataStore 拿读写权（token 覆盖该目录下的
        // 所有版本目录），之后的存在性检查和删除才能看到目标路径。
        let base = applicationContainerPath(hash: appHash)
            + "/Library/Application Support/PRBPosterExtensionDataStore"
        let handle = try consume(path: base, create: false)
        defer { handle.release() }
        let expectedSuffix = "/Extensions/\(provider)/descriptors/\(posterUUID)"
        for root in roots {
            let targetPath = root + expectedSuffix
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            // 再校验一次：必须是这个 storeRoot 下的 descriptors/<uuid>
            guard targetPath.hasPrefix(root + "/Extensions/") else {
                throw InjectError.invalidConfiguration
            }
            try FileManager.default.removeItem(atPath: targetPath)
            guard !FileManager.default.fileExists(atPath: targetPath) else {
                throw InjectError.wallpaperDeleteFailed
            }
            // 顺手把快照索引里的这条也清掉（失败也没关系，重启后系统会重建）
            let indexPath = (root as NSString).appendingPathComponent("PRPosterRoleLockScreen-gallery-index.json")
            try? removePoster(uuid: posterUUID, fromIndexAt: indexPath)
            // 顺手把镜像容器里的同一份也清掉：写后收尾会把同一 UUID 文件夹
            // 镜像到其他 CollectionsPoster 扩展目录，只删主容器那份会在
            // 镜像容器里留下一份孤儿。镜像删失败只记日志，不阻塞主删除。
            let extensionsRoot = root + "/Extensions"
            let mirrorNames = (try? FileManager.default.contentsOfDirectory(atPath: extensionsRoot)) ?? []
            for name in mirrorNames where name.localizedCaseInsensitiveContains("CollectionsPoster") && name != provider {
                let mirrorPath = extensionsRoot + "/" + name + "/descriptors/" + posterUUID
                guard mirrorPath.hasPrefix(root + "/Extensions/") else { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: mirrorPath, isDirectory: &isDir), isDir.boolValue else { continue }
                do {
                    try FileManager.default.removeItem(atPath: mirrorPath)
                } catch {
                    NSLog("[BizhiGongfang] 删镜像容器 \(name) 的描述符失败：\(error)")
                }
            }
            return
        }
        throw InjectError.wallpaperNotFound
    }

    private static func removePoster(uuid: String, fromIndexAt path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = root["entries"] as? [String: Any] else { return }
        entries = entries.filter { _, value in
            guard let entry = value as? [String: Any] else { return true }
            return entry["posterUUID"] as? String != uuid
        }
        root["entries"] = entries
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    // MARK: - 拿读写权（worse_query）

    /// 所有查询共用同一把锁：同一时间只能有一个查询在换 Library/Caches。
    private static let queryLock = NSLock()

    /// 对 path 拿一个 worse_query 读写权。create 为 false 时要求 path 必须存在。
    /// 返回的句柄在释放前一直有效；调用方用 defer { handle.release() }。
    private static func consume(path: String, create: Bool) throws -> WorseQueryHandle {
        guard path.hasPrefix("/") else { throw InjectError.invalidPath }
        queryLock.lock()
        defer { queryLock.unlock() }
        let groups = usableGroups()
        guard !groups.isEmpty else { throw InjectError.missingAppGroup }
        var failure: Int64 = -1
        // iOS 26 要用另一组 flags（alt），iOS 27 用标准 flags
        let altFlags = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
        let normalized = path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
        for (group, root) in groups {
            // 用 token 反推出的真实 group 根目录做交换（LiveContainer 下
            // NSFileManager 给的是替身路径，直接用会失败）。
            let result = worse_query_at_root(normalized, group, root, altFlags, true)
            if result >= 0 {
                let handle = WorseQueryHandle(result)
                if !create && !FileManager.default.fileExists(atPath: path) {
                    handle.release()
                    throw InjectError.missingPath
                }
                return handle
            }
            failure = result
        }
        throw InjectError.from(failure)
    }
}
