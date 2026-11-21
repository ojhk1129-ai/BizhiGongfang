import AVKit
import SwiftUI

/// 壁纸详情：预览静态图、播放动态、导出 .tendies、删除。
struct WallpaperDetailView: View {
    @EnvironmentObject private var store: WallpaperStore
    @Environment(\.dismiss) private var dismiss

    let item: WallpaperItem

    @State private var player: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isExportingTendies = false
    @State private var tendiesURL: URL?
    @State private var showTendiesShare = false
    @State private var isDeletingInjected = false
    @State private var injectedRemoved = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    /// 这条记录有没有存 video.mov（有才显示“播放动态”，视频记录
    /// 导出 .tendies 时也要用它）。
    private var hasVideo: Bool {
        FileManager.default.fileExists(atPath: store.videoURL(for: item).path)
    }

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

                    if hasVideo {
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
                    }

                    VStack(spacing: 10) {
                        Button {
                            exportTendies()
                        } label: {
                            if isExportingTendies {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("导出 .tendies", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExportingTendies)

                        Text("导出后用 Camlo「导入外部 .tendies 壁纸包」安装；不依赖直写。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // 只删锁屏画廊里的这一张（按记录的描述符 UUID 精确删），
                        // 本地这张壁纸不动。
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

    /// 导出 .tendies：用存的 MOV 重建描述符再打包。
    /// 弹分享面板（可存到文件、隔空投送、发给 Camlo 导入安装）。
    /// 不依赖直写可用性。
    private func exportTendies() {
        guard !isExportingTendies else { return }
        isExportingTendies = true
        Task {
            do {
                let url = try await TendiesExporter.exportVideo(
                    videoURL: store.videoURL(for: item),
                    name: item.name
                )
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

    /// 只删锁屏画廊里的这一张，不删本地记录。
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
