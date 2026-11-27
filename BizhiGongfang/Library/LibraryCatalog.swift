import Foundation

/// 云端壁纸库（构建 #32）：两个公开的 .tendies 社区库。
/// - CAPlayground：CAPlayground/wallpapers，wallpapers.json（287 套）。
/// - Nugget：SerStars/nugget-wallpapers，wallpapers-custom.json（111 套）。
/// 目录和预览走 jsDelivr 镜像（国内快），.tendies 包走 gh-proxy，
/// 失败时回退到直连 raw.githubusercontent.com。
/// （参考 Placard 的 WallpaperCatalog：同一套地址和回退。）
enum LibraryCatalog {

    enum Source: String, CaseIterable, Identifiable {
        case caPlayground = "CAPlayground"
        case nugget = "Nugget"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .caPlayground: return "CAPlayground"
            case .nugget: return "Nugget 创意"
            }
        }

        /// 目录 JSON 的地址（先镜像，后直连）。
        var catalogURLs: [URL] {
            switch self {
            case .caPlayground:
                return [
                    URL(string: "https://cdn.jsdmirror.com/gh/CAPlayground/wallpapers@main/wallpapers.json")!,
                    URL(string: "https://raw.githubusercontent.com/CAPlayground/wallpapers/main/wallpapers.json")!,
                ]
            case .nugget:
                return [
                    URL(string: "https://cdn.jsdmirror.com/gh/SerStars/nugget-wallpapers@main/wallpapers-custom.json")!,
                    URL(string: "https://raw.githubusercontent.com/SerStars/nugget-wallpapers/main/wallpapers-custom.json")!,
                ]
            }
        }

        /// 预览图（GIF）的基地址（jsDelivr 镜像）。
        var assetBaseURL: URL {
            switch self {
            case .caPlayground:
                return URL(string: "https://cdn.jsdmirror.com/gh/CAPlayground/wallpapers@main/")!
            case .nugget:
                return URL(string: "https://cdn.jsdmirror.com/gh/SerStars/nugget-wallpapers@main/")!
            }
        }

        /// .tendies 包的基地址（先 gh-proxy，后直连）。
        var packageBaseURLs: [URL] {
            switch self {
            case .caPlayground:
                return [
                    URL(string: "https://gh-proxy.com/https://raw.githubusercontent.com/CAPlayground/wallpapers/main/")!,
                    URL(string: "https://raw.githubusercontent.com/CAPlayground/wallpapers/main/")!,
                ]
            case .nugget:
                return [
                    URL(string: "https://gh-proxy.com/https://raw.githubusercontent.com/SerStars/nugget-wallpapers/main/")!,
                    URL(string: "https://raw.githubusercontent.com/SerStars/nugget-wallpapers/main/")!,
                ]
            }
        }
    }

    /// 库里的一张壁纸。
    struct LibraryWallpaper: Identifiable, Equatable {
        /// 来源 + 远端 id，保证两个库之间不撞。
        let id: String
        let name: String
        let creator: String
        let description: String
        /// .tendies 下载地址（按顺序试：先 gh-proxy，后直连）。
        let downloadCandidates: [URL]
        /// 预览 GIF 地址（jsDelivr 镜像）。
        let previewURL: URL
        let source: Source
        /// 远端时间（毫秒时间戳或 id），用于最新在前排序。
        let sortKey: Int64
    }

    enum CatalogError: LocalizedError {
        case fetchFailed
        case invalidData

        var errorDescription: String? {
            switch self {
            case .fetchFailed: return "壁纸库加载失败：网络不通或镜像不可用，换个网络再试"
            case .invalidData: return "壁纸库数据格式不对"
            }
        }
    }

    /// 拉取一个库的目录（最新在前）。
    /// 逐条容错：某一条解析失败就跳过它，不让一条坏数据毁掉整个列表
    /// （CAPlayground 里有 12 条的 id 是 "0000001" 这种字符串，
    /// 按 Int 解整个数组都会失败）。
    static func fetch(source: Source) async throws -> [LibraryWallpaper] {
        let data = try await fetchData(from: source.catalogURLs)
        switch source {
        case .caPlayground:
            let response = try JSONDecoder().decode(CAPlaygroundResponse.self, from: data)
            return response.wallpapers
                .compactMap { $0.value }
                .map { item in
                    LibraryWallpaper(
                        id: "cap-\(item.id)",
                        name: item.name,
                        creator: item.creator,
                        description: item.description ?? "",
                        downloadCandidates: source.packageBaseURLs.map { $0.appending(path: item.file) },
                        previewURL: source.assetBaseURL.appending(path: item.preview),
                        source: source,
                        sortKey: item.date
                    )
                }
                .sorted { $0.sortKey > $1.sortKey }
        case .nugget:
            let items = try JSONDecoder().decode([FailableDecodable<NuggetItem>].self, from: data)
            return items
                .compactMap { $0.value }
                .map { item in
                    LibraryWallpaper(
                        id: "nug-\(item.id)",
                        name: item.name,
                        creator: item.authors ?? "",
                        description: item.description ?? "",
                        downloadCandidates: source.packageBaseURLs.map { $0.appending(path: item.url) },
                        previewURL: source.assetBaseURL.appending(path: item.preview),
                        source: source,
                        sortKey: Int64(item.id)
                    )
                }
                .sorted { $0.sortKey > $1.sortKey }
        }
    }

    /// 下载一个 .tendies 包到临时目录（按顺序试下载地址），返回本地文件地址。
    /// 用 downloadTask 直接写盘，不经过内存 Data——有的包十几 MB，
    /// 整包进内存再解压容易把 App 顶掉（闪退）。
    static func downloadPackage(for wallpaper: LibraryWallpaper) async throws -> URL {
        var lastError: Error?
        for candidate in wallpaper.downloadCandidates {
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: candidate)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw CatalogError.fetchFailed
                }
                // 移到我们自己的临时位置（download 返回的临时文件系统随时会删）。
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("library-\(UUID().uuidString)")
                    .appendingPathExtension("tendies")
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
                return fileURL
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? CatalogError.fetchFailed
    }

    /// 按顺序试多个地址，拿到第一个成功的数据。
    private static func fetchData(from urls: [URL]) async throws -> Data {
        var lastError: Error?
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      !data.isEmpty else {
                    throw CatalogError.fetchFailed
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? CatalogError.fetchFailed
    }

    // MARK: - 目录 JSON 结构

    /// 逐条容错的包装：某一条解失败就得 nil，整条跳过，不毁掉整个列表。
    private struct FailableDecodable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(T.self)
        }
    }

    private struct CAPlaygroundResponse: Decodable {
        let base_url: String
        let wallpapers: [FailableDecodable<CAPlaygroundItem>]
    }

    private struct CAPlaygroundItem: Decodable {
        let name: String
        /// id 可能是 Int，也可能是 "0000001" 这种字符串（库里有 12 条是字符串）。
        let id: String
        let creator: String
        let description: String?
        let file: String
        let preview: String
        let date: Int64

        enum CodingKeys: String, CodingKey {
            case name, id, creator, description, file, preview, date
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let intID = try? c.decode(Int.self, forKey: .id) {
                id = String(intID)
            } else {
                id = try c.decode(String.self, forKey: .id)
            }
            creator = try c.decode(String.self, forKey: .creator)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            file = try c.decode(String.self, forKey: .file)
            preview = try c.decode(String.self, forKey: .preview)
            if let d = try? c.decode(Int64.self, forKey: .date) {
                date = d
            } else if let s = try? c.decode(String.self, forKey: .date), let d = Int64(s) {
                date = d
            } else {
                date = 0
            }
        }
    }

    private struct NuggetItem: Decodable {
        let id: Int
        let name: String
        let description: String?
        let url: String
        let preview: String
        let authors: String?
    }
}
