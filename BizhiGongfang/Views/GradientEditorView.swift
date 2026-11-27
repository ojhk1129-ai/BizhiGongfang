import SwiftUI

/// 渐变壁纸（构建 #31，Drift 风格）：选一套配色（或按天气/时间推荐），
/// App 内生成 12 秒渐变动画视频，再走视频壁纸同一条路写入锁屏 / 导出 .tendies。
/// 注意：锁屏壁纸是写死的一组帧，不会自己跟天气/时间变；
/// 这里是“打开 App 时按当前天气/时间生成一张”，想换就重新生成一张。
struct GradientEditorView: View {
    @EnvironmentObject private var store: WallpaperStore

    @State private var selectedPalette: GradientRenderer.Palette = GradientRenderer.paletteForCurrentTime()
    @State private var selectedWeather: GradientRenderer.Weather?
    @State private var glowOn = false
    @State private var isGenerating = false
    @State private var isInjecting = false
    @State private var isExportingTendies = false
    @State private var generatedVideoURL: URL?
    @State private var generatedPaletteID: String?
    @State private var tendiesURL: URL?
    @State private var showTendiesShare = false
    @State private var showRespringPrompt = false
    @State private var respringing = false
    @State private var gyroParallax = true
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                previewSection
                weatherSection
                paletteSection
                effectSection
                exportSection
            }
            .padding()
        }
        .navigationTitle("渐变壁纸")
        .navigationBarTitleDisplayMode(.inline)
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
            glowOn = true
        }
    }

    /// 预览：配色渐变 + 一个缓慢漂移的光晕（只是预览，真正的动画在生成的视频里）。
    private var previewSection: some View {
        ZStack {
            LinearGradient(
                colors: selectedPalette.swiftUIColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(selectedPalette.swiftUIColors[0].opacity(0.45))
                .blur(radius: 50)
                .frame(width: 180, height: 180)
                .offset(x: glowOn ? 60 : -60, y: glowOn ? -80 : 80)
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: glowOn)
        }
        .frame(maxWidth: 300)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .cornerRadius(16)
        .clipped()
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("天气")
                Spacer()
                Text("现在是\(GradientRenderer.currentPeriodName())")
                    .foregroundColor(.secondary)
            }
            .font(.subheadline)
            HStack(spacing: 8) {
                ForEach(GradientRenderer.Weather.allCases) { weather in
                    Button {
                        selectedWeather = weather
                        if let palette = GradientRenderer.palettes.first(where: { $0.id == weather.paletteID }) {
                            selectedPalette = palette
                        }
                    } label: {
                        Text(weather.rawValue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedWeather == weather ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("点天气会按天气换一套配色；也可以直接在下面点配色。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配色")
                .font(.subheadline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                ForEach(GradientRenderer.palettes) { palette in
                    Button {
                        selectedPalette = palette
                        selectedWeather = nil
                    } label: {
                        VStack(spacing: 4) {
                            LinearGradient(
                                colors: palette.swiftUIColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(height: 48)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedPalette == palette ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                            Text(palette.name)
                                .font(.caption)
                                .foregroundColor(selectedPalette == palette ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 陀螺仪 3D（构建 #30）：打开后锁屏壁纸会跟着手机倾斜轻轻移动。
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
            InjectButton(ready: !isGenerating && !isInjecting && !isExportingTendies, busy: isGenerating || isInjecting) {
                injectToLockScreen()
            }
            Button {
                exportTendies()
            } label: {
                if isExportingTendies || isGenerating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("导出 .tendies", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isExportingTendies || isInjecting || isGenerating)
            Text("先生成 12 秒渐变视频，再写入锁屏 / 导出 .tendies。锁屏上的渐变不会自己跟天气变，想换就重新生成一张。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    /// 生成渐变视频（同一套配色只生成一次，换配色才重新生成）。
    private func generateVideoIfNeeded() async throws -> URL {
        if let url = generatedVideoURL,
           generatedPaletteID == selectedPalette.id,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let url = try await GradientRenderer.renderVideo(palette: selectedPalette)
        await MainActor.run {
            self.generatedVideoURL = url
            self.generatedPaletteID = selectedPalette.id
        }
        return url
    }

    /// 一键写入锁屏：生成渐变视频 → 裁剪到 12 秒 → 抽帧做描述符、写进 PosterBoard。
    private func injectToLockScreen() {
        guard !isInjecting && !isGenerating && !isExportingTendies else { return }
        isGenerating = true
        Task {
            do {
                let sourceURL = try await generateVideoIfNeeded()
                await MainActor.run {
                    self.isGenerating = false
                    self.isInjecting = true
                }
                let identifier = LivePhotoMetadata.newIdentifier()
                VideoCropper.cropToLivePhoto(sourceURL: sourceURL, identifier: identifier) { result in
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
                                    name: WallpaperStore.defaultName(for: .gradient),
                                    kind: .gradient,
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
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.alertMessage = "生成失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    /// 导出 .tendies：生成渐变视频 → 裁剪到 12 秒 → 抽帧做描述符、打包成 .tendies，
    /// 弹分享面板（可存到文件、隔空投送、发给 Camlo 导入安装）。
    private func exportTendies() {
        guard !isExportingTendies && !isGenerating && !isInjecting else { return }
        isGenerating = true
        Task {
            do {
                let sourceURL = try await generateVideoIfNeeded()
                await MainActor.run {
                    self.isGenerating = false
                    self.isExportingTendies = true
                }
                let identifier = LivePhotoMetadata.newIdentifier()
                VideoCropper.cropToLivePhoto(sourceURL: sourceURL, identifier: identifier) { result in
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
                                    name: WallpaperStore.defaultName(for: .gradient),
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
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.alertMessage = "生成失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}
