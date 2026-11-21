# 排障报告 3：描述符活下来了，画廊为什么还不显示

日期：2026-11-20（v15 构建 #15 实测后）
结论先行：**删除问题已解决，画廊不显示是另一个阶段的问题。** 构建 #15 之后，
描述符能通过 PosterBoard 重启扫描（不再被删），但画廊列出它还需要第二步——
**PosterBoard 加载并渲染它、生成快照（`RuntimeSnapshot-lock.atx` + gallery-index
条目），画廊才有素材显示它**。我们的描述符现在卡在这第二步：要么 PosterBoard
根本没把它列入渲染（枚举时按条件过滤掉了），要么渲染失败了。写路径本身已经
和 Placard 逐行一致、收尾动作和 Camlo / AirCard 一致，剩下的分歧只在两处：
**(1) 描述符内容本身**——最大的嫌疑是 `logicalScreenClass` 用了 iPad 类
（`810w-1080h@2x~ipad`），其次是缺 Foreground 包；**(2) 写入环境**——
LiveContainer 文件权限、或 NeoSpring 的 respring 并没有真正重启 PosterBoard
守护进程。先做对照测试分清是哪一边（已实现，见第八节），再决定改什么。

## 一、最新证据（2026-11-20 15:46–15:51 CST，v15 实测）

- 装 v15，先跑诊断：第 5 步 **5 张**（苹果 4 张 + v14 测试描述符 04CC11AE——
  说明它居然活下来了）；第 6 步又写测试 E8DA120A。
- 做**变身壁纸 11-20 15:46**（夜市照片，缩略图正的）一键写入，再跑诊断：
  第 5 步 **7 张**（4 + 04CC11AE + E8DA120A + 变身 15:46），第 6 步又写测试
  2B8688BC；**第 7 步：变身 15:46「主容器：还在；镜像容器：未找到」**。
- 15:51 又跑一次诊断：第 5 步 **8 张**（7 + 2B8688BC），第 6 步又写测试
  4355A55E，第 7 步变身 15:46 仍「主容器：还在」。
- 计数一路 4 → 5 → 7 → 8，**一个都没再被删**。镜像容器在该设备上不存在
  （没有 `com.apple.Posters.CollectionsPosterApp` 扩展目录可镜像——不是失败，
  只是没东西可镜像）。
- 用户确认 15:46 注入后**点了「立即注销桌面生效」**（NeoSpring respring 成功），
  但锁屏画廊「收藏」里还是找不到这张壁纸（找的是夜市照片本身，不是蓝块）。
- 已证伪的理论：缺 respring（点了，桌面重启了）、描述符被删（第 7 步证明还在）、
  收藏位置找错（用户滑到底部看过）、视频横屏（这次是变身壁纸，竖屏源）。

## 二、画廊要「列出」一个描述符，到底需要什么

综合 Placard / Camlo / AirCard 三家代码 + Cipher.tendies 地面实况，链路是五步，
缺一步都不显示：

1. **写进目录**：`PRBPosterExtensionDataStore/<版本>/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/<UUID>/`。
   我们和 Placard 的 `writeDescriptors` 逐行一致（只 `copyItem`），已验证写得进去。
2. **PosterBoard 重启后扫描目录**：删除坏描述符（v14 的行为）、保留好的（v15 的行为）。
   Placard 删除路径的注释是关键证据："The directory is authoritative. PosterBoard
   rebuilds this snapshot index after restart."（目录是权威来源，PosterBoard 重启后
   自己重建快照索引。）
3. **加载 + 渲染描述符**：PosterBoard 的快照服务加载每个描述符的 `.ca` 包并渲染
   出缩略图，写进两处：描述符文件夹内的 `versions/<n>/RuntimeSnapshot-lock.atx`
   （及 `-home.atx`），以及快照索引 `PRPosterRoleLockScreen-gallery-index.json`
   里的条目（`posterUUID` / `bundleURL` → `Resources/Composite.atx` /
   `dateCreated`）。Placard 读缩略图时就按这个顺序找：先找 `RuntimeSnapshot-lock.atx`，
   再找索引里的 `Resources/Composite.atx`；两者都没有时报错 "The system has not
   generated a readable Lock Screen snapshot yet."——**说明「没有快照」是正常中间态，
   不是描述符坏了的标志；但画廊没有快照就没法显示那张壁纸。**
