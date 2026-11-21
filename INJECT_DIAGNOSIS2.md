# 排障报告 2：注入的描述符为什么被系统删掉

日期：2026-11-20（v14 构建 #14 实测后）
结论先行：**不是 gallery-index.json 没登记**——Placard 原版写路径也不登记它，gallery-index.json 只是快照缓存，PosterBoard 重启后自己从目录重建。真正的病根是两处：**(1) 我们的描述符是不完整的骨架，缺了真描述符里本来就有的几个文件，最要命的是每个 `.ca` 包里都缺 `assetManifest.caml`**（index.xml 里声明了它，文件却不存在，PosterKit 加载 .ca 包失败 → 描述符无法渲染 → 重启扫描时被当成坏描述符删掉）；**(2) 写完之后少了 Camlo / AirCard 都做的三个收尾动作：双写第二容器、清 GalleryCache、写 PosterBoard 持久化偏好**。1 帧空白测试描述符也被删，正好印证：问题不在视频帧数、帧内容、CAML 模板本身，而在所有描述符共用的骨架和写后流程。

## 一、最新证据（2026-11-20 15:19 CST，v14 实测）

- 视频壁纸「视频壁纸 11-20 15:14」一键写入成功，点了「立即注销桌面生效」——**respring 成功**（NeoSpring 在 LiveContainer 里生效），但画廊「收藏」里没有。
- 随后跑直写诊断：第 5 步「里面已有 4 张」（只剩最初 4 张苹果自带的）；第 6 步测试写入又成功（新测试描述符 04CC11AE-BC9E-4B42-8E4B-0ED502F233A7）；**第 7 步「已消失：视频壁纸 11-20 15:14」**。
- 计数：14:47 第 5 步 6 张（应为 8 张）→ 15:19 第 5 步 4 张。**所有我们写过的描述符都被系统删了**：两个测试描述符（DCB39882、5CBE7215）、三张真的（变身/景深/视频）、新的 15:14 视频那张，连 1 帧空白测试也活不下来。苹果自带的 4 张始终在。
- 已证伪的理论：缺 respring（respring 发生了，描述符反而被清掉）、视频描述符格式不对（1 帧空白描述符同样被删）、收藏位置找错（用户滑到底部看过）。

## 二、本地写路径确认（任务 1）

`BizhiGongfang/Inject/PosterBoardStore.swift`：

- `writeDescriptors`（约 289–311 行）：只做两件事——算 `descriptorDestination`（取版本号最大的、有 Extensions 的版本目录下 `Extensions/<provider>/descriptors`），然后 `copyItem` 每个描述符文件夹，换全新 UUID 文件夹名。**完全不碰 gallery-index.json，不碰 GalleryCache，不写任何偏好文件，不双写第二容器。**
- `deleteDescriptor`（约 325–359 行）：删文件夹后调用 `removePoster(uuid:fromIndexAt:)`（约 362–374 行），读 `<版本根>/PRPosterRoleLockScreen-gallery-index.json`，把 `entries` 里 `posterUUID` 等于目标的条目滤掉，再写回（`.sortedKeys`）。
- `DescriptorBuilder.swift`：只写描述符文件夹内部文件。`makeDescriptorMetadata`（约 262–327 行）写：`com.apple.posterkit.provider.descriptor.identifier`（随机整数三处同步）、`com.apple.posterkit.role.identifier`（`PRPosterRoleLockScreen`）、`providerInfo.plist`（NSKeyedArchiver，`kConfigurationLastUseDateKey: Date()`）、`versions/1/contents/com.apple.posterkit.provider.contents.userInfo`、`versions/1/contents/<wallpaper>/Wallpaper.plist`。**不写 `assetManifest.caml`，不写任何 RuntimeSnapshotMetadata / supplement / configurableOptions / otherMetadata / suggestionMetadata 文件。**

## 三、Placard 原版到底更不更新 gallery-index.json（任务 2）

**不更新。** 逐行核对了 Placard main 分支原版（2026-11-20 当天取回）：

