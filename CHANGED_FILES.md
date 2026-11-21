# 本次改动文件清单（一键写入锁屏 + 倒置修复）

按下面顺序，在 GitHub 网页上替换/新建这些文件（"新建"表示仓库里原来没有，
要点 Add file → Create new file；"替换"表示打开原文件点铅笔编辑，把整
个文件内容换掉；"改一行"是小改动，也可以整文件替换）。

⚠️ 注意：LICENSE、.entitlements 和 Bridging Header 都是新文件，别漏了；
VideoRenderer.swift 的倒置修复也在本次一起上（两处小改）。

## 新建（按顺序传）

1. `LICENSE`（新建，仓库根目录）
   - GPL-3.0 许可证全文。整个项目因此改为 GPL-3.0 开源。
2. `BizhiGongfang/Inject/WorseQuery.h`（新建）
3. `BizhiGongfang/Inject/WorseQuery.m`（新建）
   - 沙盒逃逸核心，移植自 forcequitOS/worse_query（经 Placard 改进的备份恢复版）。
4. `BizhiGongfang/Inject/ContainerEnumeration.h`（新建）
5. `BizhiGongfang/Inject/ContainerEnumeration.m`（新建）
   - 枚举系统容器，移植自 Placard。
6. `BizhiGongfang/Inject/GestaltAppGroupResolver.h`（新建）
7. `BizhiGongfang/Inject/GestaltAppGroupResolver.m`（新建）
   - 从签名里读 App Group，移植自 Placard。
8. `BizhiGongfang/Inject/GroupRoot.h`（新建）
9. `BizhiGongfang/Inject/GroupRoot.m`（新建）
   - LiveContainer 替身 App Group 修正 + 系统 build 号判断（自己写）。
10. `BizhiGongfang/Inject/PosterBoardStore.swift`（新建）
11. `BizhiGongfang/Inject/DescriptorBuilder.swift`（新建）
12. `BizhiGongfang/Inject/InjectSupport.swift`（新建）
13. `BizhiGongfang/Inject/InjectButton.swift`（新建）
14. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（新建）
15. `BizhiGongfang/BizhiGongfang.entitlements`（新建）
    - App Group 权限，直写必需。
16. `BizhiGongfang/BizhiGongfang-Bridging-Header.h`（新建）
    - ObjC 直写代码的桥接头文件。

## 替换（整文件内容换掉）

17. `project.yml`（替换）
    - 加了 entitlements 和 SWIFT_OBJC_BRIDGING_HEADER；部署目标仍是 iOS 17.0。
18. `BizhiGongfang/Models/WallpaperStore.swift`（替换）
    - 加了"已写入锁屏"记录（posterUUID、时间、provider）+ markInjected / clearInjected。
19. `BizhiGongfang/Views/MorphEditorView.swift`（替换）
    - 加了"一键写入锁屏"按钮 + injectToLockScreen。
20. `BizhiGongfang/Views/DepthEditorView.swift`（替换）
    - 同上。
21. `BizhiGongfang/Views/VideoEditorView.swift`（替换）
    - 同上（先裁剪再写入）。
22. `BizhiGongfang/Views/WallpaperListView.swift`（替换）
    - 右上角"直写诊断"入口 + 已写入锁屏标记。
23. `BizhiGongfang/Views/WallpaperDetailView.swift`（替换）
    - 加了"删除锁屏里的这张壁纸"按钮。
24. `BizhiGongfang/BizhiGongfangApp.swift`（替换）
    - 启动时修一次直写缓存（防上次崩溃留下的符号链接）。
25. `BizhiGongfang/LivePhoto/VideoRenderer.swift`（替换）
    - **倒置修复**：drawAspectFill 改用 image.size + image.draw(in:)，
      不再用 context.draw(cgImage)，预览和导出的视频都不再上下颠倒。
26. `README.md`（替换）
    - 一键写入说明 + GPL-3.0 声明。

## 不用动的文件

- `.github/workflows/ios.yml`、codemagic.yaml：不用改。
- 其他 LivePhoto / Views 文件：没动。

## 不用删除的文件

- 没有要删除的文件。

## 传完之后

提交后 Actions 会自动重编，跑完在 Releases 里下新 IPA（未签名 IPA（构建 #N））。
先在 LiveContainer 里装新版，点「我的壁纸」右上角「直写诊断」→「开始检查」，
一步一步看结果（见 INJECT_RESEARCH.md 第 7.4 节的测试顺序）。

## 修复 B + C（2026-11-20，待与修复 A 一起编构建 #13）

27. `BizhiGongfang/Inject/DescriptorBuilder.swift`（修复 B：强制竖屏设备原生尺寸）
    - buildDescriptor 不再用源视频尺寸算输出尺寸（删了 fittedSize），改用新加的
      devicePortraitOutputSize()：强制设备原生竖屏尺寸（Placard VideoWallpaper.swift
      的算法）——iPhone 按 UIScreen.main.nativeBounds 的长短边比例，长边上限仍为
      1920，短边向下取偶数；iPad 按 810:1080 的比例。iPhone 13 Pro 上竖屏源
      （1080×1920）和横屏源（如 1920×1080）都得 886×1920。
    - 取 UIScreen.main 包在 await MainActor.run { } 里（buildDescriptor 是 static
      func，不在 MainActor 上）。logicalScreenClass 等其他字段没动。

28. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（修复 C：诊断核对已注入描述符）
    - 诊断加了第 7 步「核对已写入的壁纸」：跑完 6 步后，用现成的
      PosterBoardStore.listDescriptorUUIDs 列出 store 里全部描述符 UUID，再与
      WallpaperStore 里每张壁纸的 injectedPosterUUID 逐一比对（store 本来就
      是 @EnvironmentObject，不用改传参），逐张显示「还在」或「已消失」（含壁纸名字）。
    - 这一步只读：只查 store 和磁盘，不写、不删任何东西；就算第 6 步测试写入失败
      了也会跑。页脚文案按「测试写入是否成功 × 核对是否有消失」分三种情况显示。

## 修复 A（2026-11-20，注入后注销桌面，待与修复 B、C 一起编构建 #13）

29. `BizhiGongfang/Inject/NeoSpring.swift`（新建）
    - 移植自 AirCard-iOS 的 RespringHelper.swift（GPL-3.0）：WebKit GPU 进程
      respring。注入成功后弹提示卡片，用户点「立即注销桌面生效」才触发——不
      自动触发，因为 LiveContainer 里注销会先把客 App 挂起，必须用户自己决定。
    - 含 RespringPromptView（说明 + 两个选择）、RespringPromptModifier 和
      View.respringPrompt 扩展；提示里写明了 LiveContainer 下注销后要重新进
      LiveContainer 打开本 App，写好的壁纸不会丢。
    - project.yml 不用改：sources 是整个 BizhiGongfang 文件夹，新文件自动编入。
30. `BizhiGongfang/Views/MorphEditorView.swift`（替换）
31. `BizhiGongfang/Views/DepthEditorView.swift`（替换）
32. `BizhiGongfang/Views/VideoEditorView.swift`（替换）
    - 三个编辑器都接了 `.respringPrompt`：注入成功才弹注销提示（写入失败仍
      走原来的失败弹窗，不弹注销提示）。
33. `BizhiGongfang/Inject/InjectSupport.swift`（替换）
    - successGuidance 改写：先讲注销桌面（只划掉 PosterBoard 不够），再讲长按
      锁屏点 +、滑到底部「收藏」里找；不想注销也可以点「不用了」，壁纸已写进去，
      之后注销一次桌面就会出现。

## 构建 #13 上传清单（只传这 7 个文件，其余不动）