4. **画廊枚举**：锁屏画廊读快照索引 + 描述符目录，列出有快照的描述符。
   Camlo 的 `galleryDestinationHint` 证实：CollectionsPoster 的描述符出现在
   「收藏」与「专为 iPhone 设计的墙纸」两个区——**画廊是按 provider / 设备类别
   分区的，存在按条件过滤的可能**。
5. **（无）索引登记**：三家安装时都不写 gallery-index.json、不写 `Collections/` /
   `Roles/` 的 `orderedPosterUUIDs`（Camlo 的 `PBRoleIndexPruner` 只删已删壁纸的
   残留条目，不新增）。诊断 2 已证伪「索引登记」理论，本报告再次确认：**不要实现
   索引登记**。

所以 v15 的状态是：**第 2 步通过了（活下来），第 3 步没发生或失败了（没快照、
没进画廊）**。新诊断在第 7 步加了快照检查（`RuntimeSnapshot-lock.atx` 有没有），
下次跑诊断就能直接看到「渲染过 / 没渲染过」，不用再猜。

## 三、我们的描述符 vs 真 Cipher.tendies（逐文件逐字段，2026-11-20 重新核对）

地面实况重新下载核对：`Cipher.tendies` 1,292,106 字节（与诊断 2 一致），描述符
`09E9B685-7456-4856-9C10-47DF26B76C33`。我们的描述符结构 = Placard
`VideoWallpaper.swift`（841 行）模板 + 构建 #15 补的骨架（assetManifest +
7 个种子文件）。逐项对照：

| 项目 | 真 Cipher（能进画廊） | 我们的描述符 | 备注 |
|---|---|---|---|
| `logicalScreenClass` | `390w-844h@3x~iphone` | **`810w-1080h@2x~ipad`** | iPad 类；iPhone 13 Pro 是 390w-844h@3x |
| `.wallpaper` 文件名 | `7400.WWDC_2022-390w-844h@3x~iphone.wallpaper` | `9183.Custom-810w-1080h@2x~ipad.wallpaper` | 文件名本身也带设备类 |
| `.ca` 文件名 | `7400.WWDC_2022_*_390w-844h@3x~iphone.ca` | `9183.Custom_*_810w-1080h@2x~ipad.ca` | 同上 |
| `.ca` 包数量 | 3 个（Background + Floating + **Foreground**） | 2 个（Background + Floating） | 缺 Foreground 包 |
| `Wallpaper.plist` 的 `foregroundAnimationFileName` | 有 | **没有** | 与上行同一问题 |
| `Wallpaper.plist` 的 `family` / `name` | `WWDC22` / `WWDC 2022` | `Chip` / `Chip` | 模板常量 |
| `Wallpaper.plist` 的 `appearanceAware` | `false` | `true` | 我们声称支持深浅色变体，但只有一套素材 |
| `Wallpaper.plist` 的 `contentVersion` | 无 | `2.01` | 模板自带 |
| `Wallpaper.plist` 的 `preferredProminentColor` | 无 | `dark: "#00000"`、`default: "#FFFFFF"` | `#00000` 是 5 位十六进制，格式可疑（应为 6 位） |
| `Wallpaper.plist` 的 `assets.identifier` | 7400（= 顶层 identifier） | 9183（≠ 顶层递减 ID） | Camlo 注释：assets identifier 跟 `.ca` 文件名绑定，不用改——不是问题 |
| `userInfo` 的 `wallpaperRepresentingIdentifier` | 字符串 `"7400"` | 整数（递减 ID） | Placard / Camlo / AirCard 三家都写整数——不是问题 |
| 顶层 `identifier`（三处同步） | 7400 | 递减 ID（19999→10100） | 三家都用非 7400 的随机/递减 ID——不是问题（见第六节） |
| `suggestionMetadata.plist` | 有（1281 字节，`7400.DYNAMIC` / modeUUID `327BA8A0-00D9-445D-A8AB-7E64CED0914E` / `ATXFaceGalleryItem` / score 20.0 / `displayNameLocalizationKey: "Collections"`） | **没有** | 见原因 6 |
| Background `index.xml` 的 `documentWidth/Height` | 390 / 844（**点**） | 886 / 1920（**像素**） | CAML 坐标空间也是点 vs 像素 |
| Background `index.xml` 的 `documentResizesToView` / `loopingEnabled` / `loopEnd` | false / true / +infinity | true / false / 0.0 | 模板差异 |
| Floating `index.xml` | 只有 `rootDocument: main.caml`（242 字节） | 完整版（3176 尺寸，与 Background 同结构） | 模板差异 |
| Floating `main.caml` | CAPlayground 空根层 390×844 | 空白层 3176×3176 | 模板差异 |
| Foreground `main.caml` | 空根层 390×844（带 `<scriptComponents/>`） | ——（没有这个包） | 见上 |
| Background `main.caml` | 184 KB，CAPlayground 生成，点坐标，含 `Root_Layer.js` | 简单 CAKeyframeAnimation 逐帧切图，像素坐标 | 都是合法 CAML，结构不同 |
| CAML 根层 `name` | `CAPlayground Root Layer` / `Root Layer` | Background 包根层叫 `_FLOATING`、Floating 包根层叫 `_BACKGROUND`（名字互换） | Placard 模板原样，疑似笔误但三家都没改 |
| `assetManifest.caml` | 每个包都有（Background/Foreground 177 字节，Floating 176 字节） | 构建 #15 已补（两个包都是 177 字节） | 已对齐 |
| 7 个种子文件 | 全部有 | 构建 #15 已补（base64 嵌 Swift，逐字节核对） | 已对齐 |
| `providerInfo.plist` | 有（`kConfigurationLastUseDateKey`） | 有（等价） | 已对齐 |
| `RuntimeSnapshot-lock.atx`（系统生成） | 包里没有（装完由系统生成） | 包里没有（同理） | 诊断第 7 步现会检查它 |

