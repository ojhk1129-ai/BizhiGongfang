# 壁纸工坊「一键直写锁屏」注入调研报告

> 调研日期：2026-11-20；目标：像 Camlo / Placard 那样，把做好的壁纸直接写进系统锁屏画廊，不经过相册。
> 结论先说：**在 iOS 27.0.1 上可行，包括在 LiveContainer 里运行也可行（但有坑要绕）**；27.3 beta 2 起苹果已封堵，升级后直写永久失效，只能导出 .tendies。
> 本文档只做调研，不改任何 App 源码。

---

## 1. 结论

| 问题 | 答案 |
|---|---|
| 27.0.1 上能不能直写 | **能**。worse_query 在 26.0–26.7.2、27.0–27.2.1、27.3 beta 1 都可用；WQFiles 明确写了在 27.0.1 上测试通过 |
| LiveContainer 里能不能直写 | **能，但要多做一步**：LiveContainer 给客 App 的 App Group 路径是"替身"，token 对应的是真实路径；WQFiles 0.9.16 已解决同一问题，有现成解法 |
| 27.3 beta 2 及以上 | **不能**。苹果在 27.3 beta 2（build 24C5049d）封堵了 worse_query；只能导出 .tendies 包 |
| 工作量 | 中等：核心逃逸 + 定位 + 写入约 1–2 天；描述符生成约 1 天；UI、导出、测试打磨约 1–2 天；总计约一周业余开发量（不含真机调试往返） |
| 最大风险 | 用户升级到 27.3 beta 2+ 后功能永久失效；以及 GPL 许可证问题（见第 8 节） |

---

## 2. 直写原理：worse_query 沙盒逃逸

### 2.1 一句话原理

PosterBoard（锁屏管理进程）只是一个普通 App，它的数据容器在 `/var/mobile/Containers/Data/Application/<UUID>`。正常 App 被沙盒挡住、读不到别的 App 的容器。worse_query 利用 `containermanagerd`（容器管理守护进程）的一个校验缺失：**让它给一个"被符号链接调包过的"目录签发沙盒扩展（sandbox extension），内核认这个 token，于是进程就获得了目标容器的读写权**。没有内核漏洞，不越狱，不是传统意义上的 exploit。

### 2.2 前置条件

- App 必须带至少一个 `com.apple.security.application-groups`（App Group）entitlement。
  - SideStore / AltStore / Impactor 签名时会自动加一个；**Sideloadly 不加**，用它签的包会报 "No App Group"。
  - 这是整个功能唯一的签名要求；没有 App Group 就只能做壁纸、导出 .tendies，不能直写（Camlo 也是这个逻辑）。

### 2.3 具体步骤（worse_query，forcequitOS，GPL-3.0）

源码：`forcequitOS/worse_query`（`worse_query.m` / `worse_query.h`），Placard 直接内置了同一份代码（`placard/Exploit/worse_query.m`）。

1. `containerURLForSecurityApplicationGroupIdentifier:` 拿到自己 App Group 容器的路径。
2. 把 `<group>/Library/Caches` 移走备份（改名成 `.placard-cache-<UUID>`），在原位置创建一个**符号链接**，指向目标路径（例如 PosterBoard 容器）。
3. `dlopen("/usr/lib/system/libsystem_containermanager.dylib")`，用 `dlsym` 取出私有函数：
   `container_query_create`、`container_query_set_class`、`container_query_set_group_identifiers`、`container_query_operation_set_part`、`container_query_operation_set_flags`、`container_query_get_single_result`、`container_query_free`、`container_copy_sandbox_token`；再从 `libsystem_sandbox` 取 `sandbox_extension_consume` / `sandbox_extension_release`。
4. 发起查询：
   - class **7**（appGroup）
   - group identifier = 自己的 App Group
   - part **3**（即 `Library/Caches`）
   - flags `0x8000000000`（iOS 26.x 用另一组 flags `0x0800000000`，即 `alt_flags`）
   - **不传 partDomain**（这是和旧版 bad_query 的关键区别，见 2.4）