- 新建：`BizhiGongfang/Inject/NeoSpring.swift`
- 替换：`BizhiGongfang/Inject/DescriptorBuilder.swift`（修复 B）、
  `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（修复 C）、
  `BizhiGongfang/Inject/InjectSupport.swift`（修复 A 文案）、
  `BizhiGongfang/Views/MorphEditorView.swift`、
  `BizhiGongfang/Views/DepthEditorView.swift`、
  `BizhiGongfang/Views/VideoEditorView.swift`（修复 A 接线）
- project.yml、entitlements、其他文件都不用动。

## 构建 #13 测试顺序

1. 装新 IPA，先跑一次「直写诊断」——第 7 步会逐张核对之前三张已注入的壁纸
   还在不在磁盘上（之前诊断第 5 步数出来是 6 张，应为 8 张，少了 2 张）。
2. 做一张变身壁纸点「一键写入锁屏」，成功后弹注销提示，点「立即注销桌面生效」。
3. 桌面重启后重新进 LiveContainer 打开本 App，长按锁屏点 +，滑到底部「收藏」
   里找那张壁纸。
4. 注意：NeoSpring 在 LiveContainer 里还没验证过——如果点了注销但桌面没重启，
   说明这招在 LiveContainer 里不生效，告诉 Muse，换别的办法。

## 修复 A（2026-11-20，与修复 B + C 一起编构建 #13）

背景：注入的视频壁纸写进去了、画廊里却不出现。排障结论是描述符内容与 Placard 原版
逐字一致，病根是缺 respring——画廊读的是快照索引 PRPosterRoleLockScreen-gallery-
index.json，只有 SpringBoard 重启才重建，光划掉 PosterBoard、甚至重启手机都不够；
Camlo / Placard / AirCard 三家装完都自动 respring。

29. `BizhiGongfang/Inject/NeoSpring.swift`（新文件，修复 A：移植 NeoSpring）
    - 照抄 AirCard-iOS 的 RespringHelper.swift（Mak5er/AirCard-iOS，
      https://github.com/Mak5er/AirCard-iOS/blob/main/ios-app/RespringHelper.swift，
      GPL-3.0）：`neospringHTML` 已逐字核对与原版完全一致（1628 字符）——iframe +
      500 个 backdrop-filter div + setInterval 里 navigator.share 和 10MB buffer；
      `RespringHelper.triggerNeoSpring()`（往 key window 贴全屏 WKWebView）、
      `NeoSpringView`（UIViewRepresentable 包装）、`openWallpaperSettings()`（跳到
      设置 › 墙纸）都在。原版的 `import AirliftFFI` 是 AirCard 自己的库，这里用不到，
      已去掉。出处注释保留在文件头（WebKit GPU 进程 respring 技术 @neonmodder123、
      Swift 实现 @skadz108、@rooootdev）。
    - 新加 `RespringPromptView`：注入成功后弹出的注销提示卡片，显示更新后的
      `InjectSupport.successGuidance`，另有一行橙色小字说明 LiveContainer 下注销会
      先退出本 App（桌面重启后重新进 LiveContainer 打开即可，壁纸不会丢）；两个选择：
      醒目的「立即注销桌面生效」（borderedProminent）和「不用了，稍后再说」。
    - 新加 `RespringPromptModifier` + `View.respringPrompt(isPresented:respringing:)`：
      sheet 弹提示，点「立即注销桌面生效」后关 sheet、把 respringing 置 true，
      `.overlay { if respringing { NeoSpringView().ignoresSafeArea() } }` 全屏展示。
      不自动触发——LiveContainer 下注销会把客 App 挂起，必须让用户自己决定点不点。

30. `BizhiGongfang/Inject/InjectSupport.swift`（修复 A：更新成功引导）
    - `successGuidance` 重写：先讲注销桌面这一步（画廊要重建索引才会出现新壁纸，
      只划 PosterBoard 不够），再讲长按锁屏点 +、滑到底部「收藏」里找；最后说明
      点「不用了」也没关系——壁纸已经写进去了，之后只要注销一次桌面，画廊里就会出现它。
      诊断页「写入成功后怎么查看」用的也是这段文字。

31. `BizhiGongfang/Views/MorphEditorView.swift`、`DepthEditorView.swift`、
    `VideoEditorView.swift`（修复 A：接入注销提示，三处改法相同）
    - 各加两个 @State：`showRespringPrompt`、`respringing`。
    - body 链上加 `.respringPrompt(isPresented: $showRespringPrompt, respringing: $respringing)`。
    - `injectToLockScreen` 成功分支不再弹 `successGuidance` 的 alert，改为
      `showRespringPrompt = true`；失败分支仍走原来的 alert。导出 Live Photo 的
      alert 不动。

注意（待真机验证）：NeoSpring 在 LiveContainer 里是否生效未经验证——它是靠挤爆
WebKit GPU 进程拖垮宿主 SpringBoard，Placard / Camlo / AirCard 均在 SideStore /
AltStore 直装环境验证。测试时：注入成功 → 点「立即注销桌面生效」→ 屏幕黑一下、
桌面重启 → 长按锁屏点 +、滑到底部「收藏」找壁纸。如果注销后本 App 被挂起，重新进
LiveContainer 打开即可。

## 修复：补描述符骨架 + 写后收尾（2026-11-20，编构建 #15）

背景：v14 实测——写入成功、respring 也成功，但描述符随后被 PosterBoard
扫描删掉（诊断第 5 步只剩最初 4 张，第 7 步「已消失」），连 1 帧空白测试
描述符也活不下来。排障报告 2（INJECT_DIAGNOSIS2.md）结论：(1) 描述符
是不完整骨架——每个 `.ca` 包的 index.xml 声明了 `assetManifest.caml`
但文件不存在，PosterKit 加载失败；还缺 7 个种子文件；(2) 写完少了
Camlo / AirCard 的收尾动作：镜像第二容器、清 GalleryCache、写
PosterBoard 持久化偏好。按报告第七节一次全上（修复 1+2+3+4）。
明确不做：不往 gallery-index.json 登记（已证伪，它是快照缓存）、
不改写路径 copy 逻辑、不改 CAML / Wallpaper.plist 模板。

32. `BizhiGongfang/Inject/DescriptorBuilder.swift`（修复 1 + 修复 4）
    - 新增 `seedDescriptorFiles(at:animationURL:floatingURL:)`，
      `buildDescriptor` 和 `buildMinimalDescriptor` 写完 main.caml /
      index.xml 后都调它。
    - 每个 `.ca` 包（Background / Floating）补 `assetManifest.caml`，
      空 MicaAssetManifest，177 字节（末尾含换行，已核对），内容逐字照
      真 .tendies 包（Cipher）和 Camlo 模板。
    - 补 7 个种子文件（内容原样取自 Camlo 的 PosterSeed.bundle，
      GPL-3.0，以 base64 常量嵌进 Swift，不依赖 bundle 资源；
      7 个文件字节数 417/417/378/691/8821/729/269，与报告一致，
      解码后已逐字节核对与原文件相同）：
      `versions/1/RuntimeSnapshotMetadata-home.plist`、
      `versions/1/RuntimeSnapshotMetadata-lock.plist`、
      `versions/1/com.apple.posterkit.provider.instance.complicationLayout.plist`、
      `versions/1/com.apple.posterkit.provider.instance.titleStyleConfiguration.plist`、
      `versions/1/supplements/0/com.apple.posterkit.provider.supplementURL.homescreenConfiguration.plist`
      （先建 `supplements/0` 目录）、
      `versions/1/contents/.com.apple.posterkit.provider.contents.configurableOptions.plist`
      （文件名以 `.` 开头）、
      `versions/1/contents/com.apple.posterkit.provider.contents.otherMetadata.plist`。
    - 不种子 `suggestionMetadata.plist`（含苹果 7400 模板值，Camlo
      自己都会在冲突时删掉它）；不补 Foreground `.ca` 包。
    - identifier 改成 Camlo 的递减 ID：新增 `nextDescendingIdentifier()`，
      UserDefaults 存 `BizhiGongfang.nextDescendingWallpaperID`，从 19999
      开始每次减 1，用到 10100 后回到 19999；三处同步的逻辑不变，
      只是 ID 来源换了（`Int.random` 已无残留）。

33. `BizhiGongfang/Inject/PosterBoardStore.swift`（修复 2）
    - 新增 `postWriteRefresh(appHash:provider:writtenPaths:)`，
      `writeDescriptors` 在返回前、持有的读写权释放前调用；不抛错，
      收尾失败只记 NSLog，绝不把一次已成功的写入变成失败。
    - 2a 镜像：新增 `mirrorDescriptors`，枚举 `<storeRoot>/Extensions`
      下所有名字含 `CollectionsPoster`（大小写不敏感）且不等于当前
      provider 的目录，把同一批描述符文件夹（同一个 UUID 文件夹名，
      原样复用）复制到其 `descriptors/` 下（不存在就先建）；至少覆盖
      `com.apple.Posters.CollectionsPosterApp`。单个目标失败只记日志。
    - 2b 清 GalleryCache：新增 `clearGalleryCache`，删
      `<storeRoot>/GalleryCache` 里的全部内容，不删目录本身；
      目录不存在就跳过。
    - 2c 写偏好：新增 `writePosterBoardPreferences` +
      `writeMergedPreferences`，写
      `com.apple.PosterBoard.unprotectedUserDefaults.plist`（binary
      plist，已存在先读出合并，只增改键，不删已有键）到两个位置：
      `<PosterBoard 容器>/Library/Preferences/` 和
      `/var/mobile/Library/Preferences/`（后者拿不到读写权就只写容器内
      那份并记日志，不阻塞）。内容照抄 AirCard：`PBF_RESET_FILE_PROTECTIONS:
      true`、`PBF_LOCALE_DID_CHANGE: true`、
      `PersistedPosterContainerBundleIdentifiers`（5 个）、
      `CompletedPosterBundleIdentifierMigrations`（6 个）。
    - 新增 `collectionPosterProviderCounts(appHash:)`（供诊断用）：
      列出 Extensions/ 下所有含 CollectionsPoster 的 provider 及各有几张。

34. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（修复 3）
    - 第 5 步数完主 provider 张数后，顺带探测并显示其他含
      CollectionsPoster 的目录（镜像容器）各有几张。
    - 第 7 步 `verifyInjectedWallpapers` 改为两个容器一起查，逐张显示
      「主容器：还在/已消失；镜像容器：还在/已消失」；镜像容器未找到时
      显示「镜像容器：未找到」，不计入失败。

未改动：`InjectSupport.swift`（`postWriteRefresh` 在 `writeDescriptors`
内部调，两个调用点不用动）、`project.yml`（无新增文件，种子数据嵌在
代码里）、CAML / Wallpaper.plist 模板、gallery-index.json。

验证：三处改动文件括号/圆括号/方括号全部平衡；7 个种子 base64 常量
从 Swift 文件里提取解码后与 Camlo 原文件逐字节相同；assetManifestCAML
按 Swift 字符串拼接语义算出 177 字节，与真包一致；`Int.random`、
`__SEED_BASE64` 占位均无残留。本地无 Mac、未编译，语法只做了人工通读
+ 括号平衡检查。

遗留注意（不在本次任务内，待 parent 决定）：`deleteDescriptor` 只删主
容器的描述符文件夹，镜像容器的那份不会一起删——详情页「删除锁屏里的
这张壁纸」和诊断页「删除刚才写入的测试壁纸」删完后，镜像容器里可能
还留一份。如需修，应在 `deleteDescriptor` 里对同一 posterUUID 也清
镜像容器（及 GalleryCache/偏好不用动）。

**已补（2026-11-20 15:33，parent 直接修，编构建 #15 前）**：`deleteDescriptor`
在主容器删除成功后，顺手枚举同一版本根下其他含 CollectionsPoster 的
扩展目录，把同一 posterUUID 的镜像文件夹也删掉（失败只记 NSLog，不阻
塞主删除；路径同样校验 `hasPrefix(root + "/Extensions/")`）。三处改动
文件括号/圆括号/方括号已复核平衡。

## 对照测试：原样写一份真实描述符（2026-11-20，编构建 #16）

背景：构建 #15 修好了删除问题——v15 实测诊断第 5 步计数从 4 张一路涨到
8 张，第 7 步「变身壁纸 11-20 15:46（主容器：还在）」，写进去的东西一个
都没再被删；用户确认注入后点了「立即注销桌面生效」（NeoSpring respring
成功），但锁屏画廊「收藏」里还是找不到。问题从「被删」变成了「画廊不显示」。
排障报告 3（INJECT_DIAGNOSIS3.md）结论：写入路径与 Placard 逐行一致、
收尾动作与 Camlo / AirCard 一致，剩下的分歧只在描述符内容本身（最大的
是 logicalScreenClass 用了 iPad 类 `810w-1080h@2x~ipad`、缺 Foreground
包）或写入环境（LiveContainer 文件权限、PosterBoard 是不是真的重启了）。
先做对照测试分清是哪一边，再决定改什么——不要再凭猜测改描述符。

做法：在 App 里嵌一份完整的真实 Cipher.tendies 描述符（SerStars /
nugget-wallpapers，描述符 09E9B685-7456-4856-9C10-47DF26B76C33，源自苹果
WWDC22 模板），诊断页一键原样写进去，只改文件夹 UUID 和三处 identifier，
走和正常注入完全相同的 writeDescriptors 路径。

35. `BizhiGongfang/Inject/ControlDescriptorData.swift`（新建，机器生成，2,433,269 字节）
    - Cipher 描述符文件夹按文件逐个 base64：共 80 个文件，1,815,321 字节。
      已剔除 `__MACOSX` / `.DS_Store` / `._*`（Camlo 归一化时也会删掉的 junk）。
      每个文件的 base64 按 32768 字符切段用 `+` 拼接。
    - 生成脚本在 /tmp/diag3/gen_control_data.py（不在仓库里）；生成后自校验过：
      从生成的 Swift 里把 base64 全解出来，与原文件逐字节相同（80/80）。
    - 注意：这个文件很大，构建时会比平时慢一点，属于正常现象。

36. `BizhiGongfang/Inject/ControlDescriptor.swift`（新建）
    - `buildControlDescriptor(in:)`：把嵌好的数据重建一份描述符文件夹，
      只改三处 identifier（描述符 identifier 文件、userInfo 的
      wallpaperRepresentingIdentifier、Wallpaper.plist 的 identifier），
      换成同一个新的递减 ID（共用 DescriptorBuilder 的计数器，保证和正常
      注入的 ID 不撞）。其余一律不动：suggestionMetadata.plist 原样保留
      （7400.DYNAMIC），assets 里的 identifier（7400）不动（跟 .ca 文件名
      绑定，Camlo 的做法），文件名、logicalScreenClass
      （390w-844h@3x~iphone）、CAML、种子文件全部原样。
      这和 Placard 安装社区 .tendies 包的做法一致。

37. `BizhiGongfang/Inject/InjectSupport.swift`（替换）
    - 新增 `InjectFlow.injectControlTest()`：重建对照描述符 → 找 PosterBoard
      → `writeDescriptors`（和正常注入同一条路径，同样享受 postWriteRefresh
      的镜像 + 清缓存 + 写偏好）→ 返回 poster UUID。

38. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
    - 新增 `hasSnapshot(posterUUID:provider:)`（只读）：查描述符文件夹的
      versions 里有没有系统渲染后生成的 `RuntimeSnapshot-lock.atx`。
      有 = PosterBoard 加载并渲染过这张描述符；没有 = 还没渲染（或渲染失败），
      画廊里就不会出现它。供诊断第 7 步显示参考，不计入失败。

39. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）
    - 新增「对照测试」区：按钮「写入对照测试描述符」（写完显示编号和后续步骤；
      诊断运行时禁用），按钮「删除对照测试描述符」（复用 deleteDescriptor）。
      对照 UUID 存在 UserDefaults（`BizhiGongfang.controlTestPosterUUID`），
      杀掉 App 重进后第 7 步还能继续核对它。
    - 第 7 步核对：除「我的壁纸」里已注入的，还会核对对照测试描述符，逐张显示
      「主容器：还在/已消失；镜像容器：还在/已消失；快照：已生成/未生成」。
      快照状态只做显示参考，不计入失败。

40. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换，一处小改）
    - `nextDescendingIdentifier()` 由 `private` 改为 internal（去掉了 `private`），
      仅此一处改动——对照测试共用同一个计数器。其他逻辑一律不动。

未改动：`project.yml`（sources 是整个 BizhiGongfang 文件夹，两个新文件自动
编入）、CAML / Wallpaper.plist 模板、gallery-index.json（仍不碰）、
InjectButton / 三个编辑器 / WallpaperStore / NeoSpring。

验证：6 个改动文件括号/圆括号/方括号全部平衡；关键标识 grep 能找到
（injectControlTest、buildControlDescriptor、hasSnapshot、
controlPosterUUID、nextDescendingIdentifier）；ControlDescriptorData 自校验
80/80 文件解码后逐字节相同。本地无 Mac、未编译，语法只做了人工通读 +
括号平衡检查。

## 构建 #16 上传清单（只传这 6 个文件，其余不动）

- 新建：`BizhiGongfang/Inject/ControlDescriptorData.swift`（2.4 MB，注意体积）、
  `BizhiGongfang/Inject/ControlDescriptor.swift`
- 替换：`BizhiGongfang/Inject/InjectSupport.swift`、
  `BizhiGongfang/Inject/PosterBoardStore.swift`、
  `BizhiGongfang/Inject/InjectDiagnosticsView.swift`、
  `BizhiGongfang/Inject/DescriptorBuilder.swift`（只改了一处 private）
- project.yml、entitlements、其他文件都不用动。

## 构建 #16 测试顺序

1. 装新 IPA，进「直写诊断」，点「写入对照测试描述符」，记下编号。
2. 点「立即注销桌面生效」，桌面重启后重进 LiveContainer。
3. 再进「直写诊断」跑一次，看第 7 步：对照测试描述符「主容器：还在」吗？
   快照「已生成」还是「未生成」？
4. 长按锁屏点 +，滑到底部「收藏」里找这张真实壁纸（WWDC 2022 彩色图案）。
5. 结果怎么解读（见 INJECT_DIAGNOSIS3.md 第六节）：
   - 对照描述符在收藏里出现了 → 我们的描述符内容有问题，下一步按报告排序改
     （先改 logicalScreenClass 为 iPhone 类，再补 Foreground 包）。
   - 对照描述符也没出现 → 问题不在描述符内容，在写入环境或画廊刷新
     （下一步查 LiveContainer 文件权限、确认 PosterBoard 真的重启了）。
   - 对照描述符还在磁盘上但快照「未生成」→ PosterBoard 没渲染它，重点查
     渲染环节（快照服务读不到文件、或描述符加载失败）。
6. 测完可以在诊断页点「删除对照测试描述符」清掉它。

## 构建 #17 准备（2026-11-20，原因 5 对照实验 + 原因 4 取证）

背景：构建 #16 对照测试结果（2026-11-20 16:24 CST 实测）：对照描述符
（原样真 Cipher）和新变身壁纸 11-20 16:23 都在主容器里（第 7 步「主容器：
还在」），但两个的快照都是「未生成」，画廊里还是什么都没有。结论：连原样
真包都不渲染，问题不在我们描述符内容（原因 1 iPad 类、原因 2 Foreground /
#00000 暂时都不是主因），在写入环境/渲染环节。按排障报告 3 第八节，下一步
是原因 3 验证（用户做：respring 后划掉 PosterBoard）→ 原因 5 → 原因 4。
本次只做原因 5 的对照实验 + 原因 4 的取证工具，不改描述符内容。

41. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换，两处改动）
    - 原因 5：`writePosterBoardPreferences` 里 `PBF_LOCALE_DID_CHANGE` 由
      `true` 改成 `false`（Camlo 的值；构建 #15 用的是 AirCard 的 true）。
      只改这一个值，其他偏好键原样不动。这是对照实验：改完若画廊出现，
      说明 true 是问题；若仍不出现，原因 5 排除。
    - 原因 4 取证：新增 `DescriptorFileAttributes`（uuid / owner /
      permissions / xattrNames）+ `descriptorFileAttributes(provider:)`
      （只读，列出某个 provider 下每个描述符文件夹的文件属性，沿用
      hasSnapshot 的读路径：先拿读写权再读，读完释放）+
      `extendedAttributeNames(atPath:)`（只读，只列扩展属性名、不读值；
      listxattr 是公开 BSD API，ObjC 层 ContainerEnumeration.m 也用
      同一头文件 <sys/xattr.h> 的 getxattr；万一 Swift 编译器认不出
      listxattr，改走 ObjC 层加同名小 helper 即可，逻辑不用改）。
      读不到属性时对应字段为 nil，界面显示「读不到」，不抛错、不崩。

42. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）
    - 新增「文件权限对照」区（只读显示，不写任何东西）：每张描述符文件夹
      的所有者、POSIX 权限位（八进制）和扩展属性名。我们写的按壁纸名字显示
      （「我的壁纸」里已注入的 + 本次测试写入 + 对照测试描述符），不在记录
      里的按 UUID 前 8 位显示（苹果自带或之前诊断写的旧测试描述符，说明
      文字里写清楚了）。一行一个描述符，纯文本，和第 7 步一个样式。
    - 有「查看文件权限对照」按钮可单独刷新（不触发第 6 步的测试写入）；
      跑完整诊断（「开始检查」）时也会在第 7 步后顺带刷新一次。

未改动：`project.yml`（无新增文件）、DescriptorBuilder / CAML /
Wallpaper.plist 模板（原因 1、2 暂时不动）、gallery-index.json（仍不碰）、
InjectSupport / ControlDescriptor / 三个编辑器 / NeoSpring。

上游核查（2026-11-20，/tmp/diag3/upstream 的三家源码重查）：除了 respring、
杀掉 PosterBoard、清 GalleryCache + 写偏好（都已在做），**没找到**别的触发
PosterBoard 渲染/生成快照的动作——三家代码里没有任何 Darwin 通知
（notify_post / CFNotificationCenter）、没有任何 touch / utimens、
没有任何强制生成快照的私有 API。AirCard 的 tunnel respring 要配对隧道，
LiveContainer 里用不上；Camlo 的 respring 看门狗最后会打开 PosterBoard
App 本身（界面动作，不是渲染触发器），可当作下一步的实验，不实现。

验证：两处改动文件括号/圆括号/方括号全部平衡；关键标识 grep 能找到
（PBF_LOCALE_DID_CHANGE: false、descriptorFileAttributes、
extendedAttributeNames、文件权限对照、refreshPermissionComparison）。
本地无 Mac、未编译，语法只做了人工通读 + 括号平衡检查。

## 构建 #17 上传清单（只传这 2 个文件，其余不动）

- 替换：`BizhiGongfang/Inject/PosterBoardStore.swift`、
  `BizhiGongfang/Inject/InjectDiagnosticsView.swift`
- project.yml、其他文件都不用动。

## 构建 #17 测试顺序

1. 装新 IPA，先跑一次「直写诊断」——看「文件权限对照」区：我们写的
   （变身壁纸、对照测试描述符、本次测试写入）和「其他」那几行的所有者、
   权限、扩展属性是不是一样。把截图发给 Muse。
2. 做一张变身壁纸点「一键写入锁屏」（这次写入会带上 PBF_LOCALE_DID_CHANGE=false
   的偏好），点「立即注销桌面生效」。
3. 桌面重启后，去多任务界面把 PosterBoard 划掉，再重进 LiveContainer。
4. 再跑一次诊断，看第 7 步快照状态（已生成/未生成）和「文件权限对照」。
5. 长按锁屏点 +，滑到底部「收藏」里找壁纸。
6. 结果怎么解读（见 INJECT_DIAGNOSIS3.md 末尾「构建 #17 准备」一节）：
   - 画廊出现了 → 原因 5（偏好 true）就是问题，修好了。
   - 还是没有，但权限对照显示我们写的和苹果的不一样 → 按那节的思路修
     （写完改权限/清扩展属性）。
   - 还是没有，权限对照也完全一样 → 原因 4、5 都排除，重点回原因 3
     （PosterBoard 到底重启了没有）和快照服务本身。

## 排障报告 4（2026-11-20，v16 实测后：单帧能用、多帧不行）

报告：`INJECT_DIAGNOSIS4.md`（本次新建，中文，约 34KB）。

### 证据（2026-11-20 16:40–16:49 CST，iPhone 13 Pro iOS 27.0.1，LiveContainer）

- 画廊「iPhone 13 Pro」区 8 张描述符全列出来了；点进去试：1、2、4、6、8 能点进去，
  里面全是纯蓝；3、5、7 是一片黑 tile，点了没反应。
- 磁盘上 8 张：5 张空白测试（1 帧纯蓝 1080×1920）+ 2 张变身视频（45 帧 886×1920）
  + 1 张对照 Cipher（原样真包 390×844）。快照：变身 16:23 和对照 Cipher 都是「未生成」。
- **用户点一张蓝 tile 里的「添加」，真的设成了锁屏，主屏幕现在就是深蓝色**——
  写入 → 画廊列出 → 添加 → 设为锁屏，端到端全通。只剩视频描述符渲染失败这一个问题。

### 结论

1. **Cipher 的 CAML 逐项对照完成**（`ControlDescriptorData.swift` 80 个文件逐个解码，
   `/tmp/cipher`，1,815,321 字节）：26 个 CAKeyframeAnimation **全部是
   `calculationMode="discrete"`**，`contents` 动画都没有 keyTimes（全文件只有 2 个
   keyTimes 块，属于一个 position.y 动画）。我们的 `caml()` 用的是 `linear`
   （Placard 模板原样，第 462 行逐字一致）。
2. **linear 是核心差异**：`contents`（CGImage）序列动画用 linear 做插值是未定义行为，
   图层在关键帧之间显示空白；常驻动画（repeatCount inf）会一直盖住静态首帧。
   单帧（1 个值）没有插值，所以不受影响——精确解释「单帧能用、多帧不行」。
3. **但 linear 解释不了 Cipher 本身也是黑的**：它的动画全是 discrete、包完整
   （47/47 资源引用对得上）、根层还有浅灰 backgroundColor，却同样黑、同样无快照。
   所以还剩第二条线：快照服务在该环境下没渲染多帧描述符（PosterBoard 没真正重启/
   渲染队列没跑、权限、或复杂包超时），或 tile 与描述符的对应关系假设有误
   （画廊排序未知；按时间/ID 单调排序时黑的 3 张是混合，不是干净的视频/测试二分）。
4. 两个排除性核查：种子平均色是青绿色（r0.34/g0.49/b0.46），不是蓝色——蓝 tile 是真的
   蓝 JPEG 内容；Cipher 资源引用 47/47 全对得上，不是缺文件。
5. 机制：tile 素材就是快照（Placard `installedWallpapers` 的找图顺序为证）；
   黑 tile = 没有快照；点不动 = `.ca` 在 PosterBoard 进程里加载失败。
   修复重心在"让快照服务能成功渲染"，不是改画廊列出逻辑（列出已通，8 张全在）。

### 已做的代码改动（只改了 `BizhiGongfang/Inject/DescriptorBuilder.swift` 一个文件）

- **主修复**：`caml()` 第 464 行 `calculationMode="linear"` → `"discrete"`。
  不补 keyTimes（Cipher 的 contents 动画也没有；均匀分摊正好是 15fps）。
  零风险：最小测试只有 1 个值，discrete 与 linear 行为完全一样。
- **顺手笔误修正**：`makeDescriptorMetadata()` 第 332 行 `"#00000"` → `"#000000"`。
  明确不是黑 tile 的原因（最小测试同样有它且能用），只是把非法颜色值修掉。
- 已验证：括号平衡 0:0:0；文件里不再有 `linear`。未动 `ControlDescriptor.swift`，
  未编译（无 Mac）。

### 修复方案（按可能性排序，见报告第九节）

1. 先验证 discrete 修复：编一版（含上面两处改动），做变身壁纸写入 → respring →
   划掉 PosterBoard → 看第 7 步快照 + 画廊 tile。快照生成/显示照片 = 修好了。
2. v17 权限对照 + PosterBoard 重启确认（已备好）。
3. 向 Cipher 对齐 index.xml（documentResizesToView false、loopingEnabled true、
   loopEnd +infinity）、补 Foreground 空包、appearanceAware 改 false、删 contentVersion
   ——打包做一次验证，单项都不是区分因素。
4. 尺寸实验（若判别实验指向尺寸）：改回 1080×1920，或全套改点尺寸 390×844 + iPhone 类。
5. 终极环境对照：Placard/Camlo 同机装一次 Cipher。

### 判别实验（见报告第十节）：单帧真照片

- 新增 `buildSinglePhotoDescriptor`（复用 `buildMinimalDescriptor` 的完整路径，
  只把一帧换成真照片）+ 诊断页按钮「写入单帧照片测试」。
- 两个探针：A = 单帧真照片 1080×1920（与最小测试只差帧内容）；B = 单帧真照片
  886×1920（与视频只差帧数）。写完 respring → 划掉 PosterBoard → 看画廊 + 第 7 步快照。
- 解读：A 照片 + B 照片 = 问题就是多帧动画；A 照片 + B 黑 = 尺寸问题；A、B 都黑 =
  不在动画，在照片内容或环境；A、B 都蓝 = 渲染服务本身有问题。
  新 tile 自带照片身份，写完后看它排第几位、总数变几张，还能反推画廊排序、
  确认黑的 3 张到底是不是视频。

---

## 构建 #19 准备（2026-11-20，本地已改好，待上传）

背景：构建 #18 的 discrete 修复已实测失败——新变身壁纸 11-20 17:06（v18 discrete
CAML）快照仍是「未生成」，画廊里还是没有照片 tile。linear→discrete 不是（唯一的）原因。
v17 的文件权限对照已实测：我们写的描述符文件夹全是「所有者 mobile；权限 755；
扩展属性：无」；苹果自带的 4 张是「所有者 mobile；权限 777；扩展属性：
com.apple.metadata:com_apple_backup_excludeItem」。所有者一样，权限和扩展属性不一样。
快照文件要写进描述符文件夹里（versions/<n>/RuntimeSnapshot-lock.atx），如果快照服务
不是以 mobile 身份写，755 就写不进去——这是目前最具体的可修差异。
删除问题仍是修好的（计数 14→16，一张没少）。

### 改了什么（5 个文件，只做下面两件事）

**1. 写后改权限（`PosterBoardStore.swift`）**

- 新增 `fixPermissionsRecursively(at:)`：递归把描述符文件夹内所有目录设为 0777、
  所有文件设为 0644。根目录本身也改。符号链接跳过（不跟过去改目标，避免改到
  文件夹外面）。隐藏文件也改（点号开头的 configurableOptions 不跳过）。
  不抛错：失败只记 NSLog，绝不把一次已成功的写入变成失败。不碰扩展属性
  （不复制苹果那个 backup_excludeItem，只改权限位）。
- 调用点两处（都在持有的读写权有效期内）：
  - `writeDescriptors`：每个描述符文件夹 copyItem 到主容器后立即改权限；
  - `mirrorDescriptors`：每个镜像 copyItem 后也改权限。
- 所有写入路径（真壁纸、空白测试、对照、单帧探针）都走 `writeDescriptors` 这一处，
  所以一次改动全覆盖。

**2. 单帧真照片判别实验（报告 4 第十节）**

- `DescriptorBuilder.swift`：
  - 新增 `buildSinglePhotoDescriptor(image: UIImage, size: CGSize, in workspace:)`；
  - `buildMinimalDescriptor` 的公共部分抽成 `buildSingleFrameDescriptor(jpeg:size:in:)`
    （最小测试 + 单帧照片共用：同一 `makeDescriptorMetadata`、同一 `caml()`、
    同一 `indexXML`、同一 `blankCAML`、同一 `floatingIndexXML`、
    同一 `seedDescriptorFiles`），只把一帧换成给定的真照片；
  - 新增 `aspectFillJPEG(image:size:)`：aspect-fill 居中裁剪，JPEG 0.7，
    用 `UIImage.draw(in:)`（方向正确，见倒置修复）；渲染格式 scale 固定为 1，
    输出像素尺寸就是 size 本身（探针 B 必须是正好 886×1920，不能是屏幕倍率）。
- `InjectSupport.swift`（`InjectFlow`）：
  - 新增 `injectSinglePhoto(image:)`：用同一张照片写两个描述符——探针 A
    （1080×1920，与最小测试只差帧内容）和探针 B（886×1920，与视频只差帧数），
    返回两个 poster UUID（顺序：A、B）。走和正常注入完全相同的
    `writeDescriptors` 路径（同样享受写后改权限 + 镜像 + 清缓存 + 写偏好）。
  - 新增 UserDefaults 键 `singlePhotoProbeAKey` / `singlePhotoProbeBKey`
    （`BizhiGongfang.singlePhotoProbeA` / `...ProbeB`），供编辑器和诊断页共用。
- `MorphEditorView.swift`：`exportSection` 里「一键写入锁屏」旁边加按钮
  「静态写入（单帧照片）」，用编辑器里当前的第一张照片（变身 A 图）调用
  `injectSinglePhoto`；成功后弹提示，让用户去画廊看两个新 tile；
  UUID 记进 UserDefaults。不经过"我的壁纸"记录。
- `InjectDiagnosticsView.swift`：
  - 第 7 步核对里把两个探针也列出来（主容器：还在/已消失；
    镜像容器：还在/已消失；快照：已生成/未生成），和对照测试同一套显示；
  - 新增「单帧照片探针」区：显示两个探针的编号 + 「删除两个单帧照片探针」
    按钮（复用 `deleteDescriptor`，主容器 + 镜像一起清；某个探针已经不在
    磁盘上了也算删干净；删完清除 UserDefaults 记录）；
  - 「文件权限对照」区里探针按名字显示（不再是"其他（UUID 前 8 位）"），
    方便确认新写的探针文件夹是不是 777。

### 没动的东西

- 没动 `ControlDescriptor.swift`、没动 CAML 模板、没动 gallery-index 相关代码。
- 没动 `buildMinimalDescriptor` 的行为（只是把公共部分抽成 helper，步骤和顺序完全一样）。
- 没编译、没打包、没上传。

### 验证

- 5 个改过的文件括号平衡全是 0:0:0。
- 关键标记 grep 通过：`fixPermissionsRecursively` ×3（定义 + 主容器 + 镜像）、
  `0o777`/`0o644`、`buildSinglePhotoDescriptor`（定义 + 2 次调用）、
  `injectSinglePhoto`、`静态写入`、`deleteProbes`、探针 UserDefaults 键
  （InjectFlow ×2、MorphEditorView ×2、诊断页 ×4）。

### 上传清单（构建 #19，5 个文件）

1. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
2. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
3. `BizhiGongfang/Inject/InjectSupport.swift`（替换）
4. `BizhiGongfang/Views/MorphEditorView.swift`（替换）
5. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）

### 测试顺序

1. 装上先跑诊断，看「文件权限对照」：确认新写的测试描述符文件夹是 777（文件 644）。
2. 做一张变身壁纸，一键写入（这次带改权限），注销桌面，划掉 PosterBoard，
   再跑诊断看第 7 步：变身壁纸的快照变「已生成」了没有；画廊里有没有照片 tile。
3. 在变身编辑器里点「静态写入（单帧照片）」写两个探针 → 注销 → 划掉 PosterBoard
   → 去画廊「iPhone 13 Pro」区看两个新 tile + 跑诊断看第 7 步两个探针的快照。
4. 探针用完可以在诊断页「单帧照片探针」区删掉。

### 结果解读

- 变身视频的快照生成了 / 画廊出现照片 tile = **改权限修好了**（755 是问题）。
- 探针 A 是照片 tile、能点、快照已生成；B 也是照片 tile = 静态真照片能渲染，
  尺寸没问题，**问题就是多帧动画**（discrete 已修但仍黑，说明动画之外还有因素，
  见下一点）。
- A 是照片 tile；B 是黑的、点不动、快照未生成 = 动画没问题，**尺寸 886×1920 有问题**
  → 把输出尺寸改回 1080×1920（或全套改点尺寸 390×844 + iPhone 类）再测。
- A、B 都黑、点不动、快照未生成 = 连单帧真照片都不渲染，**问题不在动画**，
  在照片内容（JPEG 编码/EXIF/色彩空间）或环境（快照服务）→ 查权限对照；
  换一张图再试，区分"照片文件"还是"渲染服务"。
- A、B 都蓝 tile（纯蓝、无照片）= 静态内容没画出来，tile 只显示了底色，
  **渲染服务本身有问题**（环境）→ 重点查 PosterBoard 重启确认、权限对照、
  Placard 同机对照。
- 新 tile 出现后看它排第几位、总数变几张，能反推画廊排序规则，确认黑的 3 张
  到底是不是视频（报告 4 第六节可能 A）。

## 构建 #20 准备（2026-11-20，诊断加「容器内所有描述符对照」区）

### 背景

- 用户 18:11 CST 回答：那张动漫壁纸是 **iOS 26 时装的，现在升到 27.0.1 还能用**。
  结论：它的快照是在 iOS 26 生成的、一直活着；27.0.1 上新写的多帧描述符
  （我们/Camlo/原样 Cipher）都拿不到快照，单帧的却能渲——问题卡在 27.0.1
  上新写多帧描述符的渲染一步。
- 要对照的重点：那张能用的多帧描述符，和我们的到底差在哪。
  读它的描述符（此刻就在 PosterBoard 容器里）逐项对照，是最直接的办法。
- 注意：构建 #19 的 5 个文件尚未上传（见上一节）。下面这两个文件同时
  包含 #19 的改动，传它们就同时带上了 #19 在这两个文件里的内容。

### 改动清单（2 个文件替换，只读，不写 PosterBoard）

1. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
   - 新增 `DescriptorSummary`（uuid / name / identifier / logicalScreenClass /
     hasBackgroundPackage / hasFloatingPackage / hasForegroundPackage /
     frameCount / calculationMode / hasSnapshot / owner / permissions / xattrNames，
     读不到的字段为 nil）。
   - 新增 `allDescriptorSummaries(provider:)`：只读。拿一次读写权、一次遍历
     读完主容器里全部描述符：Wallpaper.plist 的名字/编号/屏幕类、.ca 包有无、
     Background .ca 里 assets/*.jpg 的帧数、main.caml 第一个 calculationMode、
     快照 RuntimeSnapshot-lock.atx 是否存在、文件夹权限和扩展属性
     （复用已有的 `descriptorFileAttributes` 同一套读法和 `extendedAttributeNames`）。
     拿不到读写权返回空数组；某个字段读不到记 nil，绝不抛错、不崩。
   - 新增私有 helper `summarizeDescriptor(uuid:destination:)`（按
     `<uuid>/versions/<n>/contents/<名字>.wallpaper/` 布局读，版本目录取最大的
     数字版本）和 `calculationMode(inCAMLAtPath:)`（读 main.caml 文本里第一个
     calculationMode 的值；真包里 26 个动画全是 discrete，取第一个就够代表）。
2. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）
   - 新增「容器内所有描述符对照」区：只读，有独立刷新按钮
     「查看容器内所有描述符对照」（不触发第 6 步的测试写入）；每行一个描述符，
     把上面这些字段一行写清；我们自己的描述符按名字显示（我的壁纸/本次测试/
     探针 A/B/对照测试），未知 UUID 只显示前 8 位。跑完一次完整诊断也会顺带刷新它。
   - 没动第 7 步、文件权限对照区、对照测试区、单帧照片探针区。

### 没动的东西

- 没动写入路径（`writeDescriptors`、`postWriteRefresh`）、没动 CAML 模板、
  没动 gallery-index 相关代码、没动 `ControlDescriptor.swift`。
- 只读：新方法只读 PosterBoard 里的文件，不写、不删任何东西。

### 验证

- 2 个改过的文件括号平衡全是 0:0:0。
- 关键标记 grep 通过：`allDescriptorSummaries`、`struct DescriptorSummary`、
  `summarizeDescriptor`、`calculationMode(inCAMLAtPath`、`容器内所有描述符对照`、
  `refreshDescriptorComparison`、`buildDescriptorLines`。

### 上传清单（构建 #20，2 个文件）

1. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
2. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）

> 这 2 个文件同时包含构建 #19 在它们里面的改动（写后改权限 777/644、
> 文件权限对照区、探针核对）。如果 #19 的 5 个文件还没传，传完这 2 个后
> 只需再传 #19 剩下的 3 个：`DescriptorBuilder.swift`、`InjectSupport.swift`、
> `Views/MorphEditorView.swift`。

### 测试顺序

1. 装上先跑诊断（「开始检查」），顺带看「容器内所有描述符对照」区。
2. 截图发我：那张动漫壁纸是哪一行（多帧 + 快照已生成的那行），跟我们的
   哪几项不一样。

### 结果解读

- 动漫壁纸那行「多帧 + 快照已生成」，我们的多帧行「快照：未生成」——
  逐项比名字/编号/屏幕类/包/帧数/动画模式/权限/扩展属性，差在哪一项，
  下一版就改哪一项。
- 如果动漫壁纸那行根本不在列表里，说明它不在主容器
  （可能在镜像容器或其他 provider 下），下一版把对照区扩展到镜像容器。
- 如果所有行都「快照：未生成」（包括单帧的），说明这次运行没拿到
  读写权或容器路径不对，先看第 3、4 步。

## 构建 #21 准备（2026-11-20，v19 实测后：改权限生效但仍不显示 + 单帧照片探针无变化）

### 背景（2026-11-20 19:40–19:54 CST，v19 实测）

- 改权限生效：新测试写入 69F538FC 权限是 777（之前 755），但重启后画廊
  仍没多出新 tile——权限位不是（唯一的）原因，排除。
- 13p 区多了几张蓝 tile：画廊认得到新写入的描述符，列表刷新是通的。
- 单帧照片探针 A（1080×1920）+ B（886×1920）都写进去了，画廊无变化
  （无照片 tile）——连单帧照片都不显示，动画、尺寸、权限全排除，
  问题在渲染/快照那一步本身。
- 探针和最小测试走完全相同的 buildSingleFrameDescriptor + writeDescriptors
  路径，只差帧内容（纯蓝 JPEG vs 真照片 JPEG），所以不是代码路径 bug。

### 改动（2 个文件）

1. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
   - 写后设备份排除 xattr（构建 #21）：`setBackupExclude`，用公开 API
     `URLResourceValues.isExcludedFromBackup = true`，设的就是苹果自带
     描述符文件夹上那个 `com.apple.metadata:com_apple_backup_excludeItem`。
     这是文件权限对照里剩下的**最后一个差别**（所有者都是 mobile，新写
     权限现在也是 777，只剩这个 xattr 没有）。不是伪造系统标记，失败只
     记日志，不阻塞写入。
2. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）
   - 新增「有快照的描述符」区（构建 #21）：只列快照已生成的，同一行格式。
     动漫壁纸应该在里面，一张截图就能看完，不用翻上面 19 行。如果它不
     在里面，说明它的快照也不在主容器里。
   - 抽出 `formatDescriptorLine` / `descriptorNameMap`，对照区和快照区共用。

### 上传清单（构建 #21，2 个文件）

1. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
2. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）

> 用 Codemagic 编（GitHub 排不到 macOS runner）。这两个文件已包含
> #19+#20 的全部改动，仓库里其余文件不动。

### 测试顺序

1. 装上先跑诊断（「开始检查」），再点「查看有快照的描述符」，截图发我。
2. 再写一张变身壁纸（一键写入），注销，看画廊 13p 区有没有照片 tile；
   没有的话点「静态写入（单帧照片）」再写一次探针，看有没有照片 tile。
3. 诊断「文件权限对照」里新写的应该显示「权限 777；扩展属性：
   com.apple.metadata:com_apple_backup_excludeItem」。

### 结果解读

- 新写有 xattr + 照片 tile 出现——xattr 就是原因，问题解决。
- 新写有 xattr 但还是没有照片 tile——xattr 也排除；快照区里只有动漫
  （和苹果自带的）有快照，说明 27.0.1 的渲染服务根本不处理新写入的
  描述符，下一版改走 AirCard 路线（配对文件 + LocalDevVPN）对照。
- 动漫壁纸不在快照区里——它的快照不在主容器，下一版把对照区扩展到
  镜像容器。

## 构建 #22 准备（2026-11-20，探针判别出结果：A 显示、B 黑屏——尺寸是问题）

### 证据（2026-11-20 19:57–19:59 CST，v19，iPhone 13 Pro iOS 27.0.1）

- 画廊「iPhone 13 Pro」区出现一张真照片 tile（女士人像，09:41）。
- 第 7 步核对：探针 A（1080×1920）和探针 B（886×1920）都在主容器，
  快照都是「未生成」——单帧 tile 不靠快照，直接拿帧图渲染。
- 用户确认：显示的那张是 A，B 直接黑屏。
- 结论：**1080×1920 渲染，886×1920 不渲染**。两者只差尺寸，走同一条
  写入路径。之前所有视频/变身都输出 886×1920（Placard 算法按设备
  native 1170×2532 算出来的），所以全黑。蓝测试和探针 A 都是
  1080×1920，所以能显示。
- 容器里现在已有 31 张描述符（19:40 时 19 张）。

### 改动（3 个文件，含 #21 的 2 个）

1. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
   - `devicePortraitOutputSize`：iPhone 分支改成固定返回 1080×1920，
     不再按 nativeBounds 算 886×1920。iPad 分支不动。
     视频/变身的抽帧、CAML、index.xml 都会跟着变成 1080×1920。
2. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换，#21 的改动）
   - 写后设备份排除 xattr（`setBackupExclude`，公开 API）。
3. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换，#21 的改动）
   - 新增「有快照的描述符」区，只列快照已生成的。

### 上传清单（构建 #22，3 个文件）

1. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
2. `BizhiGongfang/Inject/PosterBoardStore.swift`（替换）
3. `BizhiGongfang/Inject/InjectDiagnosticsView.swift`（替换）

> 用 Codemagic 编。仓库里其余文件不动。

### 测试顺序

1. 做一张新的变身壁纸，一键写入，注销，去画廊 13p 区看有没有照片 tile。
2. 点进那张 tile，能打开、能设为锁屏就是成功；再看解锁后有没有变身效果。
3. 诊断第 7 步核对新变身壁纸的快照状态，截给我。

### 结果解读

- 变身壁纸出现照片 tile 且能打开——尺寸就是病根，问题解决；之后
  可以做滑动变身 + 陀螺仪视差（第二阶段）。
- 还是黑 tile——尺寸不是（唯一的）原因；多帧动画本身可能还需要快照，
  下一版再看快照生成条件（或改走 AirCard 路线对照）。

## 构建 #23 准备（2026-11-20，#22 实测后：B 黑屏 + 变身不进画廊，打包修）

### 判别结果（21:40–21:59 CST，用户实测 + 读代码确认）

1. **B 黑屏，根因在图本身，不在照片**：交叉淡化拖滑块没变化，滑动
   切换有变化；但把 A 那张好照片也选进 B 槽，第二张 A 还是黑——
   证明不是 B 照片坏了，是软件画第二张图本身坏了。`morphDrawer` /
   `drawAspectFill` 对 A、B 完全对称（同一函数、同一参数），所以问题
   不在绘制逻辑，而在 PHPicker 拿回来的 UIImage 对象本身：可能是
   CIImage backing（`cgImage == nil`），`image.draw(in:)` 在 CGContext
   （视频像素缓冲、预览渲染）里画不出来，静默变黑；SwiftUI 缩略图
   能显示它。交叉淡化“没变化”只是同一根因的症状（B 画不出 → 一直
   显示 A），不是 alpha 路径单独的 bug。
2. **变身不进画廊，根因在写入路线**：13p 画廊里静态写入（单帧照片
   探针）出现了，变身 / 景深 / 视频三个导入都没出现。静态和视频走
   同一条 `writeDescriptors`（权限、镜像、清缓存、写偏好都一样），
   描述符结构也一样（同一套元数据 / CAML / index.xml / 种子文件），
   只差帧的来源：静态是 `aspectFillJPEG`（UIGraphicsImageRenderer +
   UIImage.draw 直接画），视频是 MOV → AVAssetReader 抽帧。所以
   变身和景深改走静态那条渲染路：直接按 drawer 一帧一帧画出来做
   描述符，不经过 MOV。视频壁纸源头就是一段视频，仍走 MOV 抽帧，
   这次不动。
3. 诊断对照（21:49 CST）：变身壁纸 11-20 21:32 在盘上（45 帧，
   discrete，777，有备份排除 xattr）——写入成功、没被删；“没写入”
   是画廊不显示。有快照的描述符一个都没有，连 iOS 26 装的动漫壁纸
   也没有——“没快照”是普遍现象，不能单独解释不显示。

### 改动（5 个文件）

1. `BizhiGongfang/LivePhoto/PhotoPicker.swift`（替换）
   - 新增 `UIImage.flattenedForDrawing()`：归一化成“一定能画”的图
     （保证有 cgImage、方向 .up）。CIImage backing 先用 CIContext
     烤成 CGImage，再把方向烤进像素。`loadPickedImage` 改调它
     （原来只调 `normalizedOrientation()`，对 CIImage 图无效）。
     变身 A/B、景深的选图都走这里，一次修好编辑器预览、视频、
     Live Photo、注入的 B 黑屏。
2. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
   - 新增 `buildDescriptorFromDrawer(frameCount:duration:outputSize:drawer:in:)`：
     直接按 drawer 一帧一帧画出来做描述符。每帧用
     UIGraphicsImageRenderer（scale 固定 1，和单帧探针的
     aspectFillJPEG 同一套）+ drawer 画出来存 JPEG（1080×1920），
     45 帧（3 秒 × 15fps），CAML / 元数据 / index.xml / 种子文件
     和原来完全相同。
   - 新增 `renderFrameJPEG(drawer:size:time:)`（私有的画帧 helper）。
   - `buildDescriptor`（MOV 抽帧那条）不动，视频壁纸继续用它。
3. `BizhiGongfang/Inject/InjectSupport.swift`（替换）
   - 新增 `InjectFlow.injectFromDrawer(drawer:duration:stillImageTime:videoURL:name:kind:still:stillJPEGData:store:)`：
     用 `buildDescriptorFromDrawer` 做描述符、写进去、记到“我的壁纸”。
     videoURL 是调用方先渲染好的 3 秒 MOV（供记录和详情页播放动态用）。
   - `injectVideo` 不动，视频壁纸继续用它。
4. `BizhiGongfang/Views/MorphEditorView.swift`（替换）
   - `injectToLockScreen` 改调 `injectFromDrawer`（MOV 仍渲染一份，
     供记录和详情页播放用）。
5. `BizhiGongfang/Views/DepthEditorView.swift`（替换）
   - 同上（stillImageTime 用中间帧 1.5 秒）。

### 上传清单（构建 #23，5 个文件）

1. `BizhiGongfang/LivePhoto/PhotoPicker.swift`（替换）
2. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
3. `BizhiGongfang/Inject/InjectSupport.swift`（替换）
4. `BizhiGongfang/Views/MorphEditorView.swift`（替换）
5. `BizhiGongfang/Views/DepthEditorView.swift`（替换）

> 用 Codemagic 编。仓库里其余文件不动。注意：传文件里面的内容，
> 不要拖文件夹；传到对应的文件夹里（不要传到仓库根目录）。

### 测试顺序

1. 做一张新的变身壁纸（A、B 随便选两张）：编辑器里拖滑块，B 那头
   应该显示出照片（不再黑）；点“播放变身效果”，应该能变。
2. 保存到相册，按住 Live Photo，播到 B 应该不再黑。
3. 一键写入，注销，去画廊 13p 区看有没有这张变身（照片 tile）。
4. 点进 tile 设为锁屏，锁屏上解锁时看变不变身。
5. 景深也做一张、写一张，同样看 13p 里有没有。

### 结果解读

- 编辑器 B 显示、Live Photo 不黑、13p 里有变身 tile、锁屏能变身
  ——两个问题都修好了；之后可以做滑动变身 + 陀螺仪视差（第二阶段）。
- B 显示了、Live Photo 不黑，但 13p 里还是没有变身——说明画廊
  不显示不是帧来源的问题，是帧数 / 快照的问题；下一版再查（对照
  测试 Cipher 在收藏里找不找得到是关键判据）。
- B 还是黑——归一化没覆盖到这张图的格式，把那张图的来源告诉我
  （是不是实况照片 / 人像模式 / 从微信保存的），再针对性修。

## 构建 #24 准备（2026-11-21，Camlo 对照：壁纸本身做错了 + 加 .tendies 导出）

用户 09:59 说“算了，不搞了”，14:49 又回来了：看了 Camlo，Camlo 能写，
我们应该也没问题，是壁纸本身出错了；随后发来 Camlo_v1.3.0_Bilingual.ipa。
拆包对照（报告见 ~/workspace/camlo-research/CAMLO_ANALYSIS.md）确认三处做错：

1. **模板错了**：我们用 iPad 类（810w-1080h@2x~ipad）+ 2 个 .ca 包；
   Camlo 用 iPhone 类（390w-844h@3x~iphone）+ 3 个包
   （Background / Floating / Foreground）。
2. **变身写法错了**：我们是 45 帧视频（CAKeyframeAnimation 逐帧切）；
   Camlo 是 2 态滑动解锁（锁屏一张图、解锁一张图，LKState 切换）。
   画廊能列出 2 态的，列不出 45 帧的——对上“静态能显示、视频的不行”。
3. **种子文件不全**：Camlo 的 PosterSeed.bundle 有 9 个文件（含
   suggestionMetadata 注册画廊建议、RuntimeSnapshotMetadata 快照颜色统计），
   我们只有 7 个。suggestionMetadata 仍不补（它含苹果 7400 模板值，
   写错比不写更糟，Camlo 自己都会在冲突时删掉它；见 seedDescriptorFiles 注释）。

### 改动（壁纸本身）

- `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
  - 模板常量改 iPhone 类：`9183.Custom-390w-844h@3x~iphone.wallpaper`，
    Background / Floating / Foreground 三个 .ca 包；标识仍用我们自己的 9183。
  - `makeDescriptorMetadata`：logicalScreenClass 改 `390w-844h@3x~iphone`，
    加 `foregroundAnimationFileName`。
  - `buildDescriptor` / `buildSingleFrameDescriptor` / `buildDescriptorFromDrawer`
    都新建 Foreground 包（空白 CAML + floatingIndexXML + assetManifest.caml）。
  - 新增 `buildTwoStateMorphDescriptor` + `renderTwoStateJPEGs` + `twoStateCAML`：
    2 态变身描述符。assets 里只有 lock.jpg（A）和 unlock.jpg（B）；
    Chip 里叠两层，crossfade 靠 CALayer2 不透明度 0→1，slide 靠两层平移；
    LKState 的 Locked / Unlock / Sleep 用 LKStateSetValue 定 CALayer2 的值，
    Locked→Unlock 与 Unlock→Locked 两组切换里放 0.6 秒过渡动画。
    写法照 Camlo 二进制里的 LKStateSetValue / LKStateTransitionElement 片段，
    不是 Placard 的空 <elements/>。
  - `seedDescriptorFiles` 改 4 个参数，Foreground 包也补 assetManifest.caml。
- `BizhiGongfang/Inject/InjectSupport.swift`（替换）
  - 新增 `InjectFlow.injectTwoStateMorph`：把 A、B 各渲染一张 1080×1920，
    写 2 态描述符；MOV 仍渲染一份供记录和详情页播放用。
- `BizhiGongfang/Views/MorphEditorView.swift`（替换）
  - `injectToLockScreen` 改调 `injectTwoStateMorph`（slide = mode == .slide），
    不再调 `injectFromDrawer`。MOV 和静态图仍照常渲染。

### 改动（.tendies 导出，2026-11-21 子代理实现）

- 新增 `BizhiGongfang/Export/TendiesExporter.swift`：纯 Swift 打 ZIP
  （stored，method 0，不引第三方库，不用 Compression 框架），把描述符
  文件夹打成 `descriptors/<UUID>/` 结构的 .tendies；文件名 UTF-8
  （flag bit 11），CRC32 算对，目录项以 / 结尾，含隐藏文件
  （`.com.apple.posterkit.provider.contents.configurableOptions.plist`）
  和空目录。写完用 FileManager.unzipItem 自检一次（解出
  descriptors/<UUID>/ 且里面有 Wallpaper.plist 才算成功），否则抛错，
  不返回坏文件。ZIP 格式已在 Linux 上用逐字节复刻验证过 round-trip
  （python zipfile / unzip -t 均通过，CRC 全对，解出树与原树一致）。
  入口：`exportDescriptor`（主入口，打包已有描述符文件夹）、
  `exportTwoStateMorph`（A、B → 2 态描述符 → .tendies）、
  `exportSinglePhoto`（单张照片 → 静态 .tendies，1080×1920）、
  `exportFromDrawer`（景深 drawer 逐帧 → .tendies）、
  `exportVideo`（MOV → 45 帧描述符 → .tendies，async）。
  文件名清理掉 / \ : * ? " < > | 和控制字符（默认名里的冒号变“-”）。
- Morph / Depth / Video 三个编辑器各加“导出 .tendies”按钮（放在
  “一键写入锁屏”下面，bordered 样式，导出时显示 ProgressView，
  完成后弹系统分享面板 ShareSheet；失败走现有 alertMessage/showAlert）：
  变身调 exportTwoStateMorph（2 态描述符），景深调 exportFromDrawer
  （和 injectFromDrawer 同一套 drawer、45 帧、1080×1920），视频先
  VideoCropper 裁 3 秒再调 exportVideo。导出不依赖直写可用性
  （不用 App Group，不走 worse_query），iOS 太老或被封堵也能导出。
- 记录页详情（`WallpaperDetailView`）加“导出 .tendies”按钮：
  视频/景深记录用存的 MOV 调 exportVideo 重建描述符再打包；
  变身记录没有原图 B（只存了静态图和 MOV），用静态图调
  exportSinglePhoto 降级导出，按钮文案写明“导出 .tendies（静态版）”，
  下面有脚注说明。
- 导出 → 用 Camlo“导入外部 .tendies 壁纸包”安装（Camlo 已证实能装）。
  project.yml 不用改（sources 是 BizhiGongfang 目录通配，新文件自动包含）。

### 上传清单（构建 #24）

1. `BizhiGongfang/Inject/DescriptorBuilder.swift`（替换）
2. `BizhiGongfang/Inject/InjectSupport.swift`（替换）
3. `BizhiGongfang/Views/MorphEditorView.swift`（替换）
4. `BizhiGongfang/Export/TendiesExporter.swift`（新建）
5. `BizhiGongfang/Views/DepthEditorView.swift`（替换）
6. `BizhiGongfang/Views/VideoEditorView.swift`（替换）
7. `BizhiGongfang/Views/WallpaperDetailView.swift`（替换）

> 用 GitHub Actions 编（和 #23 一样）。仓库里其余文件不动。
> 注意：传文件里面的内容，不要拖文件夹；传到对应的文件夹里。

### 测试顺序

1. 做一张新的变身壁纸：一键写入，注销，去画廊 13p 区看有没有这张变身。
2. 点进 tile 设为锁屏，锁屏上滑解锁时看 A→B 变不变（crossfade 淡入 / slide 平移）。
3. 导出 .tendies：编辑器里点“导出 .tendies”，分享给 Camlo，用 Camlo
   “导入外部 .tendies 壁纸包”安装，再看画廊里有没有。
4. 景深、视频仍走老路（多帧），先只看变身；单帧照片不受影响。

### 结果解读

- 13p 里有变身 tile、锁屏解锁能变身——壁纸本身修好了。
- 13p 里还是没有，但 Camlo 导入的 .tendies 有——说明问题在直写路径，
  不在描述符；之后走 .tendies + Camlo 这条路。
- 13p 和 Camlo 导入都没有——2 态 CAML 的写法还有问题，把 Camlo 写好的
  “冰岛·黑沙玄光”描述符读出来对照（诊断页能列容器内描述符）。

## 构建 #24 修复（2026-11-21，第一次编失败，exit code 65）

运行 #2（提交 00373de，15:16）失败，只错 TendiesExporter.swift 一个文件，
4 处编译错误：

1. `FileManager.unzipItem` 不存在——工作流用的 Xcode 16.4 SDK 里没有这个 API。
   改：自检不再解压，改成直接读 ZIP 中央目录，确认里面有
   `descriptors/<UUID>/…/Wallpaper.plist`。注意 EOCD 里中央目录的起始偏移
   在偏移 16（偏移 12 是中央目录字节数），第一次写错成 12 已改回。
2. `dosDateTime` 里一行表达式太复杂，编译器类型检查超时。
   改：小时/分钟/秒三段分开算再拼。
3. 两处 `withUnsafeBytes` 解析到实例方法。改：写成 `Swift.withUnsafeBytes`。

只改这一个文件，传上去替换 `BizhiGongfang/Export/TendiesExporter.swift`，
再编一次。其他文件不用动。

## 构建 #25（2026-11-21，删 + 加 Camlo 功能）

### 先删掉的 3 样（用户 16:03 确认，只删这些）

1. **交叉淡化**：变身只留滑动。MorphEditorView 的 Mode 枚举、模式选择器删掉；
   morphDrawer 只画滑动；DescriptorBuilder.buildTwoStateMorphDescriptor 和
   twoStateCAML 的 slide 参数删掉，CAML 里 CALayer2 固定走 position.x 滑动；
   InjectSupport.injectTwoStateMorph 和 TendiesExporter.exportTwoStateMorph
   的 slide 参数也删掉。
2. **导出 Live Photo**：删 `BizhiGongfang/LivePhoto/LivePhotoExporter.swift`
   整个文件；三个编辑器的“导出 Live Photo 到相册”按钮 + exportLivePhoto()
   + isExporting 状态删掉；WallpaperDetailView 的“保存到相册”“分享”按钮
   + saveToPhotos() + isSaving 删掉，底部“去照片设 Live Photo 为墙纸”说明
   删掉；project.yml 的 NSPhotoLibraryAddUsageDescription 删掉。
   （LivePhotoMetadata 还在——injectToLockScreen 还用它的 jpegData；
   VideoRenderer.renderVideo 还在——inject 还用它。）
3. **静态写入探针**：MorphEditorView 的“静态写入（单帧照片）”按钮 +
   injectSinglePhotoProbe() + isWritingStatic 删掉。
   （InjectFlow.injectSinglePhoto 没删——诊断页第 7 步还在用它。）

### 一键写入锁屏保留（用户 16:28 纠正两次）

“静态写入”指的是上面第 3 项的探针按钮，不是直写本身。一键写入锁屏是
核心功能，必须保留。中间一度误删了整个注入系统（15 个文件），已从构建
#24 的 zip 完整恢复：Inject/（PosterBoardStore、worse_query、InjectSupport、
InjectFlow、InjectButton、InjectDiagnosticsView、ControlDescriptor、
NeoSpring、entitlements、Bridging Header）全部回来，三个编辑器的
injectToLockScreen 都在。

### 新加的 Camlo 功能（用户选“一起加上”，16:27）

1. **变身动画曲线**（3 条，不要丝滑叠化——那就是交叉淡化，已删）：
   - 上滑揭幕（默认）：B 从底部向上滑入（position.y 2880→960，0.6 秒）。
   - 破屏觉醒：B 从小放大 + 淡入（transform.scale 0.6→1 + opacity 0→1，0.8 秒）。
   - 圣光瞬变：B 瞬间出现（opacity 0→1，0.15 秒 linear）。
   - DescriptorBuilder 新增公开枚举 MorphCurve（CaseIterable），
     buildTwoStateMorphDescriptor / twoStateCAML / injectTwoStateMorph /
     exportTwoStateMorph 都接受 curve 参数（默认 revealUp）。
     MorphEditorView 加曲线分段选择器，预览 morphDrawer 按曲线画。
2. **AI 主体抠图**：新建 `BizhiGongfang/LivePhoto/ForegroundCutout.swift`
   （Vision VNGenerateForegroundInstanceMaskRequest 生成 mask，
   CIBlendWithAlphaMask 合成带透明的抠图，找不到主体返回 nil 跳过）。
   MorphEditorView 加开关（默认开）；开启时抠图写进 Floating.ca 的
   assets/foreground.png，并在 Floating.ca 写一个显示它的图层
   （floatingCAML，盖在时钟前面）。
3. **昼夜双生**：MorphEditorView 加开关，开启后多一组夜间 A/B 照片选择。
   夜图成对时写一套 Dark 变体包（9183.Custom_Dark_*），Wallpaper.plist
   的 lockAndHome 加 "dark" 入口（appearanceAware 本来就是 true）。
4. **熄屏常显图**：MorphEditorView 加可选的常显图选择，选中后写进
   `versions/1/contents/alwaysOn.jpg`（没往 otherMetadata 里记——种子
   otherMetadata 是 NSKeyedArchiver 归档，加顶层键会写坏）。
5. **裁剪**：新建 `BizhiGongfang/Views/CropView.swift`（9:16 框，拖动 +
   双指缩放，确定后裁出 1080×1920）。照片 A/B、夜间、常显 5 个槽位
   都能点“裁剪”进裁剪页。
6. **导入 .tendies + 壁纸金库**：
   - 新建 `BizhiGongfang/Export/TendiesImporter.swift`（纯 Swift 手写 ZIP
     解压，stored + deflate 都支持，自己写的 inflate，Python 验证过；
     security-scoped URL 处理；校验：不是 ZIP / 没有 descriptors/ /
     没有 Wallpaper.plist 都抛中文错）。
   - 新建 `BizhiGongfang/Models/VaultStore.swift`（金库在 Documents/Vault/
     <包 UUID>/，元数据 Documents/vault.json；add / delete / 分享用
     TendiesExporter.exportDescriptor 重新打包）。
   - 新建 `BizhiGongfang/Views/VaultView.swift`（列表：缩略图 + 名字 +
     帧数 + 导入日期，左滑删除；详情：大图 + “分享 .tendies” + 删除；
     “导入”按钮用 .fileImporter 选 .tendies / .zip）。
   - ContentView 加第三个 Tab“金库”（archivebox 图标）。MakeView 没动。
   - 只做“存进金库 + 再导出分享”，不做直写安装，不改 identifier。

### 没加的

- Camlo 内置预设画廊：没有现成图片可复制，不加。
- 夜间 Floating 抠图：抠图只按白天 A 图算，深色模式下时钟遮挡效果会消失
  （已知，待真机验证后再看）。

### 未在真机验证的点

- `awaken` 用的 transform.scale keyPath 是标准 Core Animation 写法，
  但没验证过 PosterBoard 是否认。
- TendiesImporter 的 inflate 是纯 Swift 逐位解码，几 MB 的包导入要 1–3 秒。
- ZIP64 不支持（>4GB 的包会报错，实际壁纸包只有 1–2MB）。

### 上传清单（构建 #25）

仓库里原来就有的文件，传上去替换（整文件替换）：

1. `BizhiGongfang/Inject/DescriptorBuilder.swift`
2. `BizhiGongfang/Inject/InjectSupport.swift`
3. `BizhiGongfang/Export/TendiesExporter.swift`
4. `BizhiGongfang/Views/MorphEditorView.swift`
5. `BizhiGongfang/Views/DepthEditorView.swift`
6. `BizhiGongfang/Views/VideoEditorView.swift`
7. `BizhiGongfang/Views/WallpaperDetailView.swift`
8. `BizhiGongfang/ContentView.swift`
9. `project.yml`

新建文件（Add file → Create new file，传到对应文件夹）：

10. `BizhiGongfang/LivePhoto/ForegroundCutout.swift`
11. `BizhiGongfang/Views/CropView.swift`
12. `BizhiGongfang/Export/TendiesImporter.swift`
13. `BizhiGongfang/Models/VaultStore.swift`
14. `BizhiGongfang/Views/VaultView.swift`

删除的文件（仓库里有，删掉）：

15. `BizhiGongfang/LivePhoto/LivePhotoExporter.swift`

> 其余文件不动。注意：传文件里面的内容，不要拖文件夹；传到对应的文件夹里。
> 传完去 Actions 看构建结果。

### 测试顺序

1. 编一张变身壁纸：选 A/B 两张图，三个曲线各试一次，一键写入，注销，
   去画廊 13p 区看有没有变身 tile，点进设为锁屏，上滑解锁看 A→B 变不变。
2. AI 抠图开关开/关各试一次：开的时候主体有没有破框遮住时钟。
3. 昼夜双生：开开关，选夜间 A/B，写入后切深色模式看换不换图。
4. 熄屏常显图：选一张常显图，写入（只看不报错）。
5. 裁剪：选图后点裁剪，拖动缩放，确定后看图有没有按框裁。
6. 导入 .tendies：把之前导出的 .tendies 用文件 App 打开，选“拷贝到壁纸工坊”
   或在金库里点导入，看金库列表里有没有；点进详情分享 .tendies。
7. 景深、视频：只剩一键写入 + 导出 .tendies，确认两个按钮都在。