另外核对过：Placard 的 `VideoWallpaper.swift` 确实就是这套模板（`9183.Custom-810w-1080h@2x~ipad`、
`logicalScreenClass: 810w-1080h@2x~ipad`、`preferredProminentColor: ["dark": "#00000", ...]`、
`contentVersion: 2.01`、CAML 根层 `_FLOATING` / `_BACKGROUND` 互换、indexXML 像素尺寸）——
**我们的描述符与 Placard 视频转换器的输出逐字一致**。但诊断 2 已指出：没有任何公开证据
表明 Placard 的视频转换器在 iPhone + iOS 27.0.1 上能进画廊；Placard 能用，靠的是安装
社区目录的完整 `.tendies` 包。

## 四、gallery-index.json 到底什么时候重建

- 三家都不写它；Placard 注释说 PosterBoard **重启后**自己从目录重建。
- Camlo 的刷新提示原文是「请注销桌面或在后台上滑关闭 PosterBoard 后生效」——
  即 **respring 或杀掉 PosterBoard 二选一**，不是只认 respring。
- 我们的 postWriteRefresh（构建 #15）已经做了 Camlo / AirCard 的收尾：清
  GalleryCache + 写偏好 plist（两处）。**还缺的触发条件只有一个可能：PosterBoard
  守护进程本身没有重启。** NeoSpring 是挤爆 WebKit GPU 进程拖垮 SpringBoard，
  launchd 重启 SpringBoard——PosterBoard.app 是独立的守护进程，respring 未必重启它。
  v14 的删除发生在 respring 之后，说明**删除扫描**在 respring 后跑了；但删除扫描
  和**快照生成 / 索引重建**未必是同一个触发器、同一个进程。
- 便宜的验证（不用改代码）：注入 → respring → **再去多任务界面把 PosterBoard
  划掉**（诊断页脚一直是这么提示的）→ 再长按锁屏点 + 看画廊。如果划掉 PosterBoard
  后出现了，病根就是「PosterBoard 没重启」，修复是在注入成功提示里把「划掉
  PosterBoard」写成必做步骤（或在 respring 后自动提醒）。