- `placard/WorseQuery.swift` 的 `writeDescriptors` 与我们的 `writeDescriptors` **逐行一致**：只 `copyItem` 到 `descriptors/<新 UUID>`，不碰任何索引。
- `placard/WallpaperInstaller.swift` 的安装流程：下载/解包 `.tendies` → `randomizeIdentifier` → `findPosterBoardHash` → `writeDescriptors` → 记录名字 → respring。**没有任何索引登记步骤。**
- `gallery-index.json` 在 Placard 代码里只出现在一处用途：`WorseQuery.snapshotBundleURLs`（读它，找快照缩略图 `Resources/Composite.atx` 给自家列表显示）。条目字段：`posterUUID`、`bundleURL`（含 `/descriptors/` 的快照包地址）、`dateCreated`。它是**快照缓存**，不是描述符注册表。
- Placard 删除路径的注释是关键证据（`WorseQuery.swift`，`deleteInstalledWallpaper` 内）：
  > "The directory is authoritative. PosterBoard rebuilds this snapshot index after restart."
  > （目录是权威来源，PosterBoard 重启后会自己重建这个快照索引。）
- 结论：**写路径不需要补 gallery-index 登记。** 往索引里写没有快照 bundleURL 的假条目只会更糟。父代理「写入时没在索引里登记」的假设被证伪。

另有一处需要纠正的旧结论：上份排障报告称 Placard 的 `VideoWallpaper.swift` 是「1628 行」，实际取回的 main 分支文件是 **841 行**。逐行比对后确认：我们的 `DescriptorBuilder` 与 Placard `createDescriptor` / `makeDescriptorMetadata` / `caml` / `blankCAML` / `indexXML` / `floatingIndexXML` **确实逐字一致**（仅 `Int.random` 下限 9999 vs 10000、Swift API 拼写等无关紧要的差别）。——但这恰恰说明：**Placard 自己的视频转换模板本身就是不完整的**，它和我们的描述符缺同样的文件。Placard 能用，靠的是它的主路径——安装社区目录的 `.tendies` 包，那些包里的描述符是完整版（见第五节）。「Placard 单路径 + respring 在 iOS 26/27 上被验证可用」这个说法只对 `.tendies` 目录安装成立，没有证据表明 Placard 的视频转换器在 iOS 27.0.1 上活得下来。

## 四、PosterBoard 扫描时删描述符的条件（任务 4）

没有苹果的公开文档；能从证据 + 三家开源实现推断出的是：

1. **删除发生在 PosterBoard 重启扫描时**（重启手机、respring 都会触发）。证据：14:47→15:19 之间唯一的大动作就是 respring，之后全部被清；更早 14:44 重启后也少了 2 张。
2. **删除是按描述符逐个判定的，不是按容器**。苹果自带的 4 张和我们写的在**同一个** `descriptors/` 目录里，4 张活下来，我们的全被删。能区分它们的只有描述符自身内容（或它在系统索引里的登记状态）。
3. **gallery-index.json 是快照索引，不是注册表**（见第三节）。`Collections/*.plist`、`Roles/*.plist` 里有 `orderedPosterUUIDs` / `posterUUIDs` / `activePosterUUID` / `selectedPosterUUID` 等字段（Camlo 的 `PBRoleIndexPruner` 在操作它们）——那才是"哪些 poster 属于锁屏角色"的登记处。但 Camlo / Placard 安装时**也不直接写**这些 plist；它们是 PosterBoard 自己在成功加载/渲染一个描述符后登记的。
4. 由此最合理的机制（两条，见第六节排序）：**(a) 描述符加载/渲染失败 → 重启扫描时被当成坏描述符清掉**；**(b) iOS 26.4+/27 的容器持久化/迁移逻辑**：`PersistedPosterContainerBundleIdentifiers` + `CompletedPosterBundleIdentifierMigrations` 决定哪些 provider 容器的描述符会被保留/迁移，没写这些键时，旧容器（WallpaperKit.CollectionsPoster）里的新描述符可能在重启迁移扫描中被当成"已迁走的残留"清掉。Camlo 和 AirCard 两家都写这些键（见第五节），且都明确标注 "iOS 26.4+ / iOS 27"——这是它们在 27 上活下来的关键差异之一。

