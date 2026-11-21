import SwiftUI

/// 裁剪页（构建 #25）：9:16 框，图片可拖动、双指缩放，
/// 确定后按框内区域裁出 1080×1920 的图。
/// 裁剪是可选的（不裁也能用，默认 aspectFill）。
struct CropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 累计缩放（手势结束时落盘）和累计偏移。
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero
    /// 手势进行中的临时量。
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragOffset: CGSize = .zero
    /// 框的实际尺寸（GeometryReader 量出来，裁剪计算用它）。
    @State private var frameSize: CGSize = CGSize(width: 300, height: 533)

    /// 归一化后的图（方向 .up、有 cgImage），裁剪用它。
    private var flatImage: UIImage { image.flattenedForDrawing() }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let frame = cropFrameSize(in: geometry.size)
                VStack(spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: frame.width, height: frame.height)
                        Image(uiImage: flatImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: frame.width, height: frame.height)
                            .scaleEffect(effectiveScale)
                            .offset(effectiveOffset)
                            .clipped()
                            .cornerRadius(16)
                            .gesture(dragGesture(frameSize: frame))
                            .simultaneousGesture(pinchGesture(frameSize: frame))
                    }
                    Text("拖动移动，双指缩放")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { frameSize = frame }
                .onChange(of: geometry.size) { _, newSize in
                    frameSize = cropFrameSize(in: newSize)
                }
            }
            .navigationTitle("裁剪照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        if let cropped = croppedImage() {
                            onDone(cropped)
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    /// 9:16 的裁剪框，宽取屏幕宽减边距，上限 340。
    private func cropFrameSize(in container: CGSize) -> CGSize {
        let width = min(container.width - 32, 340)
        return CGSize(width: width, height: width * 16 / 9)
    }

    private var effectiveScale: CGFloat { baseScale * pinchScale }
    private var effectiveOffset: CGSize {
        CGSize(width: baseOffset.width + dragOffset.width,
               height: baseOffset.height + dragOffset.height)
    }

    /// 拖动手势：松手时把偏移落盘并夹紧（图必须一直盖住框）。
    private func dragGesture(frameSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let next = CGSize(width: baseOffset.width + value.translation.width,
                                  height: baseOffset.height + value.translation.height)
                baseOffset = clampedOffset(next, scale: baseScale, frameSize: frameSize)
            }
    }

    /// 双指缩放手势：松手时把缩放落盘并夹紧到 1…5，同时夹紧偏移。
    private func pinchGesture(frameSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                baseScale = min(max(baseScale * value, 1), 5)
                baseOffset = clampedOffset(baseOffset, scale: baseScale, frameSize: frameSize)
            }
    }

    /// 偏移夹紧：图片边缘不能露出框（|offset| 不超过图片超出框的部分的一半）。
    private func clampedOffset(_ offset: CGSize, scale: CGFloat, frameSize: CGSize) -> CGSize {
        let img = flatImage.size
        guard img.width > 0, img.height > 0 else { return .zero }
        let s0 = max(frameSize.width / img.width, frameSize.height / img.height)
        let displayedW = img.width * s0 * scale
        let displayedH = img.height * s0 * scale
        let maxX = max(0, (displayedW - frameSize.width) / 2)
        let maxY = max(0, (displayedH - frameSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    /// 按当前缩放/偏移裁出 1080×1920。
    /// 框内看到的区域对应原图的：x=(0-origin.x)/s，宽=框宽/s（s 是总缩放）。
    private func croppedImage() -> UIImage? {
        let img = flatImage
        guard let cgImage = img.cgImage else { return nil }
        let fw = frameSize.width
        let fh = frameSize.height
        let iw = img.size.width
        let ih = img.size.height
        guard fw > 0, fh > 0, iw > 0, ih > 0 else { return nil }
        // aspect-fill 基准缩放 × 用户缩放。
        let s0 = max(fw / iw, fh / ih)
        let s = s0 * effectiveScale
        let displayedW = iw * s
        let displayedH = ih * s
        let originX = (fw - displayedW) / 2 + effectiveOffset.width
        let originY = (fh - displayedH) / 2 + effectiveOffset.height
        var cropX = (0 - originX) / s
        var cropY = (0 - originY) / s
        var cropW = fw / s
        var cropH = fh / s
        // 夹紧到图片内。
        cropX = min(max(cropX, 0), iw)
        cropY = min(max(cropY, 0), ih)
        cropW = min(cropW, iw - cropX)
        cropH = min(cropH, ih - cropY)
        guard cropW > 0, cropH > 0 else { return nil }
        // 原图点坐标 → 像素坐标。
        let fx = CGFloat(cgImage.width) / iw
        let fy = CGFloat(cgImage.height) / ih
        let pixelRect = CGRect(x: cropX * fx, y: cropY * fy, width: cropW * fx, height: cropH * fy)
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        // 统一输出 1080×1920（裁出区域已是 9:16，刚好铺满）。
        let outSize = CGSize(width: 1080, height: 1920)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outSize, format: format)
        return renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: outSize))
        }
    }
}