## 五、画廊读的是不是另一个位置

- **不是。** 三家写的是同一个位置：`PRBPosterExtensionDataStore/<最大版本号>/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/`。
  Camlo 的 `resolveStoreVersion` = 最大的带 Extensions 的数字版本目录——和我们的
  `storeRoots`（取最大）完全一致；用户设备上是 **61**。
- 镜像容器 `com.apple.Posters.CollectionsPosterApp` 在该设备上**不存在**
  （诊断第 5 步「镜像容器：未找到」），所以双写无从谈起——AirCard / Camlo 的双写
  逻辑在该设备上是空操作，不构成差异。
- 排除位置问题。唯一保留的疑问是：如果设备上有多个版本目录（如 60 和 61），
  画廊会不会读旧的那个——但 Camlo 用同样的「取最大」逻辑且能用，排除。

## 六、identifier 的取值有没有讲究

- **基本排除。** 真 Cipher 用 7400；Camlo 用递减 ID（19999→10100，和我们一样）；
  Placard 用随机 10000–99999；AirCard 用随机 ID。三家都用非 7400 的 ID 且能用。
- 细节：Camlo 的 `synchronizeCollectionsIdentifier` 在有 `WallpaperCollection.plist`
  时会把 order 映射到 `100_000 + ...` 区间——我们没有 WallpaperCollection.plist，
  不适用。AirCard 的注释值得记一笔：如果描述符自带 suggestionMetadata，**只改
  Wallpaper.plist 会打乱 PosterKit 的 suggestion 查找**——Placard 不管这个照改三处，
  Camlo 是先删掉冲突的 suggestionMetadata 再改三处。我们的对照测试照 Placard 的
  做法（保留 suggestionMetadata、只改三处），正好能测出这条路在该设备上通不通。

## 七、按可能性排序的原因清单

### 原因 1（最可能）：`logicalScreenClass` 是 iPad 类，画廊按设备类过滤掉了它

- 证据：这是我们的描述符与所有已知能进画廊的描述符之间**最大的结构性差异**。
  真 Cipher 是 `390w-844h@3x~iphone`，文件名本身也带这个类；我们的文件名、
  Wallpaper.plist、index.xml、CAML 坐标全套都是 iPad 类 / 像素尺寸。
  Camlo 的 `normalizeDescriptorForCurrentOS` 把 `logicalScreenClass` 当设备相关
  字段处理（`any` 时按文件名里的 `~ipad` 与否改成 iPad 类或 iPhone 类）；
  Camlo 的画廊提示把 CollectionsPoster 描述符分在「收藏」与「专为 iPhone 设计
  的墙纸」两区——画廊存在按设备类分区的逻辑。
- 反证与回应：Placard 模板同样用 iPad 类。如果 Placard 视频转换器在 iPhone 上
  能进画廊，本原因不成立——但**没有任何公开证据**表明它在 iOS 27.0.1 的 iPhone
  上进过画廊；Placard 能用靠的是社区完整包（全是设备匹配的类）。
- 验证方法：对照测试（第八节）——Cipher 是 iPhone 类，如果它出现而我们的不出现，
  本原因嫌疑最大；下一步直接改我们的模板：文件名、Wallpaper.plist、
  index.xml、CAML 坐标全部换成设备原生 iPhone 类（390w-844h@3x，点坐标），
  再测一次。

### 原因 2（高可能）：PosterBoard 渲染失败，始终没生成快照

- 证据链：描述符能通过解析扫描（活下来），但画廊要快照才能显示；第 7 步新增的
  快照检查能直接验证——如果我们的描述符和对照描述符都是「快照：未生成」，
  说明渲染环节根本没跑或跑失败了。