5. `containermanagerd` 按文件系统解析 part 目录，看到符号链接就**对解析后的真实目标签发 token**（类型 `com.apple.app-sandbox.read-write`，通用读写类），而不检查目标还在不在容器内。
6. `sandbox_extension_consume(token)` 得到句柄（int64），进程内即可读写目标路径；用完 `sandbox_extension_release(handle)`。
7. 把原来的 `Library/Caches` 恢复（移回备份）；崩溃导致没恢复时，下次启动要做修复（WQFiles 有 `WQRecoverCacheSwapAtPath` 逻辑）。

### 2.4 bad_query 与 worse_query 的区别（版本史）

| | bad_query（旧） | worse_query（新） |
|---|---|---|
| 手段 | class 13 + `partDomain` 里写 `../../../../..` 做路径遍历 | class 7 + 把 part 目录本身换成符号链接；不传 partDomain |
| 修复版本 | **iOS 27.2 已修**：`MCMXPCMessageQuery` 拒绝含 `..` 的 partDomain | **iOS 27.3 beta 2 已修**（见第 5 节） |
| 备注 | Placard 早期用 bad_query，后来也换成了 worse_query | KAMUI（MIT 协议）用的是同一招，叫 class-7 symlink 策略 |

### 2.5 能到达的路径（worse_query README）

```
/var/containers/Data/System（仅 iOS 27）
/var/containers/Shared/SystemGroup/*（仅 iOS 27）
/var/mobile/Containers/Data/Application/*     ← PosterBoard 在这里
/var/mobile/Containers/Data/InternalDaemon/*
/var/mobile/Containers/Data/PluginKitPlugin/*
/var/mobile/Containers/Shared/AppGroup/*
/var/mobile/Containers/Shared/AppGroup（仅 iOS 27）
```

限制：到不了 App 本体（`/var/containers/Bundle/Application` 拒绝）、到不了钥匙串、父目录本身列不出来（只能逐个访问已知的子路径）。

---

## 3. 写到哪里：PosterBoard 容器与描述符

### 3.1 找到 PosterBoard 容器

- 容器根目录：`/var/mobile/Containers/Data/Application/<UUID>`，按 bundle ID `com.apple.PosterBoard` 识别。
- 定位方法（Placard 的 `WorseQuery.findPosterBoardHash()`）：
  1. 枚举 `/var/mobile/Containers/Data/Application`（另加 `InternalDaemon`、`PluginKitPlugin`）下的 UUID 目录；
  2. 每个目录读 `.com.apple.mobile_container_manager.metadata.plist`，取 `MCMMetadataIdentifier` 字段比对 bundle ID；
  3. 找到后把 UUID 缓存到 UserDefaults，下次先验证缓存（仍有效就直接用）。
- 注意：父目录本身**列不出来**（worse_query 返回 -6 拒绝），枚举要靠别的办法：Placard 用了一个 ObjC 辅助 `placard_visit_containers`；KAMUI / WQFiles 用 LaunchServices 数据库或 inode 扫描。实现时可直接抄这个思路（或复用 KAMUI 的枚举代码，MIT 协议）。

### 3.2 描述符存放位置

```
<PosterBoard容器>/Library/Application Support/PRBPosterExtensionDataStore/<版本号>/Extensions/<provider>/descriptors/
```

- `<版本号>` 是整数目录（如 `61`），取最大的、且其下有 `Extensions` 的那个。
- 三个 provider（按壁纸类型）：
  - `com.apple.WallpaperKit.CollectionsPoster` —— 动态 / 变身 / LayeredAnimation 壁纸（我们要写的主力）
  - `com.apple.MercuryPoster`
  - `com.apple.PhotosUIPrivate.PhotosPosterProvider` —— 视频 / 照片类壁纸
- 写入方式：把做好的描述符文件夹整个复制进去，文件夹名换成一个**全新的 UUID**（`.../descriptors/<新UUID>/`）。描述符内的 ID 也要重随机（见 4.4），否则两张壁纸会互相覆盖。

### 3.3 写入后让系统看到

