import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            WallpaperListView()
                .tabItem {
                    Label("我的壁纸", systemImage: "photo.on.rectangle")
                }
            MakeView()
                .tabItem {
                    Label("制作", systemImage: "plus.circle")
                }
            VaultView()
                .tabItem {
                    Label("金库", systemImage: "archivebox")
                }
        }
    }
}