- 渲染失败的候选子原因（按可疑程度）：
  - (a) **缺 Foreground 包**：真描述符有 3 个包，Wallpaper.plist 里有
    `foregroundAnimationFileName`；我们只有 2 个包且没这个字段。锁屏渲染器
    可能要求三层齐全（时钟深度效果在前景层）。
  - (b) **像素坐标空间**：我们的 CAML bounds 和 index.xml 都是像素
    （886×1920），真包是点（390×844）。快照服务按 document 尺寸渲染，
    像素尺寸未必错，但和 iPad 类叠加后可能被当成异设备描述符跳过。
  - (c) **`preferredProminentColor` 的 `"#00000"`**：5 位十六进制，格式错误。
    画廊读 prominent color 做磁贴配色时解析失败，可能直接跳过该条目。
    这是明确的笔误（Placard 模板原样），无论如何都该改成 `"#000000"`。
  - (d) **`appearanceAware: true`**：声称支持深浅色变体，但只有一套素材；
    渲染器要深色变体时可能失败。真包是 `false`。
  - (e) CAML 根层名字互换（Background 包根层叫 `_FLOATING`）：Placard 模板原样，
    大概率只是名字，不影响渲染，排最后。
- 验证方法：先看第 7 步快照状态；再逐项改（先改 (c) + (a)，因为成本最低、
  最接近真包；像素坐标随原因 1 一起改）。

### 原因 3（中可能）：NeoSpring 的 respring 没有真正重启 PosterBoard

- 证据：见第四节。Camlo 明确认可「杀掉 PosterBoard」作为替代触发；我们的诊断页
  脚也一直提示划掉 PosterBoard，但用户是否每次都划了并不确定。
- 验证方法（零成本）：注入 → respring → **多任务界面划掉 PosterBoard** →
  再进画廊。如果出现，修复就是把这一步写进成功提示的必做项。

### 原因 4（中可能）：LiveContainer 客 App 写出的文件，权限/所有权与直装不同，快照服务读不到

- 证据：诊断 2 的原因 8，原样保留。写入本身成功（文件落地、诊断能读到），
  删除扫描也能读（否则不会「活下来」）；但快照渲染可能跑在另一个 XPC 服务/
  用户下，读不到我们写的文件就静默跳过渲染。
- 验证方法（只能在真机上做）：对照测试如果也不出现，且快照「未生成」，下一步
  在手机上对比我们写的描述符文件夹与苹果自带 4 张的 `ls -l@`（所有者、权限位、
  扩展属性）；或把同一份对照描述符用 Placard/Camlo 在该设备上装一次看结果。

### 原因 5（低可能）：`PBF_LOCALE_DID_CHANGE` 取值分歧（我们用 AirCard 的 true，Camlo 用 false）

- 证据：两家取值相反。`true` 本意是强制重建画廊缓存，理论上该帮忙；但如果
  `true` 触发的是「地区变更后的全量迁移」，可能跳过未登记的描述符。
  我们的描述符活下来了，所以即使有影响也不是删除级的影响。
- 验证方法：对照测试失败后，再试改成 `false` 编一版。

### 原因 6（低–中可能）：缺 `suggestionMetadata.plist`，画廊的「推荐条目」查不到它

- 证据：真 Cipher 自带它（`ATXFaceGalleryItem`，`descriptorIdentifier: 7400.DYNAMIC`，
  `displayNameLocalizationKey: "Collections"`，score 20.0）——字段名直指「画廊推荐条目」。
  但 Camlo 会在它与苹果模板值冲突时**删掉**它，Placard 安装时保留它却改了三处
  identifier（AirCard 注释说这样会打乱 suggestion 查找）——三家行为不一致，
  说明它不是「列出」的必要条件，至多是排序/推荐权重。
- 验证方法：对照测试保留了它（原样），如果对照出现而我们的不出现，且改完原因 1
  仍不出现，再试给我们的描述符也补一份（identifier 同步成新的递减 ID，
  modeUUID 换新的随机 UUID，不要照抄 7400.DYNAMIC）。

### 原因 7（低，已排除大半）：identifier 取值

- 排除理由见第六节：三家都用非 7400 的随机/递减 ID。对照测试用的也是同一个
  递减计数器，如果对照出现而我们的不出现，ID 取值不可能是原因。