## 五、真 .tendies 描述符 vs 我们的描述符（地面实况，任务 3）

从 Placard 社区目录下载了 `Cipher.tendies`（SerStars/nugget-wallpapers，Placard 主目录的包）并解开，逐项对照。结论：**真描述符比我们的多 8 类文件**。下面这张表是本次排障最核心的证据：

| 文件 | 真 .tendies（Cipher，可活下来） | 我们的描述符 |
|---|---|---|
| 每个 `.ca` 包里的 `assetManifest.caml` | 有（177 字节，内容见下） | **没有**（但每个 `index.xml` 都声明了它） |
| `versions/1/RuntimeSnapshotMetadata-home.plist` | 有（417 字节） | 没有 |
| `versions/1/RuntimeSnapshotMetadata-lock.plist` | 有（417 字节） | 没有 |
| `versions/1/com.apple.posterkit.provider.instance.complicationLayout.plist` | 有（378 字节） | 没有 |
| `versions/1/com.apple.posterkit.provider.instance.titleStyleConfiguration.plist` | 有（691 字节） | 没有 |
| `versions/1/supplements/0/com.apple.posterkit.provider.supplementURL.homescreenConfiguration.plist` | 有（8821 字节） | 没有 |
| `versions/1/contents/.com.apple.posterkit.provider.contents.configurableOptions.plist` | 有（729 字节） | 没有 |
| `versions/1/contents/com.apple.posterkit.provider.contents.otherMetadata.plist` | 有（269 字节） | 没有 |
| `com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist`（根目录） | 有（1281 字节） | 没有 |
| Foreground `.ca` 包（共 Background + Floating + Foreground 三个） | 有 | 只有两个 |
| `providerInfo.plist` | 有（386 字节，`kConfigurationLastUseDateKey`） | 有（等价） |
| `Wallpaper.plist`、`userInfo`、两个 identifier 文件 | 有 | 有（字段基本等价） |

`assetManifest.caml` 的完整内容（Background / Floating / Foreground 三个包里一模一样，177 字节）：

```xml
<?xml version="1.0" encoding="UTF-8"?>

<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <MicaAssetManifest>
    <modules type="NSArray"/>
  </MicaAssetManifest>
</caml>
```

其他核对点：
- 真描述符的 `Wallpaper.plist`：`identifier: 7400`，`family: WWDC22`，`logicalScreenClass: 390w-844h@3x~iphone`，`appearanceAware: false`，含 `foregroundAnimationFileName`；没有 `contentVersion`、`preferredProminentColor`。我们的字段与 Placard 模板一致，不必照抄苹果这份。
- 真描述符的 `userInfo` 里 `wallpaperRepresentingIdentifier` 是**字符串** `"7400"`，我们和 Placard 写的是整数。PosterKit 大概率两种都接受，列为次要差异，不优先改。
- 真描述符的 identifier 文件内容是 `7400`（4 字节）。Camlo 给新注入的描述符分配**递减 ID 19999→10100**（`nextDescendingWallpaperID`），注释说这样新壁纸在 Collections 里排在前面。这是排序问题，不是删除原因，列为可选。
- Camlo 的种子文件就放在它的仓库里：`Camlo/Resources/PosterSeed.bundle/`（`RuntimeSnapshotMetadata-home.plist`、`RuntimeSnapshotMetadata-lock.plist`、`complicationLayout.plist`、`configurableOptions.plist`、`homescreenConfiguration.plist`、`otherMetadata.plist`、`providerInfo.plist`、`suggestionMetadata.plist`、`titleStyleConfiguration.plist`），与 Cipher 包里的同名文件字节数完全一致（417/417/378/729/8821/269/386/1281/691）。种子文件内容已解码核对过：`RuntimeSnapshotMetadata-*` 是 NSKeyedArchiver 的 `PBUIColorStatistics`（平均色 + 对比度）；`complicationLayout` 是空 complications 的 `PRPosterComplicationLayout`；`configurableOptions` 是 `PRPosterConfigurableOptions`；`otherMetadata` 是 `PRPosterMetadata`；`homescreenConfiguration` 是完整的 `PRPosterHomeScreenConfiguration`（含调色板）。
- **注意：不要原样照抄 `suggestionMetadata.plist` 种子。** 它的内容是苹果 7400 WWDC 模板的（`descriptorIdentifier: 7400.DYNAMIC`，`modeUUID: 327BA8A0-00D9-445D-A8AB-7E64CED0914E`），Camlo 的 `normalizeDescriptorForCurrentOS` 会在检测到这两个值时**删掉**这个文件（视为种子冲突）。正确做法是第一版先不写它（见修复方案）。

