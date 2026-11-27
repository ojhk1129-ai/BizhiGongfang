import SwiftUI

/// 已装锁屏：锁屏里已装的壁纸管理（缩略图 + 名字 + 徽章 + 编号/帧数/UUID，
/// 搜索 + 刷新）。每行都有删除按钮；不是本 App 写入的点删除时会多一道
/// 提醒（可能是系统或 Pocket Poster 的，删了可能找不回来）。
struct InstalledView: View {
    @EnvironmentObject private var store: WallpaperStore

    @State private var alertMessage: String?
    @State private var showAlert = false

    // 已装锁屏的状态
    @State private var installedSummaries: [PosterBoardStore.DescriptorSummary] = []
    @State private var installedThumbnails: [String: UIImage] = [:]
    @State private var installedLoaded = false
    @State private var isLoadingInstalled = false
    @State private var installedSearchText = ""
    @State private var pendingDelete: PosterBoardStore.DescriptorSummary?
    @State private var showDeleteConfirm = false
    @State private var isDeletingInstalled = false
    @State private var thumbnailTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            installedView
            .navigationTitle("已装锁屏")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        loadInstalled()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoadingInstalled)
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .onAppear {
                if !installedLoaded {
                    loadInstalled()
                }
            }
        }
    }

    /// 已装列表：加载中 / 读不到空态 / 列表（搜索 + 刷新）。
    private var installedView: some View {
        Group {
            if isLoadingInstalled && !installedLoaded {
                VStack(spacing: 12) {
                    ProgressView("正在读取已装列表…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if installedSummaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lock.rectangle.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("读不到已装列表")
                        .font(.headline)
                    Text("先确认直写可用（App Group 权限），\n或锁屏里还没有装壁纸。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    TextField("搜索名字或 UUID", text: $installedSearchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    List {
                        Section {
                            ForEach(filteredInstalled, id: \.uuid) { summary in
                                InstalledRow(
                                    summary: summary,
                                    name: displayName(for: summary),
                                    ours: isOurs(summary),
                                    thumbnail: installedThumbnails[summary.uuid]
                                ) {
                                    pendingDelete = summary
                                    showDeleteConfirm = true
                                }
                            }
                        } header: {
                            Text("共 \(installedSummaries.count) 张 · 每张都能删，不是本 App 的会多问一句")
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .alert("删除这张锁屏壁纸？", isPresented: $showDeleteConfirm, presenting: pendingDelete) { summary in
            Button("删除", role: .destructive) {
                deleteInstalled(summary)
            }
            Button("取消", role: .cancel) {}
        } message: { summary in
            if isOurs(summary) {
                Text("\(displayName(for: summary))\nUUID：\(String(summary.uuid.prefix(8)))…\n删后要去多任务界面把 PosterBoard 划掉，画廊里才看不到。")
            } else {
                Text("\(displayName(for: summary))\nUUID：\(String(summary.uuid.prefix(8)))…\n注意：这张不是本 App 写入的，可能是系统或 Pocket Poster 的壁纸，删了可能找不回来。确定要删吗？\n删后要去多任务界面把 PosterBoard 划掉，画廊里才看不到。")
            }
        }
    }

    /// 按名字或 UUID 过滤已装列表。
    private var filteredInstalled: [PosterBoardStore.DescriptorSummary] {
        let query = installedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return installedSummaries }
        return installedSummaries.filter { summary in
            displayName(for: summary).lowercased().contains(query)
                || summary.uuid.lowercased().contains(query)
        }
    }

    /// 显示名字：本地记录里有这个 uuid 就用记录名；没有就用描述符
    /// 自带的名字；都没有就显示“其他（UUID 前 8 位）”。
    private func displayName(for summary: PosterBoardStore.DescriptorSummary) -> String {
        if let name = store.items.first(where: { $0.injectedPosterUUID == summary.uuid })?.name {
            return name
        }
        if let name = summary.name, !name.isEmpty {
            return name
        }
        return "其他（\(String(summary.uuid.prefix(8)))）"
    }

    /// 是不是本 App 写入的：编号在视频壁纸的 10100...19999 或云端导入的
    /// 20000...99999 区间里（构建 #34 补上导入号段——之前只认 10100...19999，
    /// 云端装的 57904 这类就被当成系统/其他，没了删除按钮），或描述符里
    /// 有本 App 的写入标记，或 uuid 在本地记录的 injectedPosterUUID 里。
    /// 重装 App 会清掉本地记录，所以编号区间和写入标记才是重装后还能认
    /// 出来的依据。不是本 App 的也能删（多一道提醒），见删除确认。
    private func isOurs(_ summary: PosterBoardStore.DescriptorSummary) -> Bool {
        if let identifier = summary.identifier,
           (10100...19999).contains(identifier) || (20000...99999).contains(identifier) {
            return true
        }
        if summary.hasOurMarker {
            return true
        }
        return store.items.contains { $0.injectedPosterUUID == summary.uuid }
    }

    /// 拉已装列表（后台线程调 allDescriptorSummaries，拿完回主线程）。
    /// 刷新时清掉旧缩略图、重新拉。
    private func loadInstalled() {
        guard !isLoadingInstalled else { return }
        isLoadingInstalled = true
        thumbnailTask?.cancel()
        installedThumbnails = [:]
        Task.detached {
            let summaries = PosterBoardStore.allDescriptorSummaries(provider: DescriptorBuilder.providerID)
            await MainActor.run {
                installedSummaries = summaries
                installedLoaded = true
                isLoadingInstalled = false
                startThumbnailLoad()
            }
        }
    }

    /// 缩略图：一个后台任务按顺序逐张读（consume 句柄不要并发拿），
    /// 读出一张就在主线程放进字典，列表逐行出现。
    private func startThumbnailLoad() {
        thumbnailTask?.cancel()
        thumbnailTask = Task.detached {
            let summaries = await MainActor.run { installedSummaries }
            for summary in summaries {
                if Task.isCancelled { return }
                guard let data = PosterBoardStore.thumbnailJPEG(for: summary.uuid, provider: DescriptorBuilder.providerID),
                      let image = UIImage(data: data) else { continue }
                if Task.isCancelled { return }
                await MainActor.run { installedThumbnails[summary.uuid] = image }
            }
        }
    }

    /// 删除一张已装壁纸：调 deleteDescriptor（主容器 + 镜像容器 +
    /// 画廊索引一起清），成功后从列表去掉；本地记录里有这张就清掉
    /// 已注入标记。失败弹原因。
    private func deleteInstalled(_ summary: PosterBoardStore.DescriptorSummary) {
        guard !isDeletingInstalled else { return }
        isDeletingInstalled = true
        Task {
            do {
                try PosterBoardStore.deleteDescriptor(posterUUID: summary.uuid, provider: DescriptorBuilder.providerID)
                await MainActor.run {
                    installedSummaries.removeAll { $0.uuid == summary.uuid }
                    installedThumbnails.removeValue(forKey: summary.uuid)
                    if let item = store.items.first(where: { $0.injectedPosterUUID == summary.uuid }) {
                        store.clearInjected(id: item.id)
                    }
                    isDeletingInstalled = false
                    alertMessage = "锁屏里的这张壁纸已删掉（本地这张还在）。去多任务界面把 PosterBoard 划掉，画廊里就看不到了。"
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    isDeletingInstalled = false
                    alertMessage = "删除失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
}

/// 已装锁屏的一行：缩略图 + 名字 + 徽章 + 编号/帧数/UUID。
/// 每行都有红色垃圾桶删除按钮；不是本 App 写入的点删除时会多一道提醒。
private struct InstalledRow: View {
    let summary: PosterBoardStore.DescriptorSummary
    let name: String
    let ours: Bool
    let thumbnail: UIImage?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        }
                }
            }
            .frame(width: 64, height: 96)
            .cornerRadius(8)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(ours ? "本 App" : "系统/其他")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((ours ? Color.accentColor : Color.secondary).opacity(0.15))
                        .cornerRadius(6)
                }
                Text("编号 \(summary.identifier.map(String.init) ?? "读不到") · \(summary.frameCount.map { "\($0) 帧" } ?? "帧数读不到")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("UUID \(String(summary.uuid.prefix(8)))…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
