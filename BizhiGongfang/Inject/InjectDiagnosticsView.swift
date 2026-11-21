import SwiftUI

/// 直写诊断：一步一步跑"找 PosterBoard → 拿读写权 → 写空白描述符"，
/// 每步都显示中文结果。第一次真机测试就看这个页面——不用先做完整视频导出。
/// 跑通了，说明逃逸 + 写入在你这台手机（LiveContainer）里是通的。
struct InjectDiagnosticsView: View {
    @EnvironmentObject private var store: WallpaperStore
    @Environment(\.dismiss) private var dismiss

    private enum StepStatus {
        case pending
        case running
        case success(String)
        case failure(String)

        var icon: String {
            switch self {
            case .pending: return "circle"
            case .running: return "arrow.triangle.2.circlepath"
            case .success: return "checkmark.circle.fill"
            case .failure: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .pending: return .secondary
            case .running: return .accentColor
            case .success: return .green
            case .failure: return .red
            }
        }
    }

    private struct Step: Identifiable {
        let id: Int
        let title: String
        var status: StepStatus = .pending
    }

    @State private var steps: [Step] = [
        Step(id: 0, title: "系统版本"),
        Step(id: 1, title: "App Group"),
        Step(id: 2, title: "修复残留的缓存交换"),
        Step(id: 3, title: "找到 PosterBoard 容器"),
        Step(id: 4, title: "拿到 PosterBoard 读写权"),
        Step(id: 5, title: "写入空白描述符（测试）"),
        Step(id: 6, title: "核对已写入的壁纸"),
    ]
    @State private var isRunning = false
    @State private var testPosterUUID: String?
    @State private var isDeletingTest = false
    @State private var footerMessage: String?

    /// 对照测试描述符的 poster UUID（写进 PosterBoard 后的文件夹名），
    /// 存在 UserDefaults 里，杀掉 App 重进后第 7 步还能继续核对它。
    private static let controlPosterUUIDKey = "BizhiGongfang.controlTestPosterUUID"
    @State private var controlPosterUUID: String?
    @State private var isWritingControl = false
    @State private var isDeletingControl = false
    @State private var controlMessage: String?

    /// 单帧照片探针的 poster UUID（探针 A 1080×1920、探针 B 886×1920），
    /// 存在 UserDefaults 里，杀掉 App 重进后第 7 步还能继续核对它们。
    @State private var probeAUUID: String?
    @State private var probeBUUID: String?
    @State private var isDeletingProbes = false
    @State private var probeMessage: String?

    /// 文件权限对照的结果（nil = 还没查过）。
    @State private var permissionLines: [String]?
    @State private var isCheckingPermissions = false

    /// 容器内所有描述符对照的结果（nil = 还没查过）。
    @State private var descriptorSummaryLines: [String]?
    @State private var isCheckingDescriptors = false