### Camlo / AirCard 写完描述符后还多做的事（任务 3 续）

**Camlo（`PosterBoardBridge.applyTendiesItems` + `refreshGalleryCacheNonDestructive`）：**

1. **镜像到所有 `*CollectionsPoster*` 扩展目录**：枚举 `Extensions/` 下所有名字含 `CollectionsPoster` 的目录（例如 `com.apple.Posters.CollectionsPosterApp` 及带后缀的变体），把同一描述符文件夹（**同一个 UUID 文件夹名**）复制过去。只写 `com.apple.WallpaperKit.CollectionsPoster` 一个地方是不够的。
2. **清 GalleryCache**：删掉 `<版本根>/GalleryCache` 里的全部内容（瞬时缓存，不删目录本身）。
3. **写持久化偏好**：往 `<PosterBoard 容器>/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist` 里合并写入（保留已有键）：`PBF_RESET_FILE_PROTECTIONS: true`，`PBF_LOCALE_DID_CHANGE: false`；iOS ≥ 26.4 时追加 `PersistedPosterContainerBundleIdentifiers`（至少含 `com.apple.Posters.CollectionsPosterApp`）和 `CompletedPosterBundleIdentifierMigrations`（6 个 ID，见修复方案）。
4. **描述符归一化**（`normalizeDescriptorForCurrentOS`）：清 `__MACOSX` / `.DS_Store` / `.lock` / `._*`；按上面种子表补文件；删 `Wallpaper.plist` 里的 `productTypes`；删异设备 `.atx` 快照；修 `logicalScreenClass == "any"` 的情况；修 ParameterizedCA 空 `wallpaperPropertyGroups`。
5. 同一描述符重装时**复用同一个 UUID 文件夹名**（`itemDescriptorMap`），避免重复卡片；identifier 用递减 ID。

**AirCard（`TendiesEngine.swift`，约 297–375 行）：**

1. **双写**：主写 `Extensions/<ext>/descriptors`，iOS ≥ 18 时 `com.apple.WallpaperKit.CollectionsPoster` 额外写一份到 `Extensions/com.apple.Posters.CollectionsPosterApp/descriptors`（同一 UUID 文件夹名大写形式；Mercury 同理对应 `com.apple.Posters.MercuryPosterApp`）。
2. **写偏好**：`com.apple.PosterBoard.unprotectedUserDefaults.plist` 写到**两个地方**：`<PosterBoard 容器>/Library/Preferences` 和 `/var/mobile/Library/Preferences`。内容：`PBF_RESET_FILE_PROTECTIONS: true`，`PBF_LOCALE_DID_CHANGE: true`（注意：Camlo 此键是 false，见修复方案注），`PersistedPosterContainerBundleIdentifiers`（5 个，见修复方案），`CompletedPosterBundleIdentifierMigrations`（6 个，与 Camlo 相同）。

**Placard：三件都不做。** 它的写路径与我们逐行相同，不镜像、不清 GalleryCache、不写偏好、不补种子文件。这正是为什么「Placard 能用」不能作为「我们的写法没问题」的证据：Placard 的主路径安装的是社区目录的完整 `.tendies` 描述符（自带种子文件和 assetManifest），且它的视频转换器在 iOS 27.0.1 上是否活得下来**没有公开证据**。

## 六、按可能性排序的原因清单

### 原因 1（最可能）：描述符缺 `assetManifest.caml`，PosterKit 加载 .ca 包失败 → 重启扫描时被清掉

