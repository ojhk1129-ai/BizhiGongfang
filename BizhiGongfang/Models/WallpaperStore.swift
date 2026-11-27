import Foundation
import UIKit

/// 一张已制作的壁纸。
struct WallpaperItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case morph
        case depth
        case video
        case gradient

        var displayName: String {
            switch self {
            case .morph: return "变身壁纸"
            case .depth: return "景深壁纸"
            case .video: return "视频壁纸"
            case .gradient: return "渐变壁纸"
            }
        }
    }

    let id: UUID
    var name: String
    let kind: Kind
    let createdAt: Date
    let stillImageTime: Double
    /// 已一键写入锁屏画廊时才有：PosterBoard 里那张描述符的 UUID。
    /// 删锁屏壁纸时就按这个精确删，只删这一张。
    let injectedPosterUUID: String?
    let injectedAt: Date?
    let injectedProvider: String?

    /// 显式初始化器：带默认值的三个注入字段也必须写进来——编译器只给没有
    /// 默认值的属性合成 memberwise init，不写这段的话 markInjected 那处
    /// 传 8 个参数会报 extra arguments。
    init(
        id: UUID,
        name: String,
        kind: Kind,
        createdAt: Date,
        stillImageTime: Double,
        injectedPosterUUID: String? = nil,
        injectedAt: Date? = nil,
        injectedProvider: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.stillImageTime = stillImageTime
        self.injectedPosterUUID = injectedPosterUUID
        self.injectedAt = injectedAt
        self.injectedProvider = injectedProvider
    }
}

/// 已制作壁纸的本地保存：元数据存 JSON，文件存在 Documents/Wallpapers/<id>/ 下。
/// 每个壁纸一个文件夹：still.jpg（静态图）、video.mov（视频）、thumb.jpg（缩略图）。
final class WallpaperStore: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var folderURL: URL {
        documentsURL.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    private var indexURL: URL {
        documentsURL.appendingPathComponent("wallpapers.json")
    }

    init() {
        load()
    }

    func load() {
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([WallpaperItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 保存一张新壁纸，返回创建的记录。
    @discardableResult
    func add(
        name: String,
        kind: WallpaperItem.Kind,
        stillImageTime: Double,
        stillJPEGData: Data,
        videoURL: URL,
        thumbnail: UIImage
    ) -> WallpaperItem {
        let item = WallpaperItem(
            id: UUID(),
            name: name,
            kind: kind,
            createdAt: Date(),
            stillImageTime: stillImageTime
        )
        let directory = folderURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? stillJPEGData.write(to: directory.appendingPathComponent("still.jpg"))
        try? fileManager.copyItem(at: videoURL, to: directory.appendingPathComponent("video.mov"))
        if let thumbData = thumbnail.jpegData(compressionQuality: 0.8) {
            try? thumbData.write(to: directory.appendingPathComponent("thumb.jpg"))
        }
        items.insert(item, at: 0)
        saveIndex()
        return item
    }

    func delete(_ item: WallpaperItem) {
        items.removeAll { $0.id == item.id }
        try? fileManager.removeItem(at: folderURL.appendingPathComponent(item.id.uuidString))
        saveIndex()
    }

    /// 标记一张壁纸已经写入锁屏画廊（记下 PosterBoard 里的描述符 UUID）。
    func markInjected(id: UUID, posterUUID: String, provider: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        items[index] = WallpaperItem(
            id: old.id,
            name: old.name,
            kind: old.kind,
            createdAt: old.createdAt,
            stillImageTime: old.stillImageTime,
            injectedPosterUUID: posterUUID,
            injectedAt: Date(),
            injectedProvider: provider
        )
        saveIndex()
    }

    /// 清掉一张壁纸的"已写入锁屏"标记（本地记录还在，只是不再认作已注入）。
    func clearInjected(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        items[index] = WallpaperItem(
            id: old.id,
            name: old.name,
            kind: old.kind,
            createdAt: old.createdAt,
            stillImageTime: old.stillImageTime
        )
        saveIndex()
    }

    func stillURL(for item: WallpaperItem) -> URL {
        folderURL.appendingPathComponent(item.id.uuidString).appendingPathComponent("still.jpg")
    }

    func videoURL(for item: WallpaperItem) -> URL {
        folderURL.appendingPathComponent(item.id.uuidString).appendingPathComponent("video.mov")
    }

    func thumbnail(for item: WallpaperItem) -> UIImage? {
        let url = folderURL.appendingPathComponent(item.id.uuidString).appendingPathComponent("thumb.jpg")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 默认名字，比如“变身壁纸 11-20 10:30”。
    static func defaultName(for kind: WallpaperItem.Kind) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(kind.displayName) \(formatter.string(from: Date()))"
    }

    /// 生成 360 宽的缩略图。
    static func makeThumbnail(from image: UIImage) -> UIImage {
        let targetWidth: CGFloat = 360
        let scale = targetWidth / image.size.width
        let targetSize = CGSize(width: targetWidth, height: max(1, image.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
