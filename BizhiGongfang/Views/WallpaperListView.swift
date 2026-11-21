import SwiftUI

/// 首页：我的壁纸列表。
struct WallpaperListView: View {
    @EnvironmentObject private var store: WallpaperStore
    @State private var selectedItem: WallpaperItem?
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("还没有壁纸")
                            .font(.headline)
                        Text("去「制作」做一张吧")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.items) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                WallpaperRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("我的壁纸")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("直写诊断", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
            .sheet(item: $selectedItem) { item in
                WallpaperDetailView(item: item)
            }
            .sheet(isPresented: $showDiagnostics) {
                InjectDiagnosticsView()
            }
        }
    }
}

private struct WallpaperRow: View {
    @EnvironmentObject private var store: WallpaperStore
    let item: WallpaperItem

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = store.thumbnail(for: item) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 96)
                    .cornerRadius(8)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 64, height: 96)
                    .cornerRadius(8)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.kind.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if item.injectedPosterUUID != nil {
                    Label("已写入锁屏", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Text(item.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