- 写完要**注销 SpringBoard（respring）**或至少杀掉 PosterBoard 进程，否则画廊里看不到新壁纸。
  - Placard / AirCard 用开源组件 **NeoSpring**（neonmodder123、skadz108）一键 respring；
  - Camlo 的做法是弹窗提示"立即注销桌面生效"，或让用户去多任务划掉 PosterBoard；
  - 第一版可以先不做 NeoSpring，只提示用户"去多任务划掉 PosterBoard 再进锁屏画廊"，等验证通过再接 NeoSpring。
- 用户操作路径（和 Camlo 一致）：App 内点"一键写入锁屏" → 提示 respring → 锁屏长按 → 点右下角 `+` → 在"专为你的 iPhone 设计的墙纸"那一排找到新壁纸 → 添加。

---

## 4. .tendies 包格式（描述符结构）

`.tendies` 就是一个 ZIP，里面装的是 PosterBoard 描述符文件夹。我们的 App 其实**不需要经过 ZIP**：像 Placard 的视频壁纸那样，在本地直接生成描述符文件夹、直接写进去就行；ZIP 只在"导出分享"时才需要。

### 4.1 ZIP 的两种顶层形态（Placard `findDescriptorGroups` / Nugget 文档）

| 形态 | 顶层目录名 | 写入目标 |
|---|---|---|
| Container 格式 | `Container/Library/Application Support/PRBPosterExtensionDataStore/<版本>/Extensions/<provider>/descriptors/` | 直接按原结构恢复，**不随机 ID** |
| Descriptor 格式 | `descriptor` / `descriptors` / `ordered-descriptor(s)` | `com.apple.WallpaperKit.CollectionsPoster`，ID 随机化 |
| Descriptor 格式 | `video-descriptor` / `video-descriptors` | `com.apple.PhotosUIPrivate.PhotosPosterProvider`，ID 随机化 |

解压时要防 Zip-Slip：拒绝绝对路径、`..`、symlink 条目（Placard 有这套校验）。

### 4.2 一个视频壁纸描述符的完整结构（Placard `VideoWallpaper.swift`，已逐行核对）

```
<UUID>/                                                              # 描述符文件夹
├── com.apple.posterkit.provider.descriptor.identifier               # 纯文本：随机整数，如 48392
├── com.apple.posterkit.role.identifier                              # 纯文本："PRPosterRoleLockScreen"
├── providerInfo.plist                                               # NSKeyedArchiver：{"kConfigurationLastUseDateKey": Date()}
└── versions/
    └── 1/
        └── contents/
            ├── com.apple.posterkit.provider.contents.userInfo       # binary plist：
            │                                                        # { posterEnvironmentOverrides: Data("{}"),
            │                                                        #   wallpaperRepresentingFileName: "<名字>.wallpaper",
            │                                                        #   wallpaperRepresentingIdentifier: <整数> }
            └── 9183.Custom-810w-1080h@2x~ipad.wallpaper/           # 目录（名字即 wallpaper 文件名）
                ├── Wallpaper.plist                                  # binary plist（见 4.3）
                ├── 9183.Custom_Background-810w-1080h@2x~ipad.ca/   # 背景动画包（目录）
                │   ├── main.caml
                │   ├── index.xml
                │   └── assets/
                │       ├── 0.jpg、1.jpg、2.jpg …                   # 视频抽出的帧
                └── 9183.Custom_Floating-810w-1080h@2x~ipad.ca/     # 前景包（空动画）
                    ├── main.caml
                    └── index.xml
```

### 4.3 Wallpaper.plist 关键字段

```plist
appearanceAware: true
assets:
  lockAndHome:
    default:
      backgroundAnimationFileName: "9183.Custom_Background-810w-1080h@2x~ipad.ca"
      floatingAnimationFileNameKey: "9183.Custom_Floating-810w-1080h@2x~ipad.ca"
      identifier: 9183
      name: "Chip"
      type: "LayeredAnimation"
contentVersion: 2.01
family: "Chip"
identifier: <随机整数，和 4.4 的三处保持一致>
logicalScreenClass: "810w-1080h@2x~ipad"
name: "Chip"
preferredProminentColor: { dark: "#00000", default: "#FFFFFF" }
version: 1
```

