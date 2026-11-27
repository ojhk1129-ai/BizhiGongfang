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
    static func fetch(source: Source) async throws -> [LibraryWallpaper] {
        let data = try await fetchData(from: source.catalogURLs)
        switch source {
        case .caPlayground:
            let response = try JSONDecoder().decode(CAPlaygroundResponse.self, from: data)
            return response.wallpapers
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
            let items = try JSONDecoder().decode([NuggetItem].self, from: data)
            return items
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
    static func downloadPackage(for wallpaper: LibraryWallpaper) async throws -> URL {
        var lastError: Error?
        for candidate in wallpaper.downloadCandidates {
            do {
                let (data, response) = try await URLSession.shared.data(from: candidate)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      !data.isEmpty else {
                    throw CatalogError.fetchFailed
                }
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("library-\(UUID().uuidString)")
                    .appendingPathExtension("tendies")
                try data.write(to: fileURL, options: .atomic)
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

    private struct CAPlaygroundResponse: Decodable {
        let base_url: String
        let wallpapers: [CAPlaygroundItem]
    }

    private struct CAPlaygroundItem: Decodable {
        let name: String
        let id: Int
        let creator: String
        let description: String?
        let file: String
        let preview: String
        let date: Int64
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