- 证据：每个 `.ca` 包的 `index.xml` 都声明 `<key>assetManifest</key><string>assetManifest.caml</string>`，但我们从不写这个文件；真 `.tendies` 三个包里都有它（177 字节空 `MicaAssetManifest`）。这是描述符**加载路径上**的直接缺失，且同时影响视频描述符和 1 帧空白测试描述符——与"连测试描述符也被删"的证据完全吻合。
- 反证与回应：Placard 视频模板同样缺它。如果 Placard 视频转换器在 27.0.1 上也活不下来，两者行为一致，不构成反证；如果它活得下来，那缺失 assetManifest 就不是致命的——但没有公开证据支持后者。无论如何，补上它是零风险的（真描述符里本来就有）。

### 原因 2（高可能，和原因 1 同属"描述符不完整"）：缺 RuntimeSnapshotMetadata 等种子文件，PosterBoard 无法生成画廊快照

- 证据：真描述符在 `versions/1/` 里有 `RuntimeSnapshotMetadata-home/lock.plist`（`PBUIColorStatistics` 平均色/对比度），`supplements/0/` 里有 homescreenConfiguration，`contents/` 里有 configurableOptions / otherMetadata。Camlo 明确把这些叫做"种子"，缺了就补。画廊要显示一张壁纸需要快照统计信息；没有它，PosterBoard 必须自己渲染快照，渲染失败（原因 1）就一起被清。
- 与原因 1 的关系：两个缺失可能共同导致"渲染失败 → 清掉"。修的时候一起补，分不清各自权重没关系。

### 原因 3（高可能，机制直接对应"重启时被删"）：没写 PosterBoard 持久化偏好，iOS 27 重启迁移扫描把旧容器里的新描述符当残留清掉

- 证据：Camlo、AirCard 两家都在写后写 `com.apple.PosterBoard.unprotectedUserDefaults.plist`，都明确标注 "iOS 26.4+ / iOS 27"，键是 `PBF_RESET_FILE_PROTECTIONS`、`PersistedPosterContainerBundleIdentifiers`（含 `com.apple.Posters.CollectionsPosterApp`）、`CompletedPosterBundleIdentifierMigrations`。删除恰好发生在重启/respring 后的扫描，与"迁移/持久化"类逻辑的触发时机一致。
- 反证与回应：苹果自带的 4 张在同一容器里却活下来——说明持久化键不是"容器级生死开关"。更准确的理解是：这些键让 PosterBoard 在重启时**重新登记/保留**它扫描到的描述符；没写键时，扫描只保留它已有登记（角色索引/快照索引里）的描述符，其余当孤儿清掉。苹果的 4 张有登记，我们的没有。

### 原因 4（中高可能）：只写了旧容器，没镜像到 `com.apple.Posters.CollectionsPosterApp`

- 证据：Camlo 镜像到**所有**含 `CollectionsPoster` 的扩展目录；AirCard 在 iOS ≥ 18 时双写 `com.apple.Posters.CollectionsPosterApp`。iOS 27 的画廊很可能以新容器为准枚举；只写旧容器时，PosterBoard 的迁移扫描可能把旧容器里的那份当成"已迁走"而删掉，且新容器里根本没有那份，于是彻底消失。
- 注意：单独做镜像不一定够——如果镜像的那份同样缺 assetManifest/种子，它也会被清。必须和修复 1、2 一起做。

### 原因 5（中可能）：没清 GalleryCache，画廊缓存与磁盘不一致

- 证据：Camlo 写后必清 `<版本根>/GalleryCache`。这主要解释"不显示"，不直接解释"被删"。作为收尾动作一起做，成本极低。

### 原因 6（低，已排除）：gallery-index.json 没登记

- 排除理由见第三节：Placard 不登记；它是 PosterBoard 重启后自己从目录重建的快照缓存；我们的删除路径清它与 Placard 一致。**不要实现索引登记。**

### 原因 7（低）：identifier / 排序问题

- 所有描述符共用 `name`/`family: "Chip"` 与 assets `identifier: 9183`，Placard 模板同样如此；顶层随机 identifier 各不相同。Camlo 的递减 ID（19999→10100）只是让新壁纸在 Collections 里排前面。不是删除原因。