### 4.4 main.caml（背景动画）要点

- 一个 `CALayer`，`contents` 是 `assets/0.jpg`，挂一个 `CAKeyframeAnimation`：
  - `keyPath="contents"`，`values` 为全部帧 `<CGImage src="assets/N.jpg"/>`
  - `duration` = 视频时长（秒），`repeatCount="inf"`，`autoreverses="0/1"`（乒乓往返为 1）
  - `calculationMode="linear"`，`beginTime="1e-100"`
- 必须带三态 `<states>`：`Locked` / `Unlock` / `Sleep`，以及六组 `<stateTransitions>`（`*↔Unlock`、`*↔Locked`、`*↔Sleep`）。
- 前景包用"空白 CAML"（一个 3176×3176 的空图层）；`index.xml` 是 Quartz Composer 文档元数据（`assetManifest.caml`、`documentWidth/Height`、`rootDocument = main.caml` 等），照抄 Placard 的模板即可。
- 真正的"上滑解锁变身"（两张图跟手渐变）是同一套 LayeredAnimation，但要在 `LKStateTransition` 里写跟手进度的插值动画——这是 Camlo 的核心生成器，Placard 的视频模板里没有；第一版先不做，第二阶段再研究 Camlo 的实现。

### 4.5 帧预算（别让壁纸黑屏）

- Placard 上限：视频 12 秒，帧率 10–60 fps；Camlo 建议 12/18/24 FPS、**最多 150 帧**，否则 PosterBoard 扩展会被 Jetsam 强杀，壁纸变黑或变静态。
- 我们的视频是 3 秒：15fps = 45 帧、30fps = 90 帧，都在安全区。抽帧时按目标帧率跳帧（Placard 的做法：`frameInterval = 1/输出帧率`）。
- 尺寸：按屏幕原生分辨率取长边（上限 1920），短边等比；帧存 JPEG（quality 0.7）。

### 4.6 ID 随机化（防冲突，三处同步）

安装前生成一个随机整数（Placard 用 10000–99999），同时写到三处：

1. `com.apple.posterkit.provider.descriptor.identifier` 文件内容
2. `com.apple.posterkit.provider.contents.userInfo` 里的 `wallpaperRepresentingIdentifier`
3. `Wallpaper.plist` 里的 `identifier`

描述符文件夹本身复制时也要换全新 UUID 文件夹名。

---

## 5. iOS 版本限制

| 版本 | 状态 |
|---|---|
| iOS 26.0 – 26.7.2 | 可用（26 上写不了 MobileGestalt，但 PosterBoard 写入没问题） |
| iOS 27.0 – 27.2.1 | 可用 |
| iOS 27.3 beta 1（24C5037i） | 可用（最后一个可用版本） |
| **iOS 27.3 beta 2（24C5049d）及以上** | **已封堵，worse_query 失效** |

- 证据：Camlo README（2026-11-17）"苹果已于 iOS 27.3 beta 2（24C5049d）封堵 worse_query 沙盒漏洞，免电脑直写最高仅支持至 27.3 beta 1"；WQFiles README 同样确认，并说启动检查会按 build 号识别。
- 27.3 beta 2 具体改了什么没有官方说明；按 KAMUI 作者给苹果的建议方向推测，是对 part 目录做了规范化校验、拒绝符号链接的 part 目录（即把 worse_query 的洞按 2.3 第 2 步堵上）。
- **用户当前是 iOS 27.0.1，在可用范围内**。要提醒用户：不要升级到 27.3 beta 2 或更高，并关闭自动更新，否则直写永久失效（届时只能导出 .tendies）。
- 另注意：旧版 bad_query 在 27.2 就已修掉，实现时必须用 worse_query（class 7 符号链接版），不要抄 bad_query 的 class 13 遍历版。

---

## 6. LiveContainer 里能不能用？（关键问题）

**结论：能用，但必须处理 LiveContainer 的"替身 App Group"问题；WQFiles 0.9.16 已经趟过这条路。**

### 6.1 坑：替身路径

