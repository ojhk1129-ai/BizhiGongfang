import SwiftUI

/// 三个编辑器共用的"一键写入锁屏"按钮。
/// 版本不支持时按钮置灰，并显示原因；支持时显示升级警告小字。
struct InjectButton: View {
    /// 有没有可写入的内容（比如已选好照片/视频）
    let ready: Bool
    /// 正在写入
    let busy: Bool
    let action: () -> Void

    private var availability: InjectSupport.Availability {
        InjectSupport.availability()
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                if busy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("一键写入锁屏", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!ready || busy || !availability.canInject)
            if availability.canInject {
                Text("直接写进锁屏画廊，不用经过相册。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(InjectSupport.upgradeWarning)
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text(availability.reason)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}