### 原因 8（低，但无法从现有证据排除）：LiveContainer 客 App 写出的文件在所有权/权限上与直装 App 不同

- 写入本身是成功的（文件落地、诊断能读到），删除发生在 PosterBoard 自己的扫描里，与写入进程无关的可能性更大。如果修复 1–3 做完仍被删，下一步诊断是：在手机上对比我们写的描述符文件夹与苹果自带 4 张的 `ls -l@`（所有者、权限位、扩展属性）——这一步只能在真机上做，本报告无法完成。

## 七、精确修复方案（只出方案，未改代码）

按顺序做，一次全上，不要分批试——四个修复互相之间无法区分效果，分批只会多烧几轮构建。

### 修复 1（最优先，原因 1+2）：补全描述符骨架——`DescriptorBuilder.swift`

在 `makeDescriptorMetadata` 之后、或在 `buildDescriptor` / `buildMinimalDescriptor` 写完 `main.caml` / `index.xml` 之后，加一个 `seedDescriptorFiles(at:descriptorURL:)`（新函数，放在 `DescriptorBuilder` 内）：

**1a. 每个 `.ca` 包补 `assetManifest.caml`**（Background 和 Floating 两个包都要，内容完全相同，177 字节，逐字照抄）：

```xml
<?xml version="1.0" encoding="UTF-8"?>

<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <MicaAssetManifest>
    <modules type="NSArray"/>
  </MicaAssetManifest>
</caml>
```

写到：`versions/1/contents/<wallpaper>/Background-....ca/assetManifest.caml` 和 `.../Floating-....ca/assetManifest.caml`（路径用现成的 `animationURL` / `floatingURL` 变量）。

**1b. 补 7 个种子文件。** 来源：Camlo 仓库 `Camlo/Resources/PosterSeed.bundle/`（GPL-3.0，与本项目 LICENSE 一致，引用时保留出处注释），逐文件原样取回（raw.githubusercontent.com/kianuni/Camlo/main/Camlo/Resources/PosterSeed.bundle/<文件名>）。为避开 xcodegen 资源打包的不确定性，**建议以 base64 常量嵌进 Swift 代码**（7 个文件合计约 11 KB，最大一个 homescreenConfiguration 8821 字节，base64 后约 12 KB，完全可接受），不要依赖 bundle 资源文件。写入位置（`verDir` = `versions/1`，`contentsDir` = `versions/1/contents`）：

| 种子文件 | 写到 |
|---|---|
| `RuntimeSnapshotMetadata-home.plist` | `verDir/RuntimeSnapshotMetadata-home.plist` |
| `RuntimeSnapshotMetadata-lock.plist` | `verDir/RuntimeSnapshotMetadata-lock.plist` |
| `complicationLayout.plist` | `verDir/com.apple.posterkit.provider.instance.complicationLayout.plist` |
| `titleStyleConfiguration.plist` | `verDir/com.apple.posterkit.provider.instance.titleStyleConfiguration.plist` |
| `homescreenConfiguration.plist` | `verDir/supplements/0/com.apple.posterkit.provider.supplementURL.homescreenConfiguration.plist`（需先建 `supplements/0` 目录） |
| `configurableOptions.plist` | `contentsDir/.com.apple.posterkit.provider.contents.configurableOptions.plist`（注意文件名以 `.` 开头） |
| `otherMetadata.plist` | `contentsDir/com.apple.posterkit.provider.contents.otherMetadata.plist` |

**不要**种子 `suggestionMetadata.plist`（第一版先不写；它含苹果 7400 模板值，写错比不写更糟；Camlo 自己都会在冲突时删掉它）。**不要**补 Foreground `.ca` 包（真 7400 模板有三个包，但 Placard 模板只有两个也能进目录；先不动，等前三项验证后再说）。

`buildMinimalDescriptor` 同样走 `seedDescriptorFiles`（它和 `buildDescriptor` 共用 `makeDescriptorMetadata`，种子函数也共用）。

### 修复 2（同批，原因 3+4+5）：写后三步——`PosterBoardStore.swift` + `InjectSupport.swift`