- LiveContainer 给客 App 的 `containerURLForSecurityApplicationGroupIdentifier:` 返回的不是真实 group 路径，而是一个**替身**（stand-in），形如 `<真实group>/LiveContainer/Data/AppGroup/<id>`。
- 但 `containermanagerd` 签发的 token 对应的是**真实** group 路径。直接拿替身路径做符号链接替换，token 覆盖不到，访问会被拒绝。
- 实证：WQFiles #65——"inside LiveContainer every app folder was refused"，原因就是这个。

### 6.2 解法（WQFiles 的 `wq_group_root`，三级回退，`WQAccess.m`）

1. **优先：从 token 里读真实路径**——发一次"试探查询"（不 consume token），token 字符串的最后一个字段就是 `.../AppGroup/<UUID>/Library/Caches`，由此推导出真实 group 根目录。WQFiles 注释写明："Under LiveContainer this is the only reliable answer"。
2. 其次：用 `container_query_iterate_results_sync` + `container_object_get_path` 直接问 containermanagerd 要 class 7 容器的真实路径。
3. 最后：拿 NSFileManager 的路径，若形如 LiveContainer 替身则映射回真实 group（`WQGroupRootForPath`）。
4. 选 group 时优先选"NSFileManager 路径与 token 路径一致"的那个——LiveContainer 下通常是 LiveContainer 自己用的 group（它偏好 SideStore 的 group，而 entitlement 列表顺序可能先是 AltStore 的）。

### 6.3 另一个坑：多客 App 共享 group 的缓存冲突

- `Library/Caches` 的符号链接交换是 group 级共享状态；LiveContainer 里多个客 App 共用同一个 group 时，一个 App 崩溃或没恢复好，会把别的 App 的访问也搞坏（WQFiles 0.9.15 修过："when another app sharing WQ Files' App Group (for example in LiveContainer) left its access cache broken, every folder was refused"）。
- 实现时要有：备份恢复 + 启动时自动修复损坏的交换（`WQRecoverCacheSwapAtPath` 的思路）。

### 6.4 前提与退路

- 前提：LiveContainer 本身必须带 App Group entitlement（SideStore/AltStore 装 LiveContainer 时会自动加；如果 LiveContainer 是用不带 App Group 的方式签的，客 App 里完全没法用）。
- 重要：**客 App 自己的 entitlements 在 LiveContainer 里不起作用**，起作用的是宿主（LiveContainer）进程的签名。所以我们 App 自己的 App Group entitlement 只在"直接安装"时生效。
- 退路：如果 LiveContainer 里调不通，改用 SideStore/AltStore **直接安装**我们的 App（签名保留 App Group），走 Camlo 推荐的标准路径，流程完全一样。
- 反例参考：FilzaSlop 明确说 LiveContainer 模式"只能管理 LiveContainer 客 App 自己的数据，到不了正常 App 的容器"——但那是它的 MobileHouseArrest 机制的限制；worse_query + 上述修正是另一条路，WQFiles 已证明在 LiveContainer 里能到全部容器。

---

## 7. 给壁纸工坊的实施计划

### 7.1 复用现有代码

| 现有能力 | 怎么复用 |
|---|---|
| `VideoRenderer.renderVideo`（AVAssetWriter 逐帧画 H.264 MOV，1080×1920，30fps，3 秒） | 第一版注入直接用它产出的 MOV，再用 `AVAssetReader` 抽帧（Placard 同款做法，改动最小）。优化版可在渲染循环里直接存 JPEG，省一次编解码 |
| `MorphEditorView.exportLivePhoto` / `DepthEditorView` / `VideoEditorView` 的导出流程 | 在导出成功后加一步"写入锁屏"，或在导出区并排加"一键写入锁屏"按钮 |
| `LivePhotoMetadata` 的 still-image-time 经验 | 注入路径不需要 Live Photo 元数据（描述符用帧 + CAML，不用 MOV），可以跳过 |
| `WallpaperStore`（我的壁纸列表） | 注入成功后记录一条"已写入系统"的壁纸，方便之后提供"删除已注入壁纸" |

