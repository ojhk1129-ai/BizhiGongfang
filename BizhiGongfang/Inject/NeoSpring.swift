//  NeoSpring.swift —— 注销桌面（respring），让锁屏画廊重建快照索引。
//
//  移植自 AirCard-iOS 的 RespringHelper.swift（Mak5er/AirCard-iOS，GPL-3.0，
//  源码：https://github.com/Mak5er/AirCard-iOS/blob/main/ios-app/RespringHelper.swift）：
//  WebKit GPU 进程 respring 技术 by @neonmodder123；Swift 实现 @skadz108、@rooootdev。
//  AirCard 原版里还有 import AirliftFFI（它自己的库），这里用不到，已去掉。
//
//  用法：注入成功后先弹 RespringPromptView（sheet）让用户自己决定；
//  点「立即注销桌面生效」后把 respringing 置 true，全屏展示 NeoSpringView。
//  不要自动触发——在 LiveContainer 里注销会先把客 App 挂起，必须让用户自己决定点不点。

import SwiftUI
import UIKit
import WebKit

/// NeoSpring 的实现（照抄 AirCard 的 RespringHelper）。
enum RespringHelper {

    static let neospringHTML = """
<!DOCTYPE html>
<html>
    <body>
        <!-- big credit to @neonmodder123 & @skadz108 (neospring) -->
        <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>
            const frame = document.getElementById('frame');
            const funfun = `
                <html>
                <body>
                    <script>
                        const container = document.createElement('div');
                        container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
                        document.body.appendChild(container);
    
                        for (let i = 0; i < 500; i++) {
                            let d = document.createElement('div');
                            d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';
                            container.appendChild(d);
                        }
    
                        setInterval(() => {
                            navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
                            let x = new Uint8Array(1024 * 1024 * 10);
                            crypto.getRandomValues(x);
                        }, 0);
                    <\\/script>
                </body>
                </html>
            `;
    
            frame.srcdoc = funfun;
        </script>
    </body>
</html>
"""

    /// 直接跳到「设置 › 墙纸」，方便注销后马上挑新注入的壁纸（AirCard 原版的辅助方法）。
    static func openWallpaperSettings() {
        for urlStr in ["prefs:root=WALLPAPER", "App-prefs:root=WALLPAPER", "prefs:root=Wallpaper", UIApplication.openSettingsURLString] {
            if let url = URL(string: urlStr) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
    }

    /// 直接触发 NeoSpring：往 key window 上贴一个全屏 WKWebView 并加载 neospringHTML。
    /// 编辑器里一般走 NeoSpringView（overlay 形式），这里留着备用。
    static func triggerNeoSpring() {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
                return
            }
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let webView = WKWebView(frame: window.bounds, configuration: config)
            webView.isOpaque = true
            webView.backgroundColor = .black
            window.addSubview(webView)
            webView.loadHTMLString(neospringHTML, baseURL: nil)
        }
    }
}

/// NeoSpring 的 SwiftUI 包装（照抄 AirCard 原版，rooootdev/neospring 的实现）。
/// 全屏展示后，里面的页面会挤爆 WebKit GPU 进程，拖垮 SpringBoard 触发 respring。
struct NeoSpringView: UIViewRepresentable {
    init() {}

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(RespringHelper.neospringHTML, baseURL: nil)
    }
}

/// 注入成功后的注销提示卡片：说明为什么要注销 + 两个选择。
/// 由三个编辑器在注入成功后以 sheet 弹出；点「立即注销桌面生效」后，
/// 调用方把 respringing 置 true，全屏展示 NeoSpringView。
struct RespringPromptView: View {
    var onRespring: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("已写入锁屏！")
                        .font(.title2.bold())
                    Text(InjectSupport.successGuidance)
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("在 LiveContainer 里注销会先退出本 App：桌面重启后，重新进 LiveContainer 打开本 App 即可，写好的壁纸不会丢。")
                        .font(.footnote)
                        .foregroundColor(.orange)
                    Button {
                        onRespring()
                    } label: {
                        Label("立即注销桌面生效", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("不用了，稍后再说", role: .cancel) {
                        onDismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("注销桌面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onDismiss() }
                }
            }
        }
    }
}

/// 给三个编辑器共用的注销提示接线：sheet 弹提示，respringing 为 true 时
/// 全屏盖上 NeoSpringView（这一步会重启 SpringBoard）。
struct RespringPromptModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var respringing: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                RespringPromptView(
                    onRespring: {
                        isPresented = false
                        respringing = true
                    },
                    onDismiss: { isPresented = false }
                )
            }
            .overlay {
                if respringing {
                    NeoSpringView()
                        .ignoresSafeArea()
                }
            }
    }
}

extension View {
    /// 注入成功后弹注销提示；点「立即注销桌面生效」后全屏展示 NeoSpringView。
    func respringPrompt(isPresented: Binding<Bool>, respringing: Binding<Bool>) -> some View {
        modifier(RespringPromptModifier(isPresented: isPresented, respringing: respringing))
    }
}
