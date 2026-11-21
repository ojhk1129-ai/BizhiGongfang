import SwiftUI
import UniformTypeIdentifiers

/// 壁纸金库：导入的 .tendies 包列表。点一个包进详情（大图、
/// 分享 .tendies、删除）；右上角“导入”从文件 App 选 .tendies。
struct VaultView: View {
    @StateObject private var vault = VaultStore()

    @State private var showImporter = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    /// .tendies 的 UTType：系统没有内置，按扩展名声明（属于 ZIP）。
    private static let tendiesType: UTType =
        UTType(filenameExtension: "tendies", conformingTo: .zip) ?? .zip

    var body: some View {
        NavigationStack {
            Group {
                if vault.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("金库是空的")
                            .font(.headline)
                        Text("点右上角“导入”，从文件 App 选一个 .tendies\n（Camlo、Nugget、CAPlayground 导出的都行）")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vault.items) { package in
                            NavigationLink(destination: VaultDetailView(vault: vault, package: package)) {
                                VaultRow(vault: vault, package: package)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    vault.delete(package)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("壁纸金库")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [Self.tendiesType, .zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFile(url)
                case .failure(let error):
                    alertMessage = "选择文件失败：\(error.localizedDescription)"
                    showAlert = true
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .overlay {
                if isImporting {
                    ProgressView("正在导入…")
                        .padding()
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(12)
                }
            }
        }
    }

    /// 导入一个 .tendies 文件：解开 → 收进金库。
    /// security-scoped URL 的访问由 TendiesImporter 内部处理。
    private func importFile(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            do {
                let packages = try TendiesImporter.importTendies(from: url)
                let added = vault.add(packages: packages)
                await MainActor.run {
                    isImporting = false
                    alertMessage = added.isEmpty
                        ? "导入失败：没有可收录的壁纸"
                        : "已导入 \(added.count) 个壁纸到金库"
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    alertMessage = "导入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
}

private struct VaultRow: View {
    @ObservedObject var vault: VaultStore
    let package: VaultPackage

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = vault.thumbnail(for: package) {
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
                Text(package.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(package.frameCount) 帧")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(package.importedAt, style: .date)
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

/// 金库包详情：大图、分享 .tendies、删除。
private struct VaultDetailView: View {
    @ObservedObject var vault: VaultStore
    let package: VaultPackage

    @Environment(\.dismiss) private var dismiss

    @State private var tendiesURL: URL?
    @State private var showShare = false
    @State private var isPreparingShare = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let thumbnail = vault.thumbnail(for: package) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 480)
                        .cornerRadius(12)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 480)
                        .cornerRadius(12)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name)
                        .font(.headline)
                    Text("\(package.frameCount) 帧 · 导入于 \(package.importedAt, style: .date)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    Button {
                        shareTendies()
                    } label: {
                        if isPreparingShare {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("分享 .tendies", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingShare)

                    Text("分享出去的 .tendies 可以用 Camlo「导入外部 .tendies 壁纸包」安装，也可以发给别人。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button(role: .destructive) {
                        vault.delete(package)
                        dismiss()
                    } label: {
                        Label("从金库删除", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
            }
            .padding()
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let tendiesURL = tendiesURL {
                ShareSheet(items: [tendiesURL])
            }
        }
        .alert("提示", isPresented: $showAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    /// 分享：把存着的描述符重新打成 .tendies，再弹分享面板。
    private func shareTendies() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            do {
                let url = try vault.tendiesURL(for: package)
                await MainActor.run {
                    isPreparingShare = false
                    tendiesURL = url
                    showShare = true
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                    alertMessage = "打包失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
}