### 7.2 新增文件

```
BizhiGongfang/Inject/
├── WorseQuery.h / WorseQuery.m      # 逃逸核心：移植 forcequitOS/worse_query（GPL-3.0，见第 8 节）
│                                     # 或参考 KAMUI（MIT）自己实现同一逻辑
├── PosterBoardStore.swift           # Swift 封装：读 entitlements 找 App Group → LiveContainer
│                                     #   stand-in 修正（token 解析法）→ 枚举容器找 PosterBoard
│                                     #   → storeRoots / writeDescriptors / 已装列表 / 删除
├── DescriptorBuilder.swift          # 生成描述符文件夹：抽帧 → assets/*.jpg + main.caml +
│                                     #   index.xml + Wallpaper.plist + userInfo + 两个 identifier 文件
├── TendiesExporter.swift            # 把描述符文件夹打成标准 .tendies ZIP（Descriptor 格式），
│                                     #   供 27.3b2+ 用户导出，或导入 Camlo / Placard
├── Respring.swift                    # NeoSpring 集成；第一版可先只做"提示用户划掉 PosterBoard"
└── InjectViewModel.swift + UI        # 三个编辑器里加"一键写入锁屏"按钮、进度、失败提示、
                                      #   成功后引导去锁屏画廊
```

### 7.3 要改的现有配置

- `project.yml`：
  - 新建 `BizhiGongfang/BizhiGongfang.entitlements`，加 `com.apple.security.application-groups`，group id 如 `group.com.wallpaperstudio.app`；xcodegen 用 `entitlements:` 字段挂上去。
  - **deployment target 保持 iOS 17.0**（别提到 26.0，否则丢掉老系统用户）；注入功能运行时判断系统版本，26 以下只提供 Live Photo 导出。
  - ObjC 的 `.m` 文件已在 `BizhiGongfang` 源码目录内，会自动编进 target；需要加 bridging header（xcodegen：`SWIFT_OBJC_BRIDGING_HEADER`）。
- `Info.plist`：不需要新权限 key（注入不走公开 API）；`.tendies` 文件类型注册（UTType `com.leemin.tendies`，供"用壁纸工坊打开 .tendies"用）可选做。
- 依赖：ZIPFoundation（Placard 同款，Swift Package Manager 自动拉）用于 .tendies 解压/打包；NeoSpring 用于 respring。

### 7.4 分阶段做

1. **最小验证（先做，别直接集成）**：单独建一个最小测试 App，只做"读 group → 找 PosterBoard → 写一个空白描述符 → 锁屏画廊出现"，在用户真机 27.0.1 + LiveContainer 里跑通。这是整个功能最大的不确定点，先验证再集成。
2. **视频路径**：MOV 抽帧 → 描述符 → 写入 → respring 提示。三个编辑器（变身 / 景深 / 视频）第一版都走这条路：变身和景深就当 3 秒视频处理（循环播放）。
3. **导出 .tendies**：描述符文件夹打 ZIP；27.3b2+ 用户至少能导出，拿到 Camlo/Placard 里用。
4. **已装管理**：列出我们写入过的壁纸、删除；以及"仅清理我写入的壁纸"（Camlo 同款安全设计）。
5. **第二阶段（真正的上滑变身）**：研究 Camlo 的 LayeredAnimation + `LKStateTransition` 跟手插值生成器，做两张图随解锁进度渐变的 CAML；景深的陀螺仪视差对应 `ParameterizedCA`（`wantsDeviceMotion = true` + parallax groups）。这部分工作量和第一版相当，单独排期。

### 7.5 失败处理与安全设计

- 写入前检查：系统版本（27.3b2+ 直接提示只能导出）、App Group 是否存在（没有就提示改用 SideStore/AltStore 安装）、PosterBoard 容器是否找到。
- 每次写入前备份被覆盖的 `Library/Caches`，操作完恢复；崩溃后下次启动自动修复（抄 WQFiles 的恢复逻辑）。
- 只写我们自己的描述符；提供"清理我写入的壁纸"，不要提供"清空全部"（Placard 的 Reset 会删掉系统自带，危险）。
- 写入失败要把 worse_query 的返回码翻译成人话（Placard 的 `WorseQueryError.from`：-255 路径不存在、-1 无 App Group、-2 解析失败、-4 缓存不可用、-5 被拒绝、-6 内核拒绝 token）。

