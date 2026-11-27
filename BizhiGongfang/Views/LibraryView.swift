import SwiftUI

/// 云端壁纸库（构建 #32）：浏览 CAPlayground / Nugget 两个公开库，
/// 下载 .tendies 并直接装到锁屏（走一键写入同一套直写）。
/// 社区壁纸是各种机型做的，不一定都适配本机；装不上会在锁屏画廊里看不到。
struct LibraryView: View {
    @EnvironmentObject private var store: WallpaperStore

    @State private var source: LibraryCatalog.Source = .caPlayground
    @State private var wallpapers: [LibraryCatalog.LibraryWallpaper] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var installingID: String?
    @State private var installedIDs: Set<String> = []
    @State private var showRespringPrompt = false
    @State private var respringing = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    private var filteredWallpapers: [LibraryCatalog.LibraryWallpaper] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return wallpapers }
        return wallpapers.filter { item in
            item.name.lowercased().contains(keyword)
                || item.creator.lowercased().contains(keyword)
                || item.description.lowercased().contains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("壁纸库", selection: $source) {
                    ForEach(LibraryCatalog.Source.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: source) {
                    loadCatalog()
                }

                if isLoading && wallpapers.isEmpty {
                    Spacer()
                    ProgressView("正在加载壁纸库…")
                    Spacer()
                } else if let loadError = loadError, wallpapers.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(loadError)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("再试一次") {
                            loadCatalog()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(filteredWallpapers) { item in
                                LibraryWallpaperCard(
                                    wallpaper: item,
                                    isInstalling: installingID == item.id,
                                    isInstalled: installedIDs.contains(item.id),
                                    isBusy: installingID != nil,
                                    onInstall: { install(item) }
                                )
                            }
                        }
                        .padding()
                        if filteredWallpapers.isEmpty && !searchText.isEmpty {
                            Text("没找到“\(searchText)”")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        Text("社区壁纸来自公开库，各种机型都有，不一定都适配本机；装上后去锁屏画廊看，装不上的换一张试试。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                }
            }
            .navigationTitle("壁纸库")
            .searchable(text: $searchText, prompt: "搜索壁纸名称、作者")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        loadCatalog()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .respringPrompt(isPresented: $showRespringPrompt, respringing: $respringing)
            .onAppear {
                if wallpapers.isEmpty {
                    loadCatalog()
                }
            }
        }
    }

    /// 拉取当前库的目录（最新在前）。
    private func loadCatalog() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        let currentSource = source
        Task {
            do {
                let items = try await LibraryCatalog.fetch(source: currentSource)
                await MainActor.run {
                    // 用户可能已经切到另一个库了，只更新当前库的结果。
                    if self.source == currentSource {
                        self.wallpapers = items
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    if self.source == currentSource {
                        self.isLoading = false
                        self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
    }

    /// 下载 .tendies 并装到锁屏，记一条导入记录到我的壁纸。
    private func install(_ wallpaper: LibraryCatalog.LibraryWallpaper) {
        guard installingID == nil else { return }
        installingID = wallpaper.id
        Task {
            do {
                let packageURL = try await LibraryCatalog.downloadPackage(for: wallpaper)
                defer { try? FileManager.default.removeItem(at: packageURL) }
                _ = try await TendiesImporter.installTendies(
                    from: packageURL,
                    name: wallpaper.name,
                    store: store
                )
                await MainActor.run {
                    self.installingID = nil
                    self.installedIDs.insert(wallpaper.id)
                    self.showRespringPrompt = true
                }
            } catch {
                await MainActor.run {
                    self.installingID = nil
                    self.alertMessage = "安装失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}

/// 库里一张壁纸的卡片：预览图（GIF 首帧）+ 名字/作者 + 安装按钮。
private struct LibraryWallpaperCard: View {
    let wallpaper: LibraryCatalog.LibraryWallpaper
    let isInstalling: Bool
    let isInstalled: Bool
    let isBusy: Bool
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: wallpaper.previewURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        )
                default:
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .cornerRadius(12)
            .clipped()

            Text(wallpaper.name)
                .font(.headline)
                .lineLimit(1)
            Text(wallpaper.creator)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if isInstalled {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: onInstall) {
                    if isInstalling {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("安装到锁屏", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
    }
}
