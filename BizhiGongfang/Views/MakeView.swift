import SwiftUI

/// 制作页（构建 #28）：只剩视频壁纸一种，直接就是视频制作。
/// 变身和景深已删（用户 2026-11-21 19:52 确认：只留视频）。
struct MakeView: View {
    var body: some View {
        NavigationStack {
            VideoEditorView()
        }
    }
}
