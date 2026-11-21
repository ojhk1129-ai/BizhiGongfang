import SwiftUI

/// 变身壁纸：选两张照片（锁定画面 / 解锁后画面），
/// 在应用内用滑块实时预览变身效果，导出为 Live Photo。
struct MorphEditorView: View {
    enum Mode: String, CaseIterable {
        case crossfade
        case slide

        var displayName: String {
            switch self {
            case .crossfade: return "交叉淡化"
            case .slide: return "滑动切换"
            }
        }
    }

    private enum Slot {
        case photoA
        case photoB
    }

    @EnvironmentObject private var store: WallpaperStore

    @State private var imageA: UIImage?
    @State private var imageB: UIImage?
    @State private var mode: Mode = .crossfade
    @State private var progress: Double = 0
    @State private var previewImage: UIImage?
    @State private var showPicker = false
    @State private var pickingSlot: Slot = .photoA
    @State private var isExporting = false
    @State private var isInjecting = false
    @State private var isWritingStatic = false
    @State private var isExportingTendies = false
    @State private var tendiesURL: URL?
    @State private var showTendiesShare = false
    @State private var showRespringPrompt = false
    @State private var respringing = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    private let previewSize = CGSize(width: 540, height: 960)

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                previewSection
                modeSection
                sliderSection
                photoSection
                exportSection
            }
            .padding()
        }
        .navigationTitle("变身壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PhotoPicker(isPresented: $showPicker, filter: .images, limit: 1) { results in
                guard let result = results.first else { return }
                loadPickedImage(from: result) { image in
                    guard let image = image else { return }
                    if pickingSlot == .photoA {
                        imageA = image
                    } else {
                        imageB = image
                    }
                    refreshPreview()
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
    }

    private var previewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
            if let previewImage = previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("先选两张照片")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: 300)
    }

    private var modeSection: some View {
        Picker("切换方式", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { _, _ in refreshPreview() }
    }

    private var sliderSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("锁定画面")
                Spacer()
                Text("解锁后")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            Slider(value: $progress, in: 0...1)
                .onChange(of: progress) { _, _ in refreshPreview() }
            Button("播放变身效果") {
                progress = 0
                withAnimation(.linear(duration: 3.0)) {
                    progress = 1.0
                }
            }
            .buttonStyle(.bordered)
            .disabled(imageA == nil || imageB == nil)
        }
    }

    private var photoSection: some View {
        HStack(spacing: 12) {
            photoButton(title: "照片 A（锁定）", image: imageA) {
                pickingSlot = .photoA
                showPicker = true
            }
            photoButton(title: "照片 B（解锁后）", image: imageB) {
                pickingSlot = .photoB
                showPicker = true
            }
        }
    }

    private func photoButton(title: String, image: UIImage?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 120)
                        .cornerRadius(10)
                        .clipped()
                } else {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .frame(height: 120)
                }
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
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
            .disabled(imageA == nil || imageB == nil || isExporting || isExportingTendies)
            Text("导出 3 秒视频：从 A 变到 B；静态图用 A。")
                .font(.footnote)
                .foregroundColor(.secondary)
            InjectButton(ready: imageA != nil && imageB != nil && !isExporting && !isExportingTendies, busy: isInjecting) {
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
            .disabled(imageA == nil || imageB == nil || isExportingTendies || isExporting || isInjecting || isWritingStatic)
            Text("导出 2 态变身 .tendies，用 Camlo「导入外部 .tendies 壁纸包」安装；不依赖直写，iOS 版本太老或直写被封时也能导出。")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button {
                injectSinglePhotoProbe()
            } label: {
                if isWritingStatic {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("静态写入（单帧照片）", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(imageA == nil || isWritingStatic || isInjecting || isExporting || isExportingTendies)
            Text("判别实验：用照片 A 写两个单帧探针（1080×1920 和 886×1920），看画廊里是照片 tile 还是黑 tile，分清问题在动画还是在尺寸/照片。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func refreshPreview() {
        guard let imageA = imageA, let imageB = imageB else {
            previewImage = nil
            return
        }
        let drawer = morphDrawer(imageA: imageA, imageB: imageB, mode: mode)
        previewImage = VideoRenderer.renderStill(
            size: previewSize,
            at: progress * VideoRenderer.duration,
            drawer: drawer
        )
    }

    private func morphDrawer(imageA: UIImage, imageB: UIImage, mode: Mode) -> VideoRenderer.FrameDrawer {
        return { context, canvas, time in
            let progress = min(max(time / VideoRenderer.duration, 0), 1)
            switch mode {
            case .crossfade:
                // 先把 A 不透明地画满，再把 B 按进度盖上去，这才是正确的交叉淡化
                VideoRenderer.drawAspectFill(imageA, in: context, canvas: canvas)
                VideoRenderer.drawAspectFill(imageB, in: context, canvas: canvas, alpha: progress)
            case .slide:
                let width = canvas.width
                VideoRenderer.drawAspectFill(imageA, in: context, canvas: canvas, offset: CGPoint(x: -progress * width, y: 0))
                VideoRenderer.drawAspectFill(imageB, in: context, canvas: canvas, offset: CGPoint(x: (1 - progress) * width, y: 0))
            }
        }
    }

    private func exportLivePhoto() {
        guard let imageA = imageA, let imageB = imageB, !isExporting else { return }
        isExporting = true
        let identifier = LivePhotoMetadata.newIdentifier()
        let drawer = morphDrawer(imageA: imageA, imageB: imageB, mode: mode)
        VideoRenderer.renderVideo(identifier: identifier, stillImageTime: 0, drawer: drawer) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.alertMessage = "导出失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            case .success(let videoURL):
                let still = VideoRenderer.renderStill(size: VideoRenderer.outputSize, at: 0, drawer: drawer)
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
                                name: WallpaperStore.defaultName(for: .morph),
                                kind: .morph,
                                stillImageTime: 0,
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

    /// 一键写入锁屏：先渲染 3 秒视频，再抽帧做描述符、写进 PosterBoard。
    /// 和导出 Live Photo 是同一段视频，只是最后一步不同。
    private func injectToLockScreen() {
        guard let imageA = imageA, let imageB = imageB, !isInjecting, !isExporting else { return }
        isInjecting = true
        let identifier = LivePhotoMetadata.newIdentifier()
        let drawer = morphDrawer(imageA: imageA, imageB: imageB, mode: mode)
        VideoRenderer.renderVideo(identifier: identifier, stillImageTime: 0, drawer: drawer) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isInjecting = false
                    self.alertMessage = "写入失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            case .success(let videoURL):
                let still = VideoRenderer.renderStill(size: VideoRenderer.outputSize, at: 0, drawer: drawer)
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
                        // 构建 #24：改走 2 态滑动解锁描述符（Camlo 式“真变身”）——
                        // 只把 A、B 各渲染一张 1080×1920，Locked 显示 A、Unlock 显示 B。
                        // 不再走 45 帧视频（画廊列不出多帧描述符）。
                        // MOV 仍渲染一份，供“我的壁纸”记录和详情页播放动态用。
                        _ = try await InjectFlow.injectTwoStateMorph(
                            imageA: imageA,
                            imageB: imageB,
                            slide: mode == .slide,
                            videoURL: videoURL,
                            name: WallpaperStore.defaultName(for: .morph),
                            kind: .morph,
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

    /// 导出 .tendies：两张照片 → 2 态滑动解锁描述符 → 打包成 .tendies，
    /// 弹分享面板（可存到文件、隔空投送、发给 Camlo 导入安装）。
    /// 不依赖直写可用性：不用 App Group，不走 worse_query。
    private func exportTendies() {
        guard let imageA = imageA, let imageB = imageB, !isExportingTendies else { return }
        isExportingTendies = true
        Task {
            do {
                let url = try TendiesExporter.exportTwoStateMorph(
                    imageA: imageA,
                    imageB: imageB,
                    slide: mode == .slide,
                    name: WallpaperStore.defaultName(for: .morph)
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

    /// 静态写入（单帧照片判别实验，排障报告 4 第十节）：用变身 A 图写两个
    /// 单帧探针——A（1080×1920，与最小测试只差帧内容）、B（886×1920，
    /// 与视频只差帧数）。UUID 记在 UserDefaults 里，诊断第 7 步会核对
    /// 它们的快照状态，诊断页也能删掉它们。不经过"我的壁纸"记录。
    private func injectSinglePhotoProbe() {
        guard let imageA = imageA, !isWritingStatic, !isInjecting, !isExporting else { return }
        isWritingStatic = true
        Task {
            do {
                let probes = try await InjectFlow.injectSinglePhoto(image: imageA)
                await MainActor.run {
                    self.isWritingStatic = false
                    UserDefaults.standard.set(probes.probeA, forKey: InjectFlow.singlePhotoProbeAKey)
                    UserDefaults.standard.set(probes.probeB, forKey: InjectFlow.singlePhotoProbeBKey)
                    self.alertMessage = "两个单帧照片探针已写入（A：1080×1920，B：886×1920）。注销一次桌面，再长按锁屏点 +，在画廊「iPhone 13 Pro」区找两个新的照片 tile；诊断第 7 步能看到它们的快照状态。"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run {
                    self.isWritingStatic = false
                    self.alertMessage = "静态写入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}
