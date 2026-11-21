import SwiftUI

/// 变身壁纸：选两张照片（锁定画面 / 解锁后画面），
/// 在应用内用滑块实时预览变身效果，一键写入锁屏或导出为 .tendies。
/// 只有滑动切换一种模式（交叉淡化已删：实测没用）。
/// 构建 #25：变身动画曲线（上滑揭幕 / 破屏觉醒 / 圣光瞬变）、
/// AI 主体抠图、昼夜双生、熄屏常显图、裁剪。
struct MorphEditorView: View {
    private enum Slot {
        case photoA
        case photoB
        case nightA
        case nightB
        case alwaysOn
    }

    @EnvironmentObject private var store: WallpaperStore

    @State private var imageA: UIImage?
    @State private var imageB: UIImage?
    @State private var progress: Double = 0
    @State private var previewImage: UIImage?
    @State private var showPicker = false
    @State private var pickingSlot: Slot = .photoA
    @State private var curve: DescriptorBuilder.MorphCurve = .revealUp
    @State private var cutoutEnabled = true
    @State private var nightEnabled = false
    @State private var imageNightA: UIImage?
    @State private var imageNightB: UIImage?
    @State private var imageAlwaysOn: UIImage?
    @State private var croppingSlot: Slot?
    @State private var showCrop = false
    @State private var isInjecting = false
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
                curveSection
                sliderSection
                photoSection
                optionsSection
                if nightEnabled {
                    nightSection
                }
                alwaysOnSection
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
                    setImage(image, for: pickingSlot)
                    refreshPreview()
                }
            }
        }
        .sheet(isPresented: $showCrop) {
            if let slot = croppingSlot, let img = image(for: slot) {
                CropView(image: img) { cropped in
                    setImage(cropped, for: slot)
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

    /// 变身动画曲线：上滑揭幕 / 破屏觉醒 / 圣光瞬变（构建 #25）。
    /// 选中的曲线同时改变预览滑块的动画和描述符的 CAML 过渡动画。
    private var curveSection: some View {
        Picker("变身动画", selection: $curve) {
            ForEach(DescriptorBuilder.MorphCurve.allCases, id: \.self) { curve in
                Text(curve.displayName).tag(curve)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: curve) { _, _ in refreshPreview() }
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
            } onCrop: {
                croppingSlot = .photoA
                showCrop = true
            }
            photoButton(title: "照片 B（解锁后）", image: imageB) {
                pickingSlot = .photoB
                showPicker = true
            } onCrop: {
                croppingSlot = .photoB
                showCrop = true
            }
        }
    }

    /// 开关区：AI 抠图（默认开）+ 昼夜双生。
    private var optionsSection: some View {
        VStack(spacing: 8) {
            Toggle("AI 主体抠图（遮挡时钟）", isOn: $cutoutEnabled)
            Toggle("昼夜双生（深色模式自动换图）", isOn: $nightEnabled)
        }
    }

    /// 夜间照片：开关开时才显示，共 4 张图（白天 A/B + 夜间 A/B）。
    private var nightSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                photoButton(title: "夜间 A（锁定）", image: imageNightA) {
                    pickingSlot = .nightA
                    showPicker = true
                } onCrop: {
                    croppingSlot = .nightA
                    showCrop = true
                }
                photoButton(title: "夜间 B（解锁后）", image: imageNightB) {
                    pickingSlot = .nightB
                    showPicker = true
                } onCrop: {
                    croppingSlot = .nightB
                    showCrop = true
                }
            }
            Text("深色模式时自动显示夜间图；不选夜间图时只用白天图。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    /// 熄屏常显图：可选，选中后写进描述符，锁屏熄屏时显示。
    private var alwaysOnSection: some View {
        VStack(spacing: 8) {
            photoButton(title: "熄屏常显图（可选）", image: imageAlwaysOn) {
                pickingSlot = .alwaysOn
                showPicker = true
            } onCrop: {
                croppingSlot = .alwaysOn
                showCrop = true
            }
            Text("不选就不写常显图。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func photoButton(
        title: String,
        image: UIImage?,
        onPick: @escaping () -> Void,
        onCrop: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 4) {
            Button(action: onPick) {
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
            // 有图时显示裁剪按钮（点照片是换图，点裁剪是进裁剪页）。
            if image != nil, let onCrop = onCrop {
                Button("裁剪", action: onCrop)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var exportSection: some View {
        VStack(spacing: 8) {
            InjectButton(ready: imageA != nil && imageB != nil && !isExportingTendies, busy: isInjecting) {
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
            .disabled(imageA == nil || imageB == nil || isExportingTendies || isInjecting)
            Text("导出 2 态变身 .tendies，用 Camlo「导入外部 .tendies 壁纸包」安装；不依赖直写，iOS 版本太老或直写被封时也能导出。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func image(for slot: Slot) -> UIImage? {
        switch slot {
        case .photoA: return imageA
        case .photoB: return imageB
        case .nightA: return imageNightA
        case .nightB: return imageNightB
        case .alwaysOn: return imageAlwaysOn
        }
    }

    private func setImage(_ image: UIImage, for slot: Slot) {
        switch slot {
        case .photoA: imageA = image
        case .photoB: imageB = image
        case .nightA: imageNightA = image
        case .nightB: imageNightB = image
        case .alwaysOn: imageAlwaysOn = image
        }
    }

    private func refreshPreview() {
        guard let imageA = imageA, let imageB = imageB else {
            previewImage = nil
            return
        }
        let drawer = morphDrawer(imageA: imageA, imageB: imageB, curve: curve)
        previewImage = VideoRenderer.renderStill(
            size: previewSize,
            at: progress * VideoRenderer.duration,
            drawer: drawer
        )
    }

    /// 按曲线画预览帧（和 twoStateCAML 里的过渡动画对应）：
    /// 上滑揭幕 B 从下方滑入；破屏觉醒 B 从小放大 + 淡入；
    /// 圣光瞬变 progress 过半显示 B，否则显示 A。
    private func morphDrawer(
        imageA: UIImage,
        imageB: UIImage,
        curve: DescriptorBuilder.MorphCurve
    ) -> VideoRenderer.FrameDrawer {
        return { context, canvas, time in
            let progress = min(max(time / VideoRenderer.duration, 0), 1)
            switch curve {
            case .revealUp:
                VideoRenderer.drawAspectFill(imageA, in: context, canvas: canvas)
                VideoRenderer.drawAspectFill(
                    imageB, in: context, canvas: canvas,
                    offset: CGPoint(x: 0, y: (1 - progress) * canvas.height))
            case .awaken:
                VideoRenderer.drawAspectFill(imageA, in: context, canvas: canvas)
                let scale = 0.6 + 0.4 * progress
                VideoRenderer.drawAspectFill(
                    imageB, in: context, canvas: canvas,
                    scale: scale, alpha: progress)
            case .flash:
                if progress > 0.5 {
                    VideoRenderer.drawAspectFill(imageB, in: context, canvas: canvas)
                } else {
                    VideoRenderer.drawAspectFill(imageA, in: context, canvas: canvas)
                }
            }
        }
    }

    /// 收集夜图 / 常显图 / 抠图（都算好再调 inject/export）。
    /// 夜图要成对才用；抠图找不到主体时返回 nil（跳过，不报错）。
    private func nightJPEGs(size: CGSize) -> (Data, Data)? {
        guard nightEnabled,
              let nightA = imageNightA,
              let nightB = imageNightB else { return nil }
        return DescriptorBuilder.renderTwoStateJPEGs(imageA: nightA, imageB: nightB, size: size)
    }

    private func alwaysOnJPEG(size: CGSize) -> Data? {
        guard let imageAlwaysOn = imageAlwaysOn else { return nil }
        return DescriptorBuilder.renderSingleJPEG(image: imageAlwaysOn, size: size)
    }

    private func cutoutPNG() async -> Data? {
        guard cutoutEnabled, let imageA = imageA else { return nil }
        guard let cutout = await ForegroundCutout.cutoutForeground(from: imageA) else {
            return nil
        }
        return cutout.pngData()
    }

    /// 一键写入锁屏：先渲染 3 秒视频，再做 2 态描述符、写进 PosterBoard。
    private func injectToLockScreen() {
        guard let imageA = imageA, let imageB = imageB, !isInjecting else { return }
        isInjecting = true
        let identifier = LivePhotoMetadata.newIdentifier()
        let drawer = morphDrawer(imageA: imageA, imageB: imageB, curve: curve)
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
                        // 构建 #25：曲线 / 抠图 / 夜图 / 常显图都算好一起传下去。
                        let outputSize = VideoRenderer.outputSize
                        let night = self.nightJPEGs(size: outputSize)
                        let alwaysOn = self.alwaysOnJPEG(size: outputSize)
                        let foreground = await self.cutoutPNG()
                        _ = try await InjectFlow.injectTwoStateMorph(
                            imageA: imageA,
                            imageB: imageB,
                            videoURL: videoURL,
                            name: WallpaperStore.defaultName(for: .morph),
                            kind: .morph,
                            still: still,
                            stillJPEGData: jpegData,
                            store: self.store,
                            curve: self.curve,
                            foregroundPNG: foreground,
                            nightLockJPEG: night?.0,
                            nightUnlockJPEG: night?.1,
                            alwaysOnJPEG: alwaysOn
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
    /// 构建 #25：曲线 / 抠图 / 夜图 / 常显图都算好一起传下去。
    private func exportTendies() {
        guard let imageA = imageA, let imageB = imageB, !isExportingTendies else { return }
        isExportingTendies = true
        Task {
            do {
                let outputSize = VideoRenderer.outputSize
                let night = self.nightJPEGs(size: outputSize)
                let alwaysOn = self.alwaysOnJPEG(size: outputSize)
                let foreground = await self.cutoutPNG()
                let url = try TendiesExporter.exportTwoStateMorph(
                    imageA: imageA,
                    imageB: imageB,
                    name: WallpaperStore.defaultName(for: .morph),
                    curve: self.curve,
                    foregroundPNG: foreground,
                    nightLockJPEG: night?.0,
                    nightUnlockJPEG: night?.1,
                    alwaysOnJPEG: alwaysOn
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