在 `PosterBoardStore` 里新增 `postWriteRefresh(appHash:provider:writtenPaths:)`，在 `writeDescriptors` 返回前调用（写完描述符、同一把 worse_query 读写权释放前做完最稳妥；若结构上不方便，就在 `InjectFlow.injectVideo` / `injectMinimalTest` 里写完后立即调）。三步：

**2a. 镜像到所有 `*CollectionsPoster*` 扩展目录。** 枚举 `<storeRoot>/Extensions`（`storeRoot` 用 `descriptorDestination` 所在的版本根，即 `storeRoots` 返回的第一个），对其中名字含 `CollectionsPoster`（大小写不敏感）且不等于当前 provider 的每个目录，把**同一个 UUID 文件夹**（`writtenPaths` 里的文件夹名，原样复用，不要换新 UUID）复制到它的 `descriptors/` 下（目录不存在就先建）。至少覆盖 `com.apple.Posters.CollectionsPosterApp`（AirCard 的做法）；枚举式镜像（Camlo 的做法）能覆盖带后缀的变体目录，两者都要。注意：镜像复制要在持有目标目录读写权的情况下做——复用 `consume(path:extensionsRoot)` 的句柄范围，或对每个目标目录单独 `consume`。

**2b. 清 GalleryCache。** 删掉 `<storeRoot>/GalleryCache` 里的全部内容（只清内容，不删目录本身；目录不存在就跳过）。与 2a 共用同一把句柄。

**2c. 写 PosterBoard 持久化偏好。** 写 `com.apple.PosterBoard.unprotectedUserDefaults.plist`（binary plist），目标两个位置：
  - `<PosterBoard 容器>/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist`（主写；文件已存在时先读出来合并，只增改下面这些键，不删已有键）；
  - `/var/mobile/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist`（AirCard 也写；需要对 `/var/mobile/Library/Preferences` 单独 `consume` 拿读写权；若拿不到就只写容器内那份并记一条日志，不阻塞）。

  内容（照抄 AirCard 的 dict；`PBF_LOCALE_DID_CHANGE` 取值有分歧：AirCard 是 `true`，Camlo 是 `false`——建议用 `true`，强制 PosterBoard 重建画廊缓存；若验证后仍有问题，再试 `false`）：

```swift
[
  "PBF_RESET_FILE_PROTECTIONS": true,
  "PBF_LOCALE_DID_CHANGE": true,
  "PersistedPosterContainerBundleIdentifiers": [
    "com.apple.Posters.CollectionsPosterApp",
    "com.apple.WallpaperKit.CollectionsPoster",
    "com.apple.MercuryPoster",
    "com.apple.Posters.MercuryPosterApp",
    "com.apple.PhotosUIPrivate.PhotosPosterProvider"
  ],
  "CompletedPosterBundleIdentifierMigrations": [
    "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
    "com.apple.Posters.WeatherPosterApp.WeatherPoster",
    "com.apple.Posters.UnityPosterApp.Unity2025Poster",
    "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
    "com.apple.Posters.UnityPosterApp.RhizomePoster",
    "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
  ]
]
```

`InjectSupport.swift` 的 `InjectFlow.injectVideo` / `injectMinimalTest` 不需要改调用点以外的逻辑（`writeDescriptors` 内部调 `postWriteRefresh` 是最干净的）；若 `writeDescriptors` 内不方便，就在两个调用点各加一行。

### 修复 3（同批，诊断加强，低成本）：`InjectDiagnosticsView.swift`

第 5 步在数完主 provider 的张数后，顺带探测并显示：`Extensions/` 下是否还有其他含 `CollectionsPoster` 的目录、各有几张；第 7 步核对时，**两个容器一起查**（主容器 + 镜像容器），逐张显示"主容器：还在/已消失；镜像容器：还在/已消失"。这样下次能立刻区分"镜像没写上"和"两个容器一起被清"。

### 修复 4（可选，最后做）：递减 identifier

`DescriptorBuilder` 里 `Int.random(in: 10_000...99_999)` 改成 Camlo 的做法：UserDefaults 里存 `nextDescendingID`，从 19999 开始每次减 1，用到 10100 后回到 19999。只影响 Collections 里的排序，不影响生死；放在最后，不 blocking。

