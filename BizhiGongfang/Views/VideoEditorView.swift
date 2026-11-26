import AVFoundation
import AVKit
import SwiftUI

/// 视频壁纸：从相册选一段视频，裁剪到 12 秒，导出为 Live Photo。
struct VideoEditorView: View {
    @EnvironmentObject private var store: WallpaperStore

    @State private var videoURL: URL?
    @State private var videoDuration: Double?
    @State private var player: AVPlayer?
    @State private var showPicker = false
    @State private var isInjecting = false
    @State private var isExportingTendies = false
    @State private var gyroParallax = true
    @State private var tendiesURL: URL?
    @State private var showTendiesShare = false
    @State private var showRespringPrompt = false
    @State private var respringing = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                previewSection
                infoSection
                pickSection
                effectSection
                exportSection
            }
            .padding()
        }
        .navigationTitle("视频壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PhotoPicker(isPresented: $showPicker, filter: .videos, limit: 1) { results in
                guard let result = results.first else { return }
                loadPickedVideoURL(from: result) { url in
                    guard let url = url else { return }
                    videoURL = url
                    rebuildPlayer()
                    loadDuration(for: url)
                }
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
        .respringPrompt(isPresented: $showRespringPrompt, respringing: $respringing)
        .onDisappear {
            player?.pause()
        }
    }

    /// 预览播放器：换视频时重建 player item 并播放。
    private func rebuildPlayer() {
        guard let videoURL = videoURL else { return }
        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        if let player = player {
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
        }
        player?.play()
    }

    private var previewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .cornerRadius(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("先选一段视频")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: 300)
    }

    private var infoSection: some View {
        Group {
            if let duration = videoDuration {
                let trimLength = min(duration, 3.0)
                let trimStart = max(0, (duration - trimLength) / 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("视频时长：\(String(format: "%.1f", duration)) 秒")
                    Text("将裁剪 \(String(format: "%.1f", trimStart)) 秒 – \(String(format: "%.1f", trimStart + trimLength)) 秒，共 \(String(format: "%.1f", trimLength)) 秒")
                    Text("静态图取中间帧。")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pickSection: some View {
        Button {
            showPicker = true
        } label: {
            Label(videoURL == nil ? "从相册选一段视频" : "换一段视频", systemImage: "film")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    /// 陀螺仪 3D（构建 #30）：打开后锁屏壁纸会跟着手机倾斜轻轻移动。
    /// 视差要留出移动余量，画面会比屏幕大一点点；关掉则画面正好铺满屏幕。
    private var effectSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("陀螺仪 3D", isOn: $gyroParallax)
            Text("打开后，锁屏壁纸会跟着手机倾斜轻轻移动；画面会比屏幕大一点点来留出移动余量。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportSection: some View {
        VStack(spacing: 8) {
            InjectButton(ready: videoURL != nil && !isExportingTendies, busy: isInjecting) {
                injectToLockScreen()
            }
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
            .disabled(videoURL == nil || isExportingTendies || isInjecting)
            Text("导出视频 .tendies，用 Camlo「导入外部 .tendies 壁纸包」安装；不依赖直写，iOS 版本太老或直写被封时也能导出。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func loadDuration(for url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                await MainActor.run {
                    videoDuration = seconds.isFinite ? seconds : nil
                }
            }
        }
    }

    /// 导出 .tendies：先裁剪到 12 秒，再抽帧做描述符、打包成 .tendies，
    /// 弹分享面板（可存到文件、隔空投送、发给 Camlo 导入安装）。
    /// 不依赖直写可用性：不用 App Group，不走 worse_query。
    private func exportTendies() {
        guard let videoURL = videoURL, !isExportingTendies else { return }
        isExportingTendies = true
        let identifier = LivePhotoMetadata.newIdentifier()
        VideoCropper.cropToLivePhoto(sourceURL: videoURL, identifier: identifier) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isExportingTendies = false
                    self.alertMessage = "导出失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            case .success(let cropped):
                Task {
                    do {
                        let url = try await TendiesExporter.exportVideo(
                            videoURL: cropped.videoURL,
                            name: WallpaperStore.defaultName(for: .video),
                            parallax: self.gyroParallax
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
        }
    }

    /// 一键写入锁屏：先裁剪到 12 秒，再抽帧做描述符、写进 PosterBoard。
    private func injectToLockScreen() {
        guard let videoURL = videoURL, !isInjecting else { return }
        isInjecting = true
        let identifier = LivePhotoMetadata.newIdentifier()
        VideoCropper.cropToLivePhoto(sourceURL: videoURL, identifier: identifier) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isInjecting = false
                    self.alertMessage = "写入失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            case .success(let cropped):
                Task {
                    do {
                        let still = try await VideoCropper.stillImage(from: cropped.videoURL, at: cropped.stillImageTime)
                        guard let jpegData = LivePhotoMetadata.jpegData(for: still, identifier: identifier) else {
                            await MainActor.run {
                                self.isInjecting = false
                                self.alertMessage = "写入失败：静态图生成失败"
                                self.showAlert = true
                            }
                            return
                        }
                        _ = try await InjectFlow.injectVideo(
                            videoURL: cropped.videoURL,
                            name: WallpaperStore.defaultName(for: .video),
                            kind: .video,
                            still: still,
                            stillJPEGData: jpegData,
                            store: self.store,
                            parallax: self.gyroParallax
                        )
                        await MainActor.run {
                            self.isInjecting = false
                            self.showRespringPrompt = true
                        }
                    } catch {
                        await MainActor.run {
                            self.isInjecting = false
                            self.alertMessage = "写入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                            self.showAlert = true
                        }
                    }
                }
            }
        }
    }
}
