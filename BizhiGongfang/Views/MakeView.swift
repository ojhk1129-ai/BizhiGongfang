import SwiftUI

/// 制作页（构建 #28：只剩视频壁纸；构建 #31：加渐变壁纸，Drift 风格）。
/// 顶部切换：视频壁纸 / 渐变壁纸。变身和景深已删（用户 2026-11-21 19:52 确认：只留视频）。
struct MakeView: View {
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("制作", selection: $tab) {
                    Text("视频壁纸").tag(0)
                    Text("渐变壁纸").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                if tab == 0 {
                    VideoEditorView()
                } else {
                    GradientEditorView()
                }
            }
        }
    }
}