### 原因 8（低，已排除）：位置 / 版本目录 / 镜像容器

- 排除理由见第五节：与 Camlo 同一套版本解析（最大版 61），镜像容器在该设备上
  不存在，双写是空操作。

### 原因 9（低，已排除）：gallery-index.json 没登记

- 排除理由见第二节：三家安装时都不登记；它是快照缓存，PosterBoard 重启后自己
  从目录重建。**仍然不要实现索引登记。**

## 八、对照测试（已实现，编构建 #16）

目的：一次实验分清「描述符内容」还是「写入环境 / 画廊刷新」。

- 做法：`BizhiGongfang/Inject/ControlDescriptorData.swift`（新建，机器生成）
  嵌了完整的真实 Cipher 描述符（80 个文件，1,815,321 字节，逐文件 base64，
  已剔除 `__MACOSX` / `.DS_Store` / `._*`；生成后自校验 80/80 逐字节相同）；
  `ControlDescriptor.swift`（新建）重建文件夹时只改三处 identifier（文件夹
  UUID 由写路径换；三处同步换成同一个新的递减 ID，与 Placard 安装社区包的
  做法一致；suggestionMetadata、assets identifier、文件名、CAML 全部原样）；
  `InjectFlow.injectControlTest()`（新增）走和正常注入完全相同的
  `writeDescriptors` 路径（同样享受 postWriteRefresh 的镜像 + 清缓存 + 写偏好）；
  诊断页新增「对照测试」区：按钮「写入对照测试描述符」、按钮「删除对照测试
  描述符」（复用 `deleteDescriptor`），UUID 存在 UserDefaults，第 7 步核对里
  一起显示（主容器 / 镜像容器 / **快照：已生成/未生成**）。
- 改动清单与测试步骤见 `CHANGED_FILES.md`「对照测试」一节（共 6 个文件：
  新建 2 个，替换 4 个；`project.yml` 不用动，新文件自动编入）。
- 结果解读：
  - **对照在收藏里出现了** → 写入环境和画廊刷新都没问题，**我们的描述符内容
    有问题**。下一步按第七节排序改：先改原因 1（logicalScreenClass 全套换成
    设备原生 iPhone 类 + 点坐标），再补原因 2(a) Foreground 包 + 2(c) `#000000`。
  - **对照也没出现，但第 7 步显示它「主容器：还在」** → 问题不在描述符内容，
    在写入环境或画廊刷新。下一步：先做原因 3 的验证（respring 后划掉 PosterBoard
    再看画廊）；再试原因 5（`PBF_LOCALE_DID_CHANGE` 改 false）；最后查原因 4
    （真机 `ls -l@` 对比文件权限/所有权）。
  - **对照还在磁盘上，但快照「未生成」** → PosterBoard 没渲染它。重点查渲染环节：
    先确认 PosterBoard 真的重启过（原因 3），再考虑原因 4（快照服务读不到文件）。
  - **对照在第 7 步显示「已消失」** → 说明连真描述符都会被删，删除问题没完全修好
    （与 v15 结论矛盾），回头查构建 #15 的收尾动作有没有生效（偏好 plist 有没有
    真写进去、GalleryCache 有没有真清掉）。

## 九、来源清单

- 本地：`BizhiGongfang/Inject/DescriptorBuilder.swift`（`makeDescriptorMetadata`、
  `caml`、`indexXML`、`floatingIndexXML`、`seedDescriptorFiles`、`nextDescendingIdentifier`）、
  `PosterBoardStore.swift`（`writeDescriptors`、`postWriteRefresh`、`storeRoots`、
  `descriptorDestination`、`deleteDescriptor`）、`InjectDiagnosticsView.swift`、
  `InjectSupport.swift`（`InjectFlow.injectVideo` / `injectMinimalTest`）。