### 明确不做

- **不往 `PRPosterRoleLockScreen-gallery-index.json` 里登记条目。** 它是快照缓存，Placard 不写，PosterBoard 重启后自己从目录重建；写没有快照 bundleURL 的假条目只会更糟。
- **不改写路径本身**（`writeDescriptors` 的 copy 逻辑与 Placard 逐行一致，没问题）。
- **不改 CAML / Wallpaper.plist 模板**（与 Placard 逐字一致，且真 `.tendies` 的 Wallpaper.plist 字段与模板基本等价）。

## 八、验证方法（给 parent / 用户）

一次全上修复 1+2+3 后编构建 #15，测试顺序：

1. 装新 IPA，先跑直写诊断：看第 5 步张数、第 7 步（新版会分容器显示）。
2. 做一张变身壁纸（不要用视频壁纸先试——变量最少），一键写入，点「立即注销桌面生效」。
3. 桌面重启后重进 LiveContainer，跑直写诊断看第 7 步：**这张还在不在两个容器里**。还在 = 修好了大半；再长按锁屏点 +、滑到底部「收藏」找它。
4. 如果第 7 步显示"主容器已消失、镜像容器还在"（或反过来），说明镜像有效但主容器仍被清——下轮只保留镜像容器 + 偏好键的组合再试。
5. 如果两个容器一起消失，说明删除与容器无关，回到原因 8：在真机上对比我们写的描述符文件夹与苹果自带 4 张的 `ls -l@`（所有者、权限、扩展属性），并考虑改走"先导出 .tendies、再用 Placard/Camlo 的思路导回"的对照实验——即拿 Cipher.tendies 的完整描述符原样写进去，看它活不活，以此区分"骨架问题"还是"写入环境问题"。

## 九、来源清单

- 本地：`BizhiGongfang/Inject/PosterBoardStore.swift`（`writeDescriptors`、`deleteDescriptor`、`removePoster`）、`BizhiGongfang/Inject/DescriptorBuilder.swift`（`makeDescriptorMetadata`、`caml`、`indexXML`）、`~/workspace/wallpaper-studio-ios/INJECT_RESEARCH.md`（只提到 assetManifest.caml 是 index.xml 里的字段名，没人注意到文件本身必须存在）。
- Placard（frs0n/placard，main 分支，2026-11-20 取回）：`placard/WorseQuery.swift`（`writeDescriptors`、`installedWallpapers`、`snapshotBundleURLs`、`deleteInstalledWallpaper` 注释 "The directory is authoritative…"）、`placard/WallpaperInstaller.swift`（安装流程）、`placard/VideoWallpaper.swift`（841 行，`createDescriptor` / `makeDescriptorMetadata` / `caml` / `indexXML`）、`placard/WallpaperCatalog.swift`（目录源 SerStars/nugget-wallpapers）。
- 地面实况：`Cipher.tendies`（Placard 目录，`wallpapers/custom/Cipher.tendies`，1,292,106 字节），描述符 `09E9B685-7456-4856-9C10-47DF26B76C33` 全文件清单及 `Wallpaper.plist` / `userInfo` / `assetManifest.caml` 内容已逐项核对。
- Camlo（kianuni/Camlo，main 分支，2026-11-20 取回）：`Camlo/Bridge/PosterBoardBridge.swift`（`normalizeDescriptorForCurrentOS`、`synchronizeCollectionsIdentifier`、`applyTendiesItems` 镜像逻辑、`refreshGalleryCacheNonDestructive` 偏好键）、`Camlo/Bridge/InstalledPosterManager.swift`（`PBRoleIndexPruner` 的 `Collections/` / `Roles/` 索引结构）、`Camlo/Resources/PosterSeed.bundle/`（9 个种子文件，已下载并用 plistlib 解码核对）。
- AirCard（Mak5er/AirCard-iOS，main 分支，2026-11-20 取回）：`ios-app/TendiesEngine.swift`（约 297–375 行：双写 + 偏好文件写两处）。
