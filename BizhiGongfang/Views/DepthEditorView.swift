import CoreMotion
import SwiftUI

/// 陀螺仪预览：读取重力方向，输出左右倾斜量（-1...1）。
final class MotionPreviewModel: ObservableObject {
    @Published var tiltX: CGFloat = 0

    private let manager = CMMotionManager()
    private var isRunning = false

    func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        isRunning = true
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion = motion else { return }
            self?.tiltX = CGFloat(motion.gravity.x)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
        tiltX = 0
    }
}

/// 景深壁纸：选一张照片，用陀螺仪实时预览视差效果，导出为 Live Photo。
struct DepthEditorView: View {
    @EnvironmentObject private var store: WallpaperStore

    @State private var image: UIImage?
    @State private var motionEnabled = true
    @State private var showPicker = false
    @State private var isExporting = false
    @State private var isInjecting = false
    @State private var isExportingTendies = false
    @State private var tendiesURL: URL?
    @State private var showTendiesShare = false
    @State private var showRespringPrompt = false
    @State private var respringing = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    @StateObject private var motion = MotionPreviewModel()

    // 预览里图片放大 1.15 倍，最大平移 18pt（和视频里 64px 的幅度对应）
    private let previewScale: CGFloat = 1.15
    private let previewMaxOffset: CGFloat = 18

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                previewSection
                motionSection
                photoSection
                exportSection
            }
            .padding()
        }
        .navigationTitle("景深壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PhotoPicker(isPresented: $showPicker, filter: .images, limit: 1) { results in
                guard let result = results.first else { return }
                loadPickedImage(from: result) { picked in
                    image = picked
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
        .onAppear {
            if motionEnabled {
                motion.start()
            }
        }
        .onDisappear {
            motion.stop()
        }
        .onChange(of: motionEnabled) { _, enabled in
            if enabled {
                motion.start()
            } else {
                motion.stop()
            }
        }
    }

    private var previewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
            if let image = image {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(previewScale)
                        .offset(x: motion.tiltX * previewMaxOffset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .cornerRadius(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "move.3d")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("先选一张照片")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: 300)
    }

    private var motionSection: some View {
        Toggle("陀螺仪预览（倾斜手机看视差）", isOn: $motionEnabled)
    }

    private var photoSection: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .cornerRadius(8)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                }
                Text(image == nil ? "选择一张照片" : "换一张照片")
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var exportSection: some View {
        VStack(spacing: 8) {
            Button {
                exportLivePhoto()
            } label: {
                if isExporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("导出 Live Photo 到相册")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(image == nil || isExporting || isExportingTendies)
            Text("导出 3 秒视频：图片左右平移再回正；静态图用中间帧。")
                .font(.footnote)
                .foregroundColor(.secondary)
            InjectButton(ready: image != nil && !isExporting && !isExportingTendies, busy: isInjecting) {
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
            .disabled(image == nil || isExportingTendies || isExporting || isInjecting)
            Text("导出景深 .tendies，用 Camlo「导入外部 .tendies 壁纸包」安装；不依赖直写，iOS 版本太老或直写被封时也能导出。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func depthDrawer(image: UIImage) -> VideoRenderer.FrameDrawer {
        return { context, canvas, time in
            // 正弦曲线：0 → 右移 → 回正 → 左移 → 回正
            let progress = time / VideoRenderer.duration
            let offsetX = 64 * sin(2 * .pi * progress)
            VideoRenderer.drawAspectFill(
                image,
                in: context,
                canvas: canvas,
                scale: 1.15,
                offset: CGPoint(x: offsetX, y: 0)
            )
        }
    }

    private func exportLivePhoto() {
        guard let image = image, !isExporting else { return }
        isExporting = true
        let identifier = LivePhotoMetadata.newIdentifier()
        let stillTime = VideoRenderer.duration / 2
        let drawer = depthDrawer(image: image)
        VideoRenderer.renderVideo(identifier: identifier, stillImageTime: stillTime, drawer: drawer) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.alertMessage = "导出失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            case .success(let videoURL):
                let still = VideoRenderer.renderStill(size: VideoRenderer.outputSize, at: stillTime, drawer: drawer)
                guard let jpegData = LivePhotoMetadata.jpegData(for: still, identifier: identifier) else {
                    DispatchQueue.main.async {
                        self.isExporting = false
                        self.alertMessage = "导出失败：静态图生成失败"
                        self.showAlert = true
                    }
                    return
                }
                LivePhotoExporter.save(stillJPEGData: jpegData, videoURL: videoURL) { success, error in
                    DispatchQueue.main.async {
                        self.isExporting = false
                        if success {
                            let thumbnail = WallpaperStore.makeThumbnail(from: still)
                            _ = self.store.add(
                                name: WallpaperStore.defaultName(for: .depth),
                                kind: .depth,
                                stillImageTime: stillTime,
                                stillJPEGData: jpegData,
                                videoURL: videoURL,
                                thumbnail: thumbnail
                            )
                            self.alertMessage = LivePhotoExporter.successMessage
                        } else {
                            self.alertMessage = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                        }
                        self.showAlert = true
                    }
                }
            }
        }
    }

    /// 导出 .tendies：按 drawer 一帧一帧画出来的描述符 → 打包成 .tendies，
    /// 弹分享面板（可存到文件、隔空投送、发给 Camlo 导入安装）。
    /// 和一键写入（injectFromDrawer）同一套 drawer、帧数、尺寸，只是不写进
    /// PosterBoard；不依赖直写可用性。
    private func exportTendies() {
        guard let image = image, !isExportingTendies else { return }
        isExportingTendies = true
        Task {
            do {
                let drawer = depthDrawer(image: image)
                let url = try TendiesExporter.exportFromDrawer(
                    frameCount: Int(VideoRenderer.duration * DescriptorBuilder.outputFrameRate),
                    duration: VideoRenderer.duration,
                    outputSize: VideoRenderer.outputSize,
                    drawer: drawer,
                    name: WallpaperStore.defaultName(for: .depth)
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

    /// 一键写入锁屏：先渲染 3 秒视频，再抽帧做描述符、写进 PosterBoard。
    private func injectToLockScreen() {
        guard let image = image, !isInjecting, !isExporting else { return }
        isInjecting = true
        let identifier = LivePhotoMetadata.newIdentifier()
        let stillTime = VideoRenderer.duration / 2
        let drawer = depthDrawer(image: image)
        VideoRenderer.renderVideo(identifier: identifier, stillImageTime: stillTime, drawer: drawer) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isInjecting = false
                    self.alertMessage = "写入失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            case .success(let videoURL):
                let still = VideoRenderer.renderStill(size: VideoRenderer.outputSize, at: stillTime, drawer: drawer)
                guard let jpegData = LivePhotoMetadata.jpegData(for: still, identifier: identifier) else {
                    DispatchQueue.main.async {
                        self.isInjecting = false
                        self.alertMessage = "写入失败：静态图生成失败"
                        self.showAlert = true
                    }
                    return
                }
                Task {
                    do {
                        // 构建 #23：改走静态写入那条路——直接按 drawer 一帧一帧画
                        // 描述符，不经过 MOV 抽帧；MOV 仍渲染一份，供“我的壁纸”
                        // 记录和详情页播放动态用。
                        _ = try await InjectFlow.injectFromDrawer(
                            drawer: drawer,
                            duration: VideoRenderer.duration,
                            stillImageTime: stillTime,
                            videoURL: videoURL,
                            name: WallpaperStore.defaultName(for: .depth),
                            kind: .depth,
                            still: still,
                            stillJPEGData: jpegData,
                            store: self.store
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