- 地面实况：`Cipher.tendies`（SerStars/nugget-wallpapers，2026-11-20 重新下载，
  1,292,106 字节），描述符 `09E9B685-7456-4856-9C10-47DF26B76C33` 全文件清单及
  `Wallpaper.plist` / `userInfo` / `suggestionMetadata.plist` / `providerInfo.plist` /
  三个 `.ca` 包的 `index.xml` / `main.caml` 已逐项核对（本次排障新核对了
  `.ca` 包的 index.xml 与 main.caml 内容，诊断 2 只核对了文件清单）。
- Placard（frs0n/placard，main 分支，2026-11-20 取回）：`placard/VideoWallpaper.swift`
  （841 行，模板与我们的描述符逐字一致，包括 `810w-1080h@2x~ipad`、`#00000`、
  根层名互换）、`placard/WallpaperInstaller.swift`（安装流程：下载 → 解包 →
  `randomizeIdentifier` 三处 → `findPosterBoardHash` → `writeDescriptors` → respring；
  不写索引、不写偏好、不镜像）、`placard/Exploit/WorseQuery.swift`
  （`installedWallpapers`：快照来源 `RuntimeSnapshot-lock.atx` / 索引
  `Resources/Composite.atx`；删除注释 "The directory is authoritative…"）。
- Camlo（kianuni/Camlo，main 分支，2026-11-20 取回）：`Camlo/Bridge/PosterBoardBridge.swift`
  （`normalizeDescriptorForCurrentOS`：清 junk、种子文件、删冲突 suggestionMetadata、
  清外来 `.atx`、修 `logicalScreenClass == "any"`、`synchronizeCollectionsIdentifier`、
  `applyTendiesItems`：镜像 + 递减 ID + 复用 UUID、`refreshGalleryCacheNonDestructive`：
  清 GalleryCache + 写偏好，`PBF_LOCALE_DID_CHANGE: false`、`PBExtensionTarget.resolveStoreVersion`：
  取最大带 Extensions 的版本）、`Camlo/Bridge/InstalledPosterManager.swift`
  （`PBRoleIndexPruner`：只删 `Collections/` / `Roles/` 里已删壁纸的残留条目）。
- AirCard（Mak5er/AirCard-iOS，main 分支，2026-11-20 取回）：`ios-app/TendiesEngine.swift`
  （`updatePlistIdentifiers`：有 suggestionMetadata 时不随机化，注释 "Randomizing only
  Wallpaper.plist desynchronizes PosterKit's suggestion lookup!"；双写 + 偏好写两处，
  `PBF_LOCALE_DID_CHANGE: true`）。

## 十、构建 #17 准备（2026-11-20，对照测试结果出来之后）

### 最新证据（2026-11-20 16:24 CST，构建 #16 实测）

- 第 5 步 12 张，第 6 步又写测试 F0A76E67；第 7 步：**变身壁纸 11-20 16:23
  （主容器：还在；镜像容器：未找到；快照：未生成）；对照测试描述符（Cipher）
  （主容器：还在；镜像容器：未找到；快照：未生成）**。
- hasSnapshot 的实现已核对过（查 `<描述符>/versions/<n>/RuntimeSnapshot-lock.atx`，
  路径正确），所以「未生成」是真的：**连原样真包都没被渲染**。
- 用户 16:25 CST 确认画廊「还是没有」。
- 结论更新：问题不在我们描述符内容——原因 1（iPad 类）、原因 2
  （Foreground / #00000 / 像素坐标）暂时都不是主因（它们仍然可能是「渲染失败」
  的子原因，但一个原样真包都渲染不出来，说明渲染环节在更上游就没启动）。
  剩下的主攻方向是原因 3（PosterBoard 到底重启了没有）→ 原因 5（偏好值）
  → 原因 4（文件权限/所有权）。

### 构建 #17 改了什么

1. **原因 5 对照实验**：`PBF_LOCALE_DID_CHANGE` 从 `true`（AirCard 的值）
   改成 `false`（Camlo 的值），只改这一个值。改完若画廊出现，说明 true
   是问题；若仍不出现，原因 5 排除。
2. **原因 4 取证工具**：诊断页新增「文件权限对照」区（只读），对主容器里
   每张描述符文件夹显示：所有者（NSFileOwnerAccountName）、POSIX 权限位
   （八进制）、扩展属性名（listxattr，只列名、不读值）。我们写的按壁纸名字
   显示，不在记录里的按 UUID 前 8 位显示（苹果自带或之前诊断写的旧测试
   描述符）。读不到就显示「读不到」，不崩。

