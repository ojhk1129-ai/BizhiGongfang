import SwiftUI

@main
struct BizhiGongfangApp: App {
    @StateObject private var store = WallpaperStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    // 启动时修一次直写的缓存：如果上次查询中途崩溃，
                    // App Group 的 Library/Caches 可能还留着符号链接，
                    // 不修好的话之后所有直写都会被拒绝。
                    await Task.detached {
                        let fixed = PosterBoardStore.recoverBrokenCacheSwap()
                        for line in fixed {
                            NSLog("[BizhiGongfang] 启动恢复：%@", line)
                        }
                    }.value
                }
        }
    }
}
