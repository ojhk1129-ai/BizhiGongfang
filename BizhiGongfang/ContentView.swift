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
            InstalledView()
                .tabItem {
                    Label("已装锁屏", systemImage: "rectangle.on.rectangle")
                }
            LibraryView()
                .tabItem {
                    Label("壁纸库", systemImage: "globe")
                }
        }
    }
}