### 权限对照能看到什么、怎么读

- 正常情况（系统写的和我们写的一样）：所有行所有者都是 `mobile`，权限
  都是 `755`（文件夹），扩展属性要么都没有、要么都一样。看到这样，原因 4
  基本排除。
- 可疑情况 1：我们写的文件夹权限是 `700`（只有所有者能读），苹果的是
  `755`——快照服务（跑在另一个用户/沙盒下）读不到我们的文件，渲染直接跳过。
- 可疑情况 2：所有者不一样（比如我们的是 `mobile`，苹果的是别的，或反过来）
  ——LiveContainer 客 App 写出的文件归属和直装 App 不同。
- 可疑情况 3：扩展属性不一样——比如我们的文件带了 `com.apple.quarantine`
  之类系统不认的标记，或缺了苹果文件带的某个标记（比如
  `com.apple.provenance`）。

### 如果权限对照显示不一样，下一步怎么修（只写思路，本次不实现）

- **权限位不对（最可能修得好）**：写入后、收尾前，对描述符文件夹及里面
  全部文件/子目录按苹果的权限位改一遍（文件夹 755、文件 644），用
  `FileManager.setAttributes([.posixPermissions: ...])` 递归改，不用私有
  API。改完重新跑一次诊断看对照区是否对齐，再注销桌面看快照。
- **扩展属性不对**：我们写的文件如果带了多余的 xattr（比如 quarantine），
  用 `removexattr` 清掉；如果缺了苹果文件带的某个 xattr，先不要照抄——
  有些系统 xattr（如 provenance）是系统签发时打的，伪造可能被校验拒绝，
  先确认缺的是哪一个再决定。
- **所有者不对**：App 里改不了所有者（chown 要 root 权限，App 没有；
  而且 App 写出的文件本来就归 mobile 所有）。如果对照显示所有者真的不
  一样，说明差异来自 LiveContainer 的运行环境而非文件本身——那下一步是
  换环境验证：把同一份对照描述符用 Placard / Camlo 在该设备上装一次，
  看它的快照生不生成（分清「LiveContainer 客 App 写的文件」还是「我们
  的写入路径」的问题）。
- **权限对照完全一样、但快照还是未生成**：原因 4、5 都排除，回原因 3：
  确认 PosterBoard 守护进程到底重启了没有（respring 后划掉 PosterBoard
  再看快照状态）；再往下是快照服务本身的问题，需要在真机上看 PosterBoard
  的日志（不在本次任务内）。

### 上游核查：除了 respring，还有别的渲染触发器吗

重查了 /tmp/diag3/upstream 的三家源码（Placard / Camlo / AirCard，
2026-11-20 取回的版本）：**没找到**。具体查过：

- Darwin 通知（notify_post / CFNotificationCenter / 分布式通知）：三家
  代码里一个都没有。
- touch / utimens（改文件时间戳逼系统重扫）：没有。
- 强制生成快照的私有 API：没有；Placard 只读快照，不触发。
- AirCard 的 tunnel respring（al_device_respring）：要 LocalDevVPN 配对隧道，
  LiveContainer 里用不上。
- Camlo 的 respring 看门狗最后会打开 PosterBoard App 本身（界面动作），
  不是渲染触发器；可当作下一步的实验（注销后直接打开 PosterBoard App
  再看），不实现。
- Camlo 的 refreshGalleryCacheNonDestructive 和我们构建 #15 的 postWriteRefresh
  做的事完全一致（清 GalleryCache + 写偏好，PBF_LOCALE_DID_CHANGE=false），
  另有一个 `purgeLegacyMarkerDescriptors`（只删 Camlo 自己的旧标记描述符，
  与渲染无关）。

所以触发渲染的手段仍然只有：respring、杀掉 PosterBoard、清 GalleryCache +
写偏好——前两项靠用户操作，第三项我们已经在做。
