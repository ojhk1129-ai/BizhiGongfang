import AVKit
import SwiftUI

/// 壁纸详情：预览静态图、播放动态、重新保存到相册、分享、删除。
struct WallpaperDetailView: View {
    @EnvironmentObject private var store: WallpaperStore
    @Environment(\.dismiss) private var dismiss

    let item: WallpaperItem

    @State private var player: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var showShare = false
    @State private var isSaving = false
    @State private var isExportingTendies = false
    @State private var tendiesURL: URL?
    @State private var showTendiesShare = false
    @State private var isDeletingInjected = false
    @State private var injectedRemoved = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isPlayingVideo, let player = player {
                        VideoPlayer(player: player)
                            .frame(height: 480)
                            .cornerRadius(12)
                    } else if let data = try? Data(contentsOf: store.stillURL(for: item)),
                              let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 480)
                            .cornerRadius(12)
                    }

                    Button(isPlayingVideo ? "查看静态图" : "播放动态") {
                        if isPlayingVideo {
                            player?.pause()
                            isPlayingVideo = false
                        } else {
                            let newPlayer = AVPlayer(url: store.videoURL(for: item))
                            player = newPlayer
                            isPlayingVideo = true
                            newPlayer.play()
                        }
                    }
                    .buttonStyle(.bordered)

                    VStack(spacing: 10) {
                        Button {
                            saveToPhotos()
                        } label: {
                            Label("保存到相册", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)

                        Button {
                            showShare = true
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            exportTendies()
                        } label: {
                            if isExportingTendies {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label(item.kind == .morph ? "导出 .tendies（静态版）" : "导出 .tendies", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExportingTendies || isSaving)

                        Text(item.kind == .morph
                             ? "变身记录只存了静态图，导出的是静态版 .tendies；要变身效果请回变身页重新做。导出后用 Camlo「导入外部 .tendies 壁纸包」安装。"
                             : "导出后用 Camlo「导入外部 .tendies 壁纸包」安装；不依赖直写。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // 只删锁屏画廊里的这一张（按记录的描述符 UUID 精确删），
                        // 本地这张壁纸和相册里的 Live Photo 都不动。
                        if item.injectedPosterUUID != nil && !injectedRemoved {
                            Button(role: .destructive) {
                                deleteInjectedWallpaper()
                            } label: {
                                if isDeletingInjected {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label("删除锁屏里的这张壁纸", systemImage: "lock.slash")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDeletingInjected)
                        }

                        Button(role: .destructive) {
                            store.delete(item)
                            dismiss()
                        } label: {
                            Label("删除这张壁纸", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    Text("设为锁屏壁纸：去「照片」打开这张 Live Photo → 点分享 → 「设为墙纸」→ 打开 Live Photo。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [store.stillURL(for: item), store.videoURL(for: item)])
            }
            .sheet(isPresented: $showTendiesShare) {
                if let tendiesURL = tendiesURL {
                    ShareSheet(items: [tendiesURL])
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private func saveToPhotos() {
        guard let jpegData = try? Data(contentsOf: store.stillURL(for: item)) else {
            alertMessage = "找不到静态图文件"
            showAlert = true
            return
        }
        isSaving = true
        LivePhotoExporter.save(stillJPEGData: jpegData, videoURL: store.videoURL(for: item)) { success, error in
            DispatchQueue.main.async {
                isSaving = false
                if success {
                    alertMessage = LivePhotoExporter.successMessage
                } else {
                    alertMessage = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                }
                showAlert = true
            }
        }
    }

    /// 导出 .tendies：视频/景深记录用存的 MOV 重建描述符再打包；
    /// 变身记录没有原图 B（只存了静态图和 MOV），用静态图降级导出静态版。
    /// 弹分享面板（可存到文件、隔空投送、发给 Camlo 导入安装）。
    /// 不依赖直写可用性。
    private func exportTendies() {
        guard !isExportingTendies else { return }
        isExportingTendies = true
        Task {
            do {
                let url: URL
                if item.kind == .morph {
                    guard let data = try? Data(contentsOf: store.stillURL(for: item)),
                          let image = UIImage(data: data) else {
                        throw TendiesExporter.ExportError.stillImageMissing
                    }
                    url = try TendiesExporter.exportSinglePhoto(image: image, name: item.name)
                } else {
                    url = try await TendiesExporter.exportVideo(
                        videoURL: store.videoURL(for: item),
                        name: item.name
                    )
                }
                await MainActor.run {
                    self.isExportingTendies = false
                    self.tendiesURL = url
                    self.showTendiesShare = true
                }
            } catch {
                await MainActor.run {
                    self.isExportingTendies = false
                    self.alertMessage = "导出失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    /// 只删锁屏画廊里的这一张，不删本地记录和相册。
    private func deleteInjectedWallpaper() {
        guard let posterUUID = item.injectedPosterUUID,
              let provider = item.injectedProvider,
              !isDeletingInjected else { return }
        isDeletingInjected = true
        Task {
            do {
                try PosterBoardStore.deleteDescriptor(posterUUID: posterUUID, provider: provider)
                await MainActor.run {
                    store.clearInjected(id: item.id)
                    injectedRemoved = true
                    isDeletingInjected = false
                    alertMessage = "锁屏里的这张壁纸已删掉（本地这张还在）。去多任务界面把 PosterBoard 划掉，画廊里就看不到了。"
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    isDeletingInjected = false
                    alertMessage = "删除失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
}
