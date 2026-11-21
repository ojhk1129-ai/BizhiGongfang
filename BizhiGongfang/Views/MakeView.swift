import SwiftUI

/// 制作页：三种壁纸的入口。
struct MakeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: MorphEditorView()) {
                        MakerRow(
                            icon: "photo.on.rectangle.angled",
                            title: "变身壁纸",
                            subtitle: "选两张照片，解锁时一张变另一张"
                        )
                    }
                    NavigationLink(destination: DepthEditorView()) {
                        MakerRow(
                            icon: "move.3d",
                            title: "景深壁纸",
                            subtitle: "选一张照片，晃动手机有视差效果"
                        )
                    }
                    NavigationLink(destination: VideoEditorView()) {
                        MakerRow(
                            icon: "film",
                            title: "视频壁纸",
                            subtitle: "选一段视频，做成动态锁屏壁纸"
                        )
                    }
                } header: {
                    Text("选一种开始制作")
                } footer: {
                    Text("做好的壁纸会导出为 Live Photo，保存到相册后，在「照片」里设为锁屏壁纸即可。")
                }
            }
            .navigationTitle("制作壁纸")
        }
    }
}

private struct MakerRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