    /// 有快照的描述符（nil = 还没查过，构建 #21）：只列快照已生成的，
    /// 动漫壁纸应该在里面，一张截图就能看完，不用翻上面 19 行。
    @State private var snapshotLines: [String]?
    @State private var isCheckingSnapshots = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(InjectSupport.systemDescription())
                        .font(.subheadline)
                    Text(InjectSupport.upgradeWarning)
                        .font(.footnote)
                        .foregroundColor(.orange)
                } header: {
                    Text("这台手机")
                }

                Section {
                    ForEach(steps) { step in
                        HStack(spacing: 12) {
                            if case .running = step.status {
                                ProgressView()
                            } else {
                                Image(systemName: step.status.icon)
                                    .foregroundColor(step.status.color)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.subheadline)
                                switch step.status {
                                case .pending:
                                    Text("还没检查")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .running:
                                    Text("检查中…")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .success(let message):
                                    Text(message)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .failure(let message):
                                    Text(message)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                } header: {
                    Text("一步一步检查")
                } footer: {
                    if let footerMessage = footerMessage {
                        Text(footerMessage)
                            .font(.footnote)
                    }
                }

                if let testPosterUUID = testPosterUUID {
                    Section {
                        Button {
                            deleteTestWallpaper()
                        } label: {
                            if isDeletingTest {
                                ProgressView()
                            } else {
                                Label("删除刚才写入的测试壁纸", systemImage: "trash")
                            }
                        }
                        .disabled(isDeletingTest)
                        Text("测试壁纸的编号：\(testPosterUUID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("清理测试")
                    }
                }

                Section {
                    Text("把一份完整的真实壁纸描述符（Cipher，WWDC 2022）原样写进 PosterBoard，只改文件夹编号和三处 identifier——和正常注入走同一条写入路径。写完注销桌面，去画廊「收藏」里找它：找得到，说明是我们自己的描述符有问题；找不到，说明问题在写入环境或画廊刷新。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        writeControlTest()
                    } label: {
                        if isWritingControl {
                            ProgressView()
                        } else {
                            Label("写入对照测试描述符", systemImage: "doc.badge.plus")
                        }
                    }
                    .disabled(isWritingControl || isRunning)
                    if let controlPosterUUID = controlPosterUUID {
                        Text("对照描述符的编号：\(controlPosterUUID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button {
                            deleteControlTest()
                        } label: {
                            if isDeletingControl {
                                ProgressView()
                            } else {
                                Label("删除对照测试描述符", systemImage: "trash")
                            }
                        }
                        .disabled(isDeletingControl)
                    }
                    if let controlMessage = controlMessage {
                        Text(controlMessage)
                            .font(.footnote)
                    }
                } header: {
                    Text("对照测试")
                }

                Section {
                    Text("只读对照：每张描述符文件夹的所有者、POSIX 权限位（八进制）和扩展属性名。我们写的和苹果自带的如果不一样（比如所有者或权限不同），快照服务可能读不到我们写的文件，画廊就渲染不出来。不在记录里的可能是苹果自带的，也可能是之前诊断写的旧测试描述符。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        refreshPermissionComparison()
                    } label: {
                        if isCheckingPermissions {
                            ProgressView()
                        } else {
                            Label("查看文件权限对照", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .disabled(isCheckingPermissions || isRunning)
                    if let permissionLines = permissionLines {
                        ForEach(permissionLines.indices, id: \.self) { index in
                            Text(permissionLines[index])
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("文件权限对照")
                }

                Section {
                    Text("只读对照：主容器里每一张描述符的名字、编号、屏幕类、.ca 包（背景/浮动/前景）、帧数、CAML 动画模式、快照和权限。那张 iOS 26 时装的动漫壁纸会是唯一一个「多帧 + 快照已生成」的，一眼就能认出来——把它那一行和我们的逐项比，就能看到差在哪。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        refreshDescriptorComparison()
                    } label: {
                        if isCheckingDescriptors {
                            ProgressView()
                        } else {
                            Label("查看容器内所有描述符对照", systemImage: "list.bullet.rectangle")
                        }
                    }
                    .disabled(isCheckingDescriptors || isRunning)
                    if let descriptorSummaryLines = descriptorSummaryLines {
                        ForEach(descriptorSummaryLines.indices, id: \.self) { index in
                            Text(descriptorSummaryLines[index])
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("容器内所有描述符对照")
                }

                Section {
                    Text("只读：只列快照已生成的描述符。那张 iOS 26 时装的动漫壁纸应该在里面——截这一区就行，不用翻上面 19 行。如果它不在里面，说明它的快照也不在主容器里。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        refreshSnapshotComparison()
                    } label: {
                        if isCheckingSnapshots {
                            ProgressView()
                        } else {
                            Label("查看有快照的描述符", systemImage: "photo.on.rectangle")
                        }
                    }
                    .disabled(isCheckingSnapshots || isRunning)
                    if let snapshotLines = snapshotLines {
                        ForEach(snapshotLines.indices, id: \.self) { index in
                            Text(snapshotLines[index])
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("有快照的描述符")
                }

                Section {
                    Text(InjectSupport.successGuidance)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("写入成功后怎么查看")
                }

                if probeAUUID != nil || probeBUUID != nil {
                    Section {
                        Text("单帧真照片判别实验的两个探针：A 是 1080×1920（与最小测试只差帧内容），B 是 886×1920（与视频只差帧数）。在变身编辑器里点「静态写入（单帧照片）」写入。注销桌面后去画廊「iPhone 13 Pro」区找两个新的照片 tile，第 7 步核对它们的快照状态。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        if let probeAUUID = probeAUUID {
                            Text("探针 A 的编号：\(probeAUUID)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let probeBUUID = probeBUUID {
                            Text("探针 B 的编号：\(probeBUUID)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button {
                            deleteProbes()
                        } label: {
                            if isDeletingProbes {
                                ProgressView()
                            } else {
                                Label("删除两个单帧照片探针", systemImage: "trash")
                            }
                        }
                        .disabled(isDeletingProbes)
                        if let probeMessage = probeMessage {
                            Text(probeMessage)
                                .font(.footnote)
                        }
                    } header: {
                        Text("单帧照片探针")
                    }
                }
            }
            .navigationTitle("直写诊断")
            .onAppear {
                controlPosterUUID = UserDefaults.standard.string(forKey: Self.controlPosterUUIDKey)
                probeAUUID = UserDefaults.standard.string(forKey: InjectFlow.singlePhotoProbeAKey)
                probeBUUID = UserDefaults.standard.string(forKey: InjectFlow.singlePhotoProbeBKey)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始检查") { runDiagnostics() }
                        .disabled(isRunning)
                }
            }
        }
    }

    private func setStep(_ id: Int, _ status: StepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }

    private func runDiagnostics() {
        guard !isRunning else { return }
        isRunning = true
        footerMessage = nil
        testPosterUUID = nil
        for index in steps.indices {
            steps[index].status = .pending
        }
        Task {
            await runSteps()
            await MainActor.run { isRunning = false }
        }
    }

    private func runSteps() async {
        // 1. 系统版本
        await setStepMain(0, .running)
        let availability = InjectSupport.availability()
        if !availability.canInject {
            await setStepMain(0, .failure(availability.reason))
            await setFooterMain("系统版本这一关就过不去，下面的步骤不用跑了。")
            return
        }
        await setStepMain(0, .success("支持直写（\(InjectSupport.systemDescription())）"))

        // 2. App Group
        await setStepMain(1, .running)
        let groups = PosterBoardStore.usableGroups()
        if groups.isEmpty {
            let signed = PosterBoardStore.signedGroups()
            await setStepMain(1, .failure(signed.isEmpty
                ? "签名里没有 App Group（见提示）"
                : "签名里有 \(signed.joined(separator: "、"))，但拿不到对应的 group 目录"))
            await setFooterMain("没有可用的 App Group，直写做不了。直接安装的话请用 SideStore / AltStore 签名；在 LiveContainer 里则要看 LiveContainer 本身的签名。")
            return
        }
        await setStepMain(1, .success("可用：\(groups.map { $0.group }.joined(separator: "、"))"))

        // 3. 修复残留的缓存交换
        await setStepMain(2, .running)
        let fixed = PosterBoardStore.recoverBrokenCacheSwap()
        if fixed.isEmpty {
            await setStepMain(2, .success("没什么要修的，缓存是干净的"))
        } else {
            await setStepMain(2, .success(fixed.joined(separator: "；")))
        }

        // 4. 找到 PosterBoard 容器
        await setStepMain(3, .running)
        let appHash: String
        do {
            appHash = try PosterBoardStore.findPosterBoardHash()
            await setStepMain(3, .success("找到了，容器编号 \(appHash)"))
        } catch {
            await setStepMain(3, .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            await setFooterMain("找不到 PosterBoard 容器，直写做不了。")
            return
        }

        // 5. 拿到 PosterBoard 读写权
        await setStepMain(4, .running)
        do {
            let roots = try PosterBoardStore.storeRoots(appHash: appHash)
            if roots.isEmpty {
                await setStepMain(4, .failure("拿到了读写权，但没找到带 Extensions 的版本目录"))
                await setFooterMain("PosterBoard 容器里没有可写的版本目录。")
                return
            }
            let destination = try PosterBoardStore.descriptorDestination(appHash: appHash, provider: DescriptorBuilder.providerID)
            let count = (try? PosterBoardStore.listDescriptorUUIDs(provider: DescriptorBuilder.providerID).count) ?? 0
            var message = "拿到了，可写 \(destination)，里面已有 \(count) 张"
            // 顺带探测其他含 CollectionsPoster 的扩展目录（镜像容器）各有几张。
            let mirrors = (try? PosterBoardStore.collectionPosterProviderCounts(appHash: appHash)) ?? []
            let others = mirrors.filter { $0.provider != DescriptorBuilder.providerID }
            if !others.isEmpty {
                message += "；镜像容器：" + others.map { "\($0.provider) \($0.count) 张" }.joined(separator: "、")
            }
            await setStepMain(4, .success(message))
        } catch {
            await setStepMain(4, .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            await setFooterMain("拿不到 PosterBoard 的读写权，可能是被封堵了，或者 App Group 不对。")
            return
        }

        // 6. 写入空白描述符（测试）
        await setStepMain(5, .running)
        var testWriteOK = false
        do {
            let posterUUID = try await InjectFlow.injectMinimalTest()
            await setStepMain(5, .success("写进去了，编号 \(posterUUID)"))
            await MainActor.run { testPosterUUID = posterUUID }
            testWriteOK = true
        } catch {
            await setStepMain(5, .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }

        // 7. 核对已写入的壁纸（只读：只查 store 和磁盘，不写、不删任何东西）。
        // 就算第 6 步失败了也要跑——它查的是之前写入的壁纸，和这次的测试写入无关。
        await setStepMain(6, .running)
        let verificationFailed = await verifyInjectedWallpapers()

        if testWriteOK && !verificationFailed {
            await setFooterMain("全部通过！去多任务界面把 PosterBoard 划掉，再长按锁屏点 +，画廊里应该能看到一张深蓝色的测试壁纸。确认后可以在下面删掉它。")
        } else if testWriteOK {
            await setFooterMain("测试写入通过了，但最后一步发现有已写入的壁纸在 PosterBoard 里找不到了——画廊里也看不到它们，可能是被系统清掉了。")
        } else {
            await setFooterMain("写入失败，见上面第 6 步的报错。")
        }

        // 顺带刷新文件权限对照和容器内所有描述符对照（只读），不用用户再点一次。
        refreshPermissionComparison()
        refreshDescriptorComparison()
    }

    /// 核对"我的壁纸"里每张已注入壁纸的 posterUUID 是不是还在 PosterBoard 的
    /// descriptors 目录里。主容器和镜像容器一起查，逐张显示
    /// "主容器：还在/已消失；镜像容器：还在/已消失；快照：已生成/未生成"。
    /// 对照测试描述符（如果写过）和单帧照片探针（如果写过）也一起核对。
    /// 只读：只查 store 和磁盘，不写、不删任何东西。
    /// 返回 true 表示有已消失的（或根本列不出来），false 表示全部还在
    /// （或还没有写入过的壁纸）。快照状态只做显示参考，不计入失败。
    private func verifyInjectedWallpapers() async -> Bool {
        // 待核对的条目：我的壁纸里已注入的 + 对照测试描述符（如果写过）
        // + 单帧照片探针（如果写过）。
        let (injectedItems, controlUUID, probeA, probeB) = await MainActor.run {
            (store.items.filter { $0.injectedPosterUUID != nil }, controlPosterUUID, probeAUUID, probeBUUID)
        }
        var checks: [(name: String, uuid: String, provider: String)] = injectedItems.compactMap { item in
            guard let uuid = item.injectedPosterUUID else { return nil }
            return (item.name, uuid, item.injectedProvider ?? DescriptorBuilder.providerID)
        }
        if let controlUUID {
            checks.append(("对照测试描述符（Cipher）", controlUUID, DescriptorBuilder.providerID))
        }
        if let probeA {
            checks.append(("单帧照片探针 A（1080×1920）", probeA, DescriptorBuilder.providerID))
        }
        if let probeB {
            checks.append(("单帧照片探针 B（886×1920）", probeB, DescriptorBuilder.providerID))
        }
        guard !checks.isEmpty else {
            await setStepMain(6, .success("还没有写入过的壁纸"))
            return false
        }
        do {
            let mainOnDisk = Set(try PosterBoardStore.listDescriptorUUIDs(provider: DescriptorBuilder.providerID))
            // 镜像容器：所有其他含 CollectionsPoster 的 provider 的 UUID 并集。
            var mirrorOnDisk = Set<String>()
            var mirrorChecked = false
            if let appHash = try? PosterBoardStore.findPosterBoardHash(),
               let counts = try? PosterBoardStore.collectionPosterProviderCounts(appHash: appHash) {
                for entry in counts where entry.provider != DescriptorBuilder.providerID {
                    mirrorChecked = true
                    if let uuids = try? PosterBoardStore.listDescriptorUUIDs(provider: entry.provider) {
                        mirrorOnDisk.formUnion(uuids)
                    }
                }
            }
            var lines: [String] = []
            var anyMainMissing = false
            var anyMirrorMissing = false
            for check in checks {
                let inMain = mainOnDisk.contains(check.uuid)
                let inMirror = mirrorOnDisk.contains(check.uuid)
                if !inMain { anyMainMissing = true }
                if mirrorChecked && !inMirror { anyMirrorMissing = true }
                let mainText = inMain ? "主容器：还在" : "主容器：已消失"
                let mirrorText = mirrorChecked
                    ? (inMirror ? "镜像容器：还在" : "镜像容器：已消失")
                    : "镜像容器：未找到"
                // 快照：系统渲染过这张描述符，才会在它的 versions 里生成
                // RuntimeSnapshot-lock.atx。有快照 = PosterBoard 认得并渲染过它；
                // 没快照 = 还没渲染（或渲染失败），画廊里就不会出现它。
                let snapshotText = PosterBoardStore.hasSnapshot(posterUUID: check.uuid, provider: check.provider)
                    ? "快照：已生成" : "快照：未生成"
                lines.append("\(check.name)（\(mainText)；\(mirrorText)；\(snapshotText)）")
            }
            let failed = anyMainMissing || anyMirrorMissing
            await setStepMain(6, failed
                ? .failure(lines.joined(separator: "；"))
                : .success(lines.joined(separator: "；")))
            return failed
        } catch {
            await setStepMain(6, .failure("列不出来：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"))
            return true
        }
    }

    /// 刷新「文件权限对照」：只读，列出主容器里每张描述符文件夹的所有者、
    /// POSIX 权限位（八进制）和扩展属性名。我们写的按壁纸名字显示，不在
    /// 我们记录里的按 UUID 前 8 位显示（苹果自带或之前诊断写的旧测试描述符）。
    /// 读不到属性时显示「读不到」，不崩、不写任何东西。
    private func refreshPermissionComparison() {
        guard !isCheckingPermissions else { return }
        isCheckingPermissions = true
        Task {
            let lines = await buildPermissionLines()
            await MainActor.run {
                permissionLines = lines
                isCheckingPermissions = false
            }
        }
    }

    private func buildPermissionLines() async -> [String] {
        let (ourNames, controlUUID) = await MainActor.run {
            var names: [String: String] = [:]
            for item in store.items {
                if let uuid = item.injectedPosterUUID { names[uuid] = item.name }
            }
            if let testPosterUUID { names[testPosterUUID] = "本次测试写入" }
            if let probeAUUID { names[probeAUUID] = "单帧照片探针 A（1080×1920）" }
            if let probeBUUID { names[probeBUUID] = "单帧照片探针 B（886×1920）" }
            return (names, controlPosterUUID)
        }
        let attrs = PosterBoardStore.descriptorFileAttributes(provider: DescriptorBuilder.providerID)
        guard !attrs.isEmpty else { return ["读不到描述符列表（先跑一次「开始检查」确认能拿到读写权）。"] }
        var lines: [String] = []
        for attr in attrs {
            let displayName: String
            if let name = ourNames[attr.uuid] {
                displayName = name
            } else if attr.uuid == controlUUID {
                displayName = "对照测试描述符（Cipher）"
            } else {
                displayName = "其他（\(String(attr.uuid.prefix(8)))）"
            }
            guard let owner = attr.owner, let permissions = attr.permissions, let xattrs = attr.xattrNames else {
                lines.append("\(displayName)：读不到")
                continue
            }
            let permsText = String(format: "%o", permissions)
            let xattrText = xattrs.isEmpty ? "无" : xattrs.joined(separator: "、")
            lines.append("\(displayName)：所有者 \(owner)；权限 \(permsText)；扩展属性：\(xattrText)")
        }
        return lines
    }

    /// 刷新「容器内所有描述符对照」：只读，列出主容器里每张描述符的
    /// 名字/编号/屏幕类、.ca 包、帧数、CAML 动画模式、快照和权限。
    /// 我们写的按壁纸名字显示，不在我们记录里的按 UUID 前 8 位显示
    /// （苹果自带的 4 张、对照测试、旧测试描述符、那张动漫壁纸）。
    /// 读不到的字段显示「读不到」，不崩、不写任何东西。
    private func refreshDescriptorComparison() {
        guard !isCheckingDescriptors else { return }
        isCheckingDescriptors = true
        Task {
            let lines = await buildDescriptorLines()
            await MainActor.run {
                descriptorSummaryLines = lines
                isCheckingDescriptors = false
            }
        }
    }

    /// 刷新「有快照的描述符」（构建 #21）：只列快照已生成的，和上面
    /// 对照区同一行格式。没有就直说没有，不崩。
    private func refreshSnapshotComparison() {
        guard !isCheckingSnapshots else { return }
        isCheckingSnapshots = true
        Task {
            let lines = await buildSnapshotLines()
            await MainActor.run {
                snapshotLines = lines
                isCheckingSnapshots = false
            }
        }
    }

    /// 我们写的描述符 UUID → 显示名的映射（对照区和快照区共用）。
    private func descriptorNameMap() async -> (ourNames: [String: String], controlUUID: String?) {
        await MainActor.run {
            var names: [String: String] = [:]
            for item in store.items {
                if let uuid = item.injectedPosterUUID { names[uuid] = item.name }
            }
            if let testPosterUUID { names[testPosterUUID] = "本次测试写入" }
            if let probeAUUID { names[probeAUUID] = "单帧照片探针 A（1080×1920）" }
            if let probeBUUID { names[probeBUUID] = "单帧照片探针 B（886×1920）" }
            return (names, controlPosterUUID)
        }
    }

    /// 对照区一行的格式（对照区和快照区共用）：名字/编号/屏幕类、.ca 包、
    /// 帧数、CAML 动画模式、快照、所有者、权限、扩展属性。
    private func formatDescriptorLine(
        _ summary: PosterBoardStore.DescriptorSummary,
        ourNames: [String: String],
        controlUUID: String?
    ) -> String {
        let displayName: String
        if let name = ourNames[summary.uuid] {
            displayName = name
        } else if summary.uuid == controlUUID {
            displayName = "对照测试描述符（Cipher）"
        } else {
            displayName = "其他（\(String(summary.uuid.prefix(8)))）"
        }
        var packages: [String] = []
        if summary.hasBackgroundPackage { packages.append("背景") }
        if summary.hasFloatingPackage { packages.append("浮动") }
        if summary.hasForegroundPackage { packages.append("前景") }
        let packagesText = packages.isEmpty ? "无" : packages.joined(separator: "+")
        let nameText = summary.name ?? "读不到"
        let idText = summary.identifier.map(String.init) ?? "读不到"
        let screenClassText = summary.logicalScreenClass ?? "读不到"
        let frameText = summary.frameCount.map(String.init) ?? "读不到"
        let modeText = summary.calculationMode ?? "读不到"
        let snapshotText = summary.hasSnapshot ? "已生成" : "未生成"
        let permsText = summary.permissions.map { String(format: "%o", $0) } ?? "读不到"
        let ownerText = summary.owner ?? "读不到"
        let xattrText: String
        if let xattrs = summary.xattrNames {
            xattrText = xattrs.isEmpty ? "无" : xattrs.joined(separator: "、")
        } else {
            xattrText = "读不到"
        }
        return "\(displayName)：名字 \(nameText)；编号 \(idText)；屏幕类 \(screenClassText)；包：\(packagesText)；帧数 \(frameText)；动画 \(modeText)；快照：\(snapshotText)；所有者 \(ownerText)；权限 \(permsText)；扩展属性：\(xattrText)"
    }

    private func buildDescriptorLines() async -> [String] {
        let (ourNames, controlUUID) = await descriptorNameMap()
        let summaries = PosterBoardStore.allDescriptorSummaries(provider: DescriptorBuilder.providerID)
        guard !summaries.isEmpty else { return ["读不到描述符列表（先跑一次「开始检查」确认能拿到读写权）。"] }
        return summaries.map { formatDescriptorLine($0, ourNames: ourNames, controlUUID: controlUUID) }
    }

    /// 只列快照已生成的描述符（构建 #21）：动漫壁纸应该在里面。
    private func buildSnapshotLines() async -> [String] {
        let (ourNames, controlUUID) = await descriptorNameMap()
        let summaries = PosterBoardStore.allDescriptorSummaries(provider: DescriptorBuilder.providerID)
        let withSnapshot = summaries.filter { $0.hasSnapshot }
        guard !withSnapshot.isEmpty else {
            return ["没有快照已生成的描述符（动漫壁纸不在里面，说明它的快照也不在主容器里）。"]
        }
        return withSnapshot.map { formatDescriptorLine($0, ourNames: ourNames, controlUUID: controlUUID) }
    }

    @MainActor
    private func setStepMain(_ id: Int, _ status: StepStatus) async {
        setStep(id, status)
    }

    @MainActor
    private func setFooterMain(_ message: String) async {
        footerMessage = message
    }

    private func deleteTestWallpaper() {
        guard let posterUUID = testPosterUUID, !isDeletingTest else { return }
        isDeletingTest = true
        Task {
            do {
                try PosterBoardStore.deleteDescriptor(posterUUID: posterUUID, provider: DescriptorBuilder.providerID)
                await MainActor.run {
                    testPosterUUID = nil
                    footerMessage = "测试壁纸已删掉。"
                    isDeletingTest = false
                }
            } catch {
                await MainActor.run {
                    footerMessage = "删除失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    isDeletingTest = false
                }
            }
        }
    }

    /// 写入对照测试描述符：一份完整的真实 Cipher 描述符原样写进 PosterBoard。
    /// 走和正常注入完全相同的 writeDescriptors 路径。写完记下它的 UUID，
    /// 第 7 步核对会一起显示它，之后也可以在这里删掉。
    private func writeControlTest() {
        guard !isWritingControl else { return }
        isWritingControl = true
        controlMessage = nil
        Task {
            do {
                let posterUUID = try await InjectFlow.injectControlTest()
                await MainActor.run {
                    controlPosterUUID = posterUUID
                    UserDefaults.standard.set(posterUUID, forKey: Self.controlPosterUUIDKey)
                    controlMessage = "对照描述符已写入，编号 \(posterUUID)。点「立即注销桌面生效」，再长按锁屏点 +、滑到底部「收藏」里找这张真实壁纸（WWDC 2022 彩色图案）。"
                    isWritingControl = false
                }
            } catch {
                await MainActor.run {
                    controlMessage = "写入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    isWritingControl = false
                }
            }
        }
    }

    private func deleteControlTest() {
        guard let posterUUID = controlPosterUUID, !isDeletingControl else { return }
        isDeletingControl = true
        Task {
            do {
                try PosterBoardStore.deleteDescriptor(posterUUID: posterUUID, provider: DescriptorBuilder.providerID)
                await MainActor.run {
                    controlPosterUUID = nil
                    UserDefaults.standard.removeObject(forKey: Self.controlPosterUUIDKey)
                    controlMessage = "对照测试描述符已删掉。"
                    isDeletingControl = false
                }
            } catch {
                await MainActor.run {
                    controlMessage = "删除失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    isDeletingControl = false
                }
            }
        }
    }

    /// 删除两个单帧照片探针（复用 deleteDescriptor，主容器 + 镜像一起清）。
    /// 删完清除 UserDefaults 里的记录，第 7 步就不再核对它们。
    /// 某个探针已经不在磁盘上了也算删干净了（系统可能已经清掉它）。
    private func deleteProbes() {
        guard !isDeletingProbes else { return }
        let uuids = [probeAUUID, probeBUUID].compactMap { $0 }
        guard !uuids.isEmpty else { return }
        isDeletingProbes = true
        Task {
            var failures: [String] = []
            for uuid in uuids {
                do {
                    try PosterBoardStore.deleteDescriptor(posterUUID: uuid, provider: DescriptorBuilder.providerID)
                } catch InjectError.wallpaperNotFound {
                    // 已经不在了，算删干净了
                } catch {
                    failures.append(uuid)
                }
            }
            await MainActor.run {
                if failures.isEmpty {
                    probeAUUID = nil
                    probeBUUID = nil
                    UserDefaults.standard.removeObject(forKey: InjectFlow.singlePhotoProbeAKey)
                    UserDefaults.standard.removeObject(forKey: InjectFlow.singlePhotoProbeBKey)
                    probeMessage = "两个探针已删掉。"
                } else {
                    probeMessage = "删除失败：\(failures.count) 个探针没删掉。"
                }
                isDeletingProbes = false
            }
        }
    }
}
