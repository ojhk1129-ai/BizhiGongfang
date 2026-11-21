import Foundation
import UIKit

/// 金库里的一张壁纸包（一个 .tendies 里的一个描述符）。
struct VaultPackage: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let importedAt: Date
    /// 帧数（2 张 = 2 态变身）。
    let frameCount: Int
    /// 金库里这个包的描述符文件夹名（Vault/<id>/descriptors/<descriptorUUID>/）。
    let descriptorUUID: String
}

/// 壁纸金库：导入的 .tendies 存在 Documents/Vault/<包 UUID>/ 下，
/// 每个包一个文件夹：descriptors/<描述符 UUID>/（描述符原样）+
/// thumb.jpg（缩略图）；元数据存 Documents/vault.json。
/// 分享时用 TendiesExporter 把存着的描述符重新打成 .tendies
/// （不另外存一份原文件，避免重复占空间）。
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultPackage] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var folderURL: URL {
        documentsURL.appendingPathComponent("Vault", isDirectory: true)
    }

    private var indexURL: URL {
        documentsURL.appendingPathComponent("vault.json")
    }

    init() {
        load()
    }

    func load() {
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([VaultPackage].self, from: data) else {
            items = []
            return
        }
        // 防御：文件夹丢了的记录直接清掉（比如用户手动删了文件）。
        items = decoded.filter { package in
            fileManager.fileExists(atPath: descriptorURL(for: package).path)
        }.sorted { $0.importedAt > $1.importedAt }
        if items.count != decoded.count {
            saveIndex()
        }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 把导入的包收进金库：每个包的描述符文件夹拷到
    /// Vault/<新 UUID>/descriptors/<原描述符 UUID>/，缩略图存为
    /// thumb.jpg，写 vault.json。返回收录的金库记录。
    /// 拷完删掉导入时的临时解压目录（从第一个包的 descriptorURL
    /// 推出来：临时目录/descriptors/<UUID> → 临时目录）。
    @discardableResult
    func add(packages: [TendiesImporter.TendiesPackage]) -> [VaultPackage] {
        var added: [VaultPackage] = []
        for package in packages {
            let id = UUID()
            let packageDir = folderURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let descriptorsDir = packageDir.appendingPathComponent("descriptors", isDirectory: true)
            let descriptorUUID = package.descriptorURL.lastPathComponent
            let targetDescriptorURL = descriptorsDir.appendingPathComponent(descriptorUUID, isDirectory: true)
            do {
                try fileManager.createDirectory(at: descriptorsDir, withIntermediateDirectories: true)
                try fileManager.copyItem(at: package.descriptorURL, to: targetDescriptorURL)
                if let thumbnailData = package.thumbnailData {
                    try thumbnailData.write(to: packageDir.appendingPathComponent("thumb.jpg"), options: .atomic)
                }
            } catch {
                try? fileManager.removeItem(at: packageDir)
                continue
            }
            let vaultPackage = VaultPackage(
                id: id,
                name: package.name,
                importedAt: Date(),
                frameCount: package.frameCount,
                descriptorUUID: descriptorUUID
            )
            added.append(vaultPackage)
        }
        // 临时解压目录用完就删（所有包都在同一个临时目录里）。
        if let first = packages.first {
            let extractionDir = first.descriptorURL
                .deletingLastPathComponent()  // descriptors/
                .deletingLastPathComponent()  // 临时目录
            try? fileManager.removeItem(at: extractionDir)
        }
        items.insert(contentsOf: added, at: 0)
        items.sort { $0.importedAt > $1.importedAt }
        saveIndex()
        return added
    }

    func delete(_ package: VaultPackage) {
        items.removeAll { $0.id == package.id }
        try? fileManager.removeItem(at: folderURL.appendingPathComponent(package.id.uuidString))
        saveIndex()
    }

    /// 金库里这个包的描述符文件夹。
    func descriptorURL(for package: VaultPackage) -> URL {
        folderURL
            .appendingPathComponent(package.id.uuidString, isDirectory: true)
            .appendingPathComponent("descriptors", isDirectory: true)
            .appendingPathComponent(package.descriptorUUID, isDirectory: true)
    }

    func thumbnail(for package: VaultPackage) -> UIImage? {
        let url = folderURL
            .appendingPathComponent(package.id.uuidString, isDirectory: true)
            .appendingPathComponent("thumb.jpg")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 分享用的 .tendies 文件：把存着的描述符重新打成包
    /// （临时目录里，分享面板用完系统会自己清理）。
    func tendiesURL(for package: VaultPackage) throws -> URL {
        try TendiesExporter.exportDescriptor(descriptorURL(for: package), name: package.name)
    }
}