---

## 8. 许可证注意事项（重要）

| 来源 | 协议 | 影响 |
|---|---|---|
| forcequitOS/worse_query | GPL-3.0 | 直接复制代码 → 整个 App 必须 GPL-3.0 开源 |
| frs0n/placard | GPL-3.0 | 同上（VideoWallpaper / WorseQuery.swift 等） |
| Kianuni/Camlo | GPL-3.0 | 同上 |
| murk-sus/kamui-escape（逃逸引擎） | **MIT** | 可自由使用、修改、闭源商用，只需保留版权声明 |
| leminlimez/Pocket Poster、Nugget（.tendies 格式） | 格式本身是事实标准 | 照着格式自己写实现不构成复制；不要直接搬它们的代码 |

建议：**逃逸核心参考 KAMUI 的 MIT 实现自己写**（逻辑和 worse_query 相同，都是 class 7 符号链接那几步）；描述符/CAML 生成照着格式自己实现；只在必要时引用 GPL 代码——一旦引用，仓库就要挂 GPL-3.0 协议并开源。决定之前先和用户确认他是否接受把项目开源（GPL）。

---

## 9. 风险与未知（按严重程度）

1. **27.3 beta 2 已封堵**：用户一旦升级，直写永久失效；功能寿命取决于用户停留在 27.0.1–27.3 beta 1。必须在 App 里做版本检测和明确提示。
2. **LiveContainer 的 stand-in 坑**：不做 token 解析修正就一定失败；多客 App 共享 group 还有缓存冲突。要按第 6 节实现。
3. **注入失败可能损坏 PosterBoard 描述符**：写坏会导致壁纸黑屏或画廊异常；要有备份、清理入口和恢复指引。
4. **签名要求**：直接安装必须用保留 App Group 的签名工具（SideStore/AltStore 行，Sideloadly 不行）。
5. **帧预算 / Jetsam**：帧太多或分辨率太高会让锁屏壁纸黑屏；按 4.5 的上限控制。
6. **未验证**：27.0.1 上 class 7 路径是否一次成功（WQFiles 称在 27.0.1 测试通过；KAMUI 说 27.0.x 上 class-13 遍历也可能还有效，可做多策略回退）。
7. **苹果后续封堵**：27.3 beta 2 已证明苹果在主动修这个洞；未来版本可能进一步收紧。
8. **GPL 污染**（第 8 节）：抄代码前先定协议策略。

---

## 10. 参考来源

- forcequitOS/worse_query（README + worse_query.m/h）：https://github.com/forcequitOS/worse_query
- forcequitOS/bad_query：https://github.com/forcequitOS/bad_query
- frs0n/placard（README、placard/Exploit/WorseQuery.swift、worse_query.m、VideoWallpaper.swift、WallpaperInstaller.swift）：https://github.com/frs0n/placard
- Kianuni/Camlo（README、docs/FEATURES.md）：https://github.com/Kianuni/Camlo
- murk-sus/kamui-escape（README，MIT，class-7 symlink 详解与多策略回退）：https://github.com/murk-sus/kamui-escape
- kolbicz/WQFiles（README、WQAccess.m、WQAccessSafety.h；LiveContainer #65 的完整解法）：https://github.com/kolbicz/WQFiles
- leminlimez/Pocket-Poster .tendies 格式文档：https://deepwiki.com/leminlimez/Pocket-Poster/4.1-tendies-file-format
- GoldenNugget documentation（tendies 两种格式）：https://github.com/GoldenNugget-Team/GoldenNugget/blob/HEAD/documentation.md
- melv.in：worse_finder（机制讲解与实测）：https://www.melv.in/blog/worse-finder-every-app-container-on-ios-one-symlink-away/
- Ostorlab：worse_query 分析：https://blog.ostorlab.co/worse-query-ios-sandbox-escape.html
