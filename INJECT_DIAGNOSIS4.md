# 排障报告 4：单帧能用、多帧不行——CAML 的 calculationMode 是 linear，真包全是 discrete

日期：2026-11-20（v16 构建 #16 实测后，用户点 tile + 设锁屏验证之后）
结论先行：**蓝 tile 真的能用**——用户点一张蓝 tile 进去点「添加」，锁屏已经设成了深蓝色。
写入 → 画廊列出 → 点进编辑器 → 设为锁屏，端到端全通。剩下的只有一个问题：
**多帧视频描述符渲染失败（黑 tile、点不动、无快照），连原样真包 Cipher 也一样。**

本次把 Cipher 的 CAML 逐字节解出来对照，抓到一个明确的、可修的差异：
**我们的 `caml()` 用 `calculationMode="linear"`，而 Cipher 的 26 个
CAKeyframeAnimation 全部是 `calculationMode="discrete"`，一个 linear 都没有。**
`contents`（CGImage）序列动画用 linear 模式做插值是未定义行为——图层在关键帧
之间显示空白；单帧（只有 1 个值）没有插值，所以不受影响，正好解释了
「单帧能用、多帧不行」。**已直接改了：`calculationMode` → `discrete`**（另顺手修了
`#00000` 笔误 → `#000000`），都在 `DescriptorBuilder.swift`。

但有一点必须诚实说明：**linear 解释不了 Cipher 本身也是黑的。** Cipher 的动画全是
discrete、包是完整的（47/47 资源引用都对得上），它也一样黑、一样没快照。所以除了
CAML 模式之外，还剩一个环境/渲染服务因素（或 tile 与描述符的对应关系假设有误）。
本报告把这两条线分开写：先修明确的 discrete，再用一个最小判别实验分清剩下那条线。

## 一、最新证据（2026-11-20 16:40–16:49 CST，v16 实测）

- 锁屏画廊「iPhone 13 Pro」区：8 张我们写的描述符全列出来了。
- 点进去试：**1、2、4、6、8 能点进去，3、5、7 是一片黑 tile，点了没反应。**
- 点进去的 5 张**全是蓝的**（纯蓝，无照片）。
- 磁盘上我们自己的描述符正好 8 张：5 张空白测试（`buildMinimalDescriptor`，1 帧纯蓝
  1080×1920，时长 1.0）+ 2 张变身视频（`buildDescriptor`，45 帧 886×1920，时长约 3 秒）
  + 1 张对照 Cipher（`ControlDescriptor` 写入的原样真 `.tendies` 包，390×844，iPhone 类）。
- 快照检查（`hasSnapshot`，查 `versions/<n>/RuntimeSnapshot-lock.atx`）：变身 16:23 和对照
  Cipher 都是「未生成」。测试描述符的快照状态未知。
- **用户 16:49 CST 实测：点一张蓝 tile 里的「添加」，真的设成了锁屏，主屏幕现在就是深蓝色。**
  端到端证明：写入 → 画廊列出 → 添加 → 设为锁屏，全通。
- 两类描述符的唯一区别：帧数（1 vs 45）、尺寸（1080×1920 vs 886×1920）、时长（1.0 vs 约 3.0）。
  元数据完全一样（`logicalScreenClass` 都是 `810w-1080h@2x~ipad`、`preferredProminentColor`
  都是 dark `#00000` / default `#FFFFFF`），CAML 结构也一样（同一个 `caml()` 函数），
  只是 `values` 里图片数量不同。

工作假设（本报告采用，但第三节会指出它的不确定性）：5 张能进的全是蓝的 = 5 张测试；
3 张黑的、点不动的 = 2 张变身 + 1 张对照。结论：**单帧静态描述符能渲染、能点、能进；
多帧视频描述符渲染失败、黑 tile、点不动——连原样真包 Cipher 也一样。**

## 二、Cipher 的 CAML 逐项对照（本次新解出来的地面实况）

方法：把 `ControlDescriptorData.swift` 里嵌的 80 个文件逐个 base64 解码
（`/tmp/cipher`，共 1,815,321 字节，与报告 3 一致），直接读
`7400.WWDC_2022_Background-390w-844h@3x~iphone.ca/main.caml`（184,606 字节，
CAPlayground 生成）。

### 2.1 关键帧动画对照表

| 项目 | 真 Cipher（Background main.caml） | 我们的 `caml()` | 结论 |
|---|---|---|---|
| `calculationMode` | **全部 26 个 CAKeyframeAnimation 都是 `discrete`** | **`linear`** | **核心差异，见第六节** |
| `keyTimes` | `contents` 动画**都没有** `<keyTimes>`（全文件只有 2 个 `<keyTimes>` 块，都属于一个 `position.y` 动画，值是整数 0/1） | 没有 | 一致：`contents` 动画不需要 keyTimes |
| `values` 数量（每个 `contents` 动画） | 3–5 张（共 10 个 `contents` 动画） | 45 张（视频）/ 1 张（最小测试） | 数量级差异，不是模式差异 |
| `duration`（`contents` 动画） | 0.5 / 1 / 3 秒 | 视频约 3 秒 / 最小测试 1.0 秒 | 同量级 |
| `beginTime` | `1e-100` | `1e-100` | 一致 |
| `repeatCount` | `inf` | `inf` | 一致 |
| `removedOnCompletion` | `0` | `0` | 一致 |
| `autoreverses` | 0 或 1（个别动画是 1） | 0 | 视频循环播放用 0 是对的 |
| 静态 `<contents>` | 有（第一张图） | 有（`assets/0.jpg`） | 一致 |
| `repeatDuration` | 有的动画是 `inf`，有的没有 | `0`（= 默认值，未设置） | 无实质差异 |
| `enabled="1"` / `highFrameRateReason="5"` | 多数动画带这两个属性 | 没有 | CAPlayground 的附加属性，不影响渲染 |
| `fillMode` | 仅 `position.y` 动画是 `both` | 没有 | 不影响 `contents` |
| 其他 `keyPath` | `position` / `position.x` / `position.y` / `transform.scale` / `hidden` / `opacity`（另有 360 个 `CASpringAnimation`，`mica_autorecalculatesDuration="1"`，管状态切换时的显隐/透明度） | 只有 `contents` | Cipher 是完整交互模板，我们是最小动画——结构差异，但不是黑 tile 的直接原因（见第七节） |
| 根层 `backgroundColor` | 有，`0.898 0.9059 0.9216`（浅灰） | 没有 | 见 2.3：即使动画全失败，Cipher 也该显示浅灰而不是纯黑 |
| 根层 `name` | `CAPlayground Root Layer` / `Root Layer` | Background 包根层叫 `_FLOATING`、Floating 包根层叫 `_BACKGROUND`（互换） | Placard 模板原样，只是名字 |
| `<states>` / `<stateTransitions>` | 每层都有（`LKState` 出现 1218 次，含各层的 states） | 只有根层有（Locked / Unlock / Sleep + 6 组切换） | 结构差异，不是黑 tile 的直接原因 |
| `<modules/>` / `<scriptComponents/>` | Floating 有 `<modules/>`，Foreground 有 `<scriptComponents/>` | 没有 | CAPlayground 的附加元素 |

### 2.2 上游原版核对：linear 是 Placard 模板原样，不是我们抄错了

- Placard `VideoWallpaper.swift`（841 行，main 分支，2026-11-20 取回）第 462 行：
  `calculationMode="linear"`，无 keyTimes——**与我们的 `caml()` 逐字一致**。
  所以 linear 是 Placard 模板本身的写法；但没有任何公开证据表明 Placard 的视频转换器
  在 iOS 27.0.1 的 iPhone 上能进画廊（诊断 2、3 已指出）。
- Camlo `PosterBoardBridge.swift`（1558 行，2026-11-20 取回）里**没有生成视频 CAML 的代码**
  （它只安装/归一化 `.tendies` 包，`healParameterizedCAMLIfNeeded` 只修 ParameterizedCA），
  所以 Camlo 没有"视频转描述符"的参考实现可以对照。
- Apple 的 CAKeyframeAnimation 文档 + 通用实践：`contents` 序列动画的标准写法就是
  `calculationMode = kCAAnimationDiscrete`（"makes the animation jump to each keyframe
  instead of blending, which is ideal for frame-based animations"）。Cipher（苹果 WWDC22
  模板经 CAPlayground 生成）26 个动画全是 discrete，与文档一致。

### 2.3 .ca 包与 Wallpaper.plist 对照（补充报告 3 的表）

| 项目 | 真 Cipher | 我们的描述符（视频 / 最小测试都一样） | 是不是区分因素 |
|---|---|---|---|
| `.ca` 包数量 | 3 个（Background + Floating + **Foreground**） | 2 个 | 不是：最小测试同样只有 2 个且能用 |
| Background `index.xml` 的 `documentWidth/Height` | 390 / 844（点） | 886 / 1920（视频）/ 1080 / 1920（最小测试）（像素） | 待定：见第七节原因 4 |
| Background `index.xml` 的 `documentResizesToView` | `false` | `true` | 不是：最小测试同样是 `true` 且能用 |
| Background `index.xml` 的 `loopingEnabled` / `loopEnd` | `true` / `+infinity` | `false` / `0.0` | 不是：最小测试同样是 `false`/`0.0` 且能用；但向 Cipher 对齐是低风险顺手项（见第九节） |
| Background `index.xml` 缺的键 | 没有 `interactiveShowsCursor` / `presentationShowsCursor` / `scalesToFitInPlayer` / `savesWindowFrame` / `unitsInPixelsInPlayer` | 都有这些键 | 不是：最小测试同样有这些键且能用 |
| Floating `index.xml` | 只有 `rootDocument: main.caml`（242 字节） | 完整版（3176 尺寸） | 不是：最小测试同样是完整版且能用 |
| Floating `main.caml` | CAPlayground 空根层 390×844 | 空白层 3176×3176 | 不是：最小测试同样是 3176 且能用 |
| Foreground `main.caml` | 空根层 390×844（`geometryFlipped="1"`，带 `<scriptComponents/>`） | ——（没有这个包） | 不是：最小测试同样没有且能用 |
| `Wallpaper.plist` 的 `foregroundAnimationFileName` | 有 | 没有 | 不是：最小测试同样没有且能用 |
| `Wallpaper.plist` 的 `appearanceAware` | `false` | `true` | 不是：最小测试同样是 `true` 且能用 |
| `Wallpaper.plist` 的 `contentVersion` | 无 | `2.01` | 不是：最小测试同样有且能用 |
| `Wallpaper.plist` 的 `preferredProminentColor` | 无 | dark `#00000`、default `#FFFFFF` | 不是：最小测试同样有且能用；但 `#00000` 是明确笔误，已顺手修掉（见第九节） |
| `userInfo` 的 `wallpaperRepresentingIdentifier` | 字符串 `"7400"` | 整数（递减 ID） | 不是：最小测试同样是整数且能用 |
| `suggestionMetadata.plist` | 有 | 没有 | 不是：最小测试同样没有且能用 |

**小结：除了 calculationMode（第六节）和尺寸（第七节原因 4），所有已知的模板差异，
最小测试和视频描述符是共有的——所以它们都不能解释「最小测试能用、视频不行」。
唯一同时满足「两类描述符不一样」和「与真包不一样」的，就是 CAML 的 calculationMode。**

## 三、两个排除性核查（本次新做）

### 3.1 Cipher 的资源引用全部对得上（47/47）

核查了 Cipher 三个 `.ca` 包的 `main.caml` 里所有 `src="assets/..."` 引用（Background 47 个
去重后引用，含 `%20` URL 编码的文件名）：**全部能在包里找到对应文件**。包里另有 11 个
未被引用的文件（`Root_Layer.js`、`darkmodeframe1/2.png`、`dot 1.png` 等），是多余文件，
无害。所以 Cipher 黑不是因为缺资源文件、文件名编解码问题或对照数据生成时丢了文件。

### 3.2 种子文件的平均色是青绿色，不是蓝色——蓝 tile 不是"底色 fallback"

种子 `RuntimeSnapshotMetadata-home/lock.plist`（`PBUIColorStatistics`）的平均色：
home 是 r 0.336 / g 0.494 / b 0.458，lock 是 r 0.345 / g 0.496 / b 0.468——都是
**偏青绿的中等色**，不是蓝色。而最小测试的 JPEG 是 RGB(0.1, 0.15, 0.35) 的深海军蓝。
所以画廊里看到的蓝 tile 是**真的蓝 JPEG 内容被渲染出来了**，不是系统拿种子平均色
当 fallback 画出来的。这就排除了"蓝 tile 只是底色，内容其实也没渲染"的怀疑：
**最小测试是真的能渲染的**。

## 四、机制：tile 是快照；黑 tile = 没有快照；点不动 = 加载失败

综合 Placard `WorseQuery.swift`（2026-11-20 取回，463 行）和三份诊断报告：

- Placard 的 `installedWallpapers` 找缩略图的顺序：先找描述符文件夹里的
  `RuntimeSnapshot-lock.atx`，再找 gallery-index 里的 `Resources/Composite.atx`；
  两个都没有时报错 "The system has not generated a readable Lock Screen snapshot yet."
  ——**画廊 tile 的素材就是快照**。系统画廊的 tile 同理：有快照就显示内容，没快照就
  显示黑块（tile 框 + 灰色时钟 09:41，与用户截图一致）。
- 快照是 PosterBoard 的快照服务加载 `.ca` 包、渲染 Background 层之后写进
  `versions/<n>/RuntimeSnapshot-lock.atx` 的。`hasSnapshot` 查的就是这个文件。
  变身 16:23 和对照 Cipher 都是「未生成」——**快照服务没有渲染它们**。
- 点 tile 没反应，说明不只是"没快照"：点进编辑器也要 PosterKit 加载这个描述符的
  `.ca`。加载失败 → 编辑器打不开 → 点了没反应。最小测试能点进、能设锁屏，
  说明它的 `.ca` 在 PosterBoard 进程里加载成功了。

所以"黑 tile + 点不动 + 快照未生成"三者是同一个根：**PosterBoard 的进程加载/渲染
这个描述符的 `.ca` 失败了**。问题就缩小到：`.ca` 里有什么东西，让加载/渲染失败，
而最小测试的 `.ca` 没有？

## 五、为什么 linear 模式会坏（机制解释）

`CAKeyframeAnimation` 的 `calculationMode` 决定关键帧之间怎么取值：

- `discrete`：每个关键帧的值按顺序轮流显示，不插值。`contents` 是 CGImage，
  只能这样——图片和图片之间没有"中间值"。
- `linear`：在相邻关键帧之间**插值**。对数字、点、颜色可以插值；对 CGImage
  没有插值算法，结果是未定义的——实际表现是图层在关键帧之间的时间里显示空白
  （插值结果为空），只在恰好落在关键帧的瞬间有图。
- 我们的视频动画：45 个值、时长 3 秒、没有 keyTimes、linear 模式。快照服务在某个
  时刻求值，几乎必然落在两个关键帧之间 → 插值结果为空 → 图层透明 → 渲染出来是
  空白 → 快照服务认为渲染失败（或写出空白快照后被当成无效），最终 `RuntimeSnapshot-lock.atx`
  不存在 → 黑 tile。
- 更关键的是，这个动画是常驻的（`beginTime="1e-100"`、`repeatCount="inf"`、
  `removedOnCompletion="0"`）：它一旦挂上，就一直覆盖静态 `<contents src="assets/0.jpg"/>`。
  所以即使静态首帧是好的照片，也永远显示不出来——动画的"空白"把它盖住了。
- 最小测试为什么不受影响：`values` 里只有 1 个值，没有"两个关键帧之间"，
  也就没有插值；linear 和 discrete 在这种情况下行为完全一样。静态内容正常显示。
  这就精确解释了「单帧能用、多帧不行」。

Apple 文档的原话（CAKeyframeAnimation 参考）：`kCAAnimationDiscrete` 是
"Each keyframe value is used in turn, no interpolated values are calculated"；
而帧动画的标准写法就是 discrete + keyTimes（keyTimes 对 `contents` 动画不是必需的——
Cipher 的 10 个 `contents` 动画都没有 keyTimes；没有 keyTimes 时 discrete 模式把
关键帧均匀分摊，45 帧 / 3 秒 = 每帧 1/15 秒，正好就是 15fps 的抽帧节奏）。

## 六、Cipher 黑的悖论：linear 解释不了全部

诚实地讲，第五节只解释了我们自己的视频描述符，解释不了 Cipher：

- Cipher 的 10 个 `contents` 动画全是 `discrete`，没有 linear；包是完整的
  （47/47 资源引用对得上）；根层还有浅灰 `backgroundColor`——即使所有动画都失败，
  根层也该显示浅灰，而不是纯黑。
- 但 Cipher 在这台设备上同样是黑 tile、点不动、快照未生成。

所以一定还有第二条线。两条可能（按可能性排序）：

### 可能 A：tile 与描述符的对应关系假设有误（画廊排序未知）

- "黑的 3 张 = 2 张变身 + 1 张对照"这个映射，建立在"5 张能进的全是蓝的"和 5:3 的
  数量吻合上。但画廊在「iPhone 13 Pro」区里的**排序规则未知**。
- 如果画廊按时间或 identifier 单调排序（Camlo 的递减 ID 机制暗示画廊按 identifier
  降序排，新壁纸在前；我们的 ID 随写入时间递减，所以降序 = 最早写的在前）：
  顺序是 04CC11AE（测试）、变身 15:46、E8DA120A（测试）、2B8688BC（测试）、
  4355A55E（测试）、变身 16:23、对照 Cipher、F0A76E67（测试），
  黑的 3、5、7 号就是 E8DA120A、4355A55E、**对照 Cipher**——是 2 张测试 + 1 张对照
  的混合，不是干净的视频/测试二分。
- 如果按 identifier 升序（最新写的在前）：黑的 3、5、7 号是变身 16:23、2B8688BC（测试）、
  变身 15:46——同样是混合。
- 只有画廊按**非单调顺序**（例如直接枚举目录的 readdir 顺序，APFS 上基本是任意顺序）
  排列时，"黑的 = 2 变身 + 1 对照"才成立。
- 注意：按单调排序时，黑的集合里总有一张测试——这与"最小测试都能用"矛盾，
  除非那两张测试恰好是别的什么原因黑的（目前没有这样的原因）。而按"全蓝"反推：
  单调排序下两张变身会在"能进的 5 张"里，它们点进去该显示照片而不是全蓝——
  除非变身在编辑器里也渲染失败、显示了蓝底（目前没有证据）。
- **结论：映射的不确定性真实存在，不能 100% 认定黑的 3 张就是视频。**
  判别实验（第十节）要顺带解决它：新写的单帧照片 tile 自带可识别的内容（照片），
  写完后看它出现在第几位、总数变成几张，就能反推画廊的排序规则。

### 可能 B：快照服务在该环境下对多帧动画渲染失败（环境因素）

- 即使动画是正确的 discrete，Cipher 在这台设备上也没生成快照。可能的子原因：
  - **PosterBoard 没真正重启 / 渲染队列没跑**：快照只在 PosterBoard 重启扫描时
    生成。用户 16:35 说"做了一个重启"，但没分清是 respring 还是整机重启；
    NeoSpring 的 respring 未必重启 PosterBoard 守护进程。测试描述符写得早
    （15:19–15:51），可能在某次重启周期里被渲染过；视频/对照写得晚
    （16:23–16:24），之后 PosterBoard 可能还没跑过渲染。
  - **快照服务读不到文件**（原因 4，v17 的权限对照就是为这个准备的）：快照渲染
    可能跑在另一个 XPC 服务/用户下。如果我们的文件权限/所有权与苹果自带的不一样，
    渲染会静默跳过。但同一次写入、同一种权限，最小测试能渲染、视频不能——
    权限差异很难解释这种区分，除非快照服务对多帧动画要读更多文件（45 个 JPEG）
    而其中某个读失败。v17 的权限对照能直接看到。
  - **iOS 27.0.1 的快照服务对复杂 .ca 有问题**：Cipher 的 CAML 是 184KB、数百个图层、
    360 个 spring 动画、CAReplicatorLayer——渲染成本远高于最小测试。如果快照服务
    有单张超时/内存上限，复杂包会失败。但 Cipher 是苹果模板衍生的正常包，
    在 iOS 26 上经 Placard 安装是能用的；27.0.1 是否改了快照管线，未知。
  - **终极环境对照**：把同一份 Cipher 描述符用 Placard/Camlo 在该设备上装一次，
    看快照生不生成（诊断 3 第十节已提过）。如果 Placard 装的也黑，问题与我们的
    写入路径完全无关，是设备/系统版本层面的；如果 Placard 装的能显示，问题在我们的
    写入路径（权限/收尾动作）。

## 七、按可能性排序的原因清单（更新）

### 原因 1（最可能，已修）：`calculationMode="linear"`，`contents` 动画求值失败

- 证据：Cipher 26 个动画全是 discrete，我们是 linear；Apple 文档明确规定
  `contents` 序列动画用 discrete；单帧（1 个值）无插值所以不受影响，
  精确匹配「单帧能用、多帧不行」。
- 修复：已改成 `discrete`（第九节）。不补 keyTimes（Cipher 也没有，均匀分摊正好是 15fps）。

### 原因 2（高可能）：快照服务在该环境下没渲染多帧描述符

- 证据：Cipher discrete 也黑、也无快照；linear 解释不了它。
- 子原因按可疑程度：(a) PosterBoard 没真正重启/渲染队列没跑（用户 16:35 的"重启"
  性质不明；测试写得早、视频写得晚，时间差可能正好卡在两次渲染周期之间）；
  (b) 快照服务读不到文件（等 v17 权限对照）；(c) iOS 27.0.1 快照服务对复杂 .ca
  超时/失败。
- 验证：v17 权限对照 + respring 后划掉 PosterBoard 再看快照；终极验证是 Placard/Camlo
  同机对照安装。

### 原因 3（中可能）：tile 与描述符的对应关系假设有误

- 证据与分析见第六节可能 A。画廊排序规则未知，单调排序下黑的 3 张是混合。
- 验证：判别实验（第十节）——新 tile 的照片内容自带身份，写完后看它排第几位、
  总数变几张，反推排序规则。

### 原因 4（低–中）：帧尺寸 886×1920

- 最小测试是 1080×1920 且能用，视频是 886×1920；但 Cipher 是 390×844 也黑，
  所以尺寸单独解释不了全部。尺寸仍是未排除变量，判别实验的探针 B 直接测它。
- 注意：886×1920 是 Placard 的设备原生像素算法（iPhone 13 Pro native 1170×2532
  按比例缩到长边 1920），本身是有道理的；改尺寸不是首选，先测。

### 原因 5（低）：`index.xml` 的循环/尺寸 flags 与真包不一致

- `documentResizesToView: true`（真包 `false`）、`loopingEnabled: false` /
  `loopEnd: 0.0`（真包 `true` / `+infinity`）。但最小测试同样是这些值且能用，
  所以不是区分因素。向 Cipher 对齐是低风险顺手项，可与下次构建一起做（第九节）。

### 原因 6（低）：缺 Foreground 包 / `appearanceAware: true` / `contentVersion: 2.01`

- 最小测试同样缺 Foreground、同样 `appearanceAware: true`、同样有 `contentVersion`，
  且能用。所以都不是区分因素。补 Foreground 包仍是"向真包对齐"的候选，
  但优先级排在 discrete 修复和判别实验之后。

### 原因 7（低，已修掉一半）：`preferredProminentColor` 的 `"#00000"` 是 5 位非法十六进制

- 最小测试同样有它且能用，所以不是黑 tile 的原因。但它确实是笔误（Placard 模板原样），
  已顺手改成 `"#000000"`（第九节）。

### 原因 8（已排除）：资源文件缺失

- Cipher 47/47 引用对得上（第三节）；我们的视频帧由代码生成，不会缺。

### 原因 9（已排除）：种子平均色导致蓝 tile

- 种子平均色是青绿色（r 0.34 / g 0.49 / b 0.46），不是蓝色；蓝 tile 是真的蓝 JPEG
  内容（第三节）。

### 原因 10（已排除大半）：identifier / 排序 / 位置 / 索引登记

- 见诊断 2、3：三家都用非 7400 的 ID；位置与 Camlo 一致（最大版本 61）；
  镜像容器在该设备上不存在；gallery-index 不登记（仍然不要实现）。

## 八、渲染失败最可能发生在哪个环节（任务 3 的判断）

把链路拆开：

1. **画廊 tile 渲染时直接加载 `.ca` 失败**——不太可能是主环节。tile 的素材是快照
   （第四节），画廊本身不直接渲染 `.ca`；它只读快照文件。黑 tile 的直接原因是
   "没有快照"，不是"画廊加载失败"。
2. **快照服务渲染失败导致 tile fallback 成黑块**——**最可能的主环节**。快照服务要加载
   `.ca`、求值动画、渲染一帧、写 `.atx`。我们的视频在"求值动画"这一步就失败了
   （linear 插值 CGImage 无结果）；Cipher 在"加载/渲染"这一步失败了
   （原因待查，可能是渲染队列没跑、权限、或复杂包超时）。
3. **点 tile 没反应**是同一个根的另一面：编辑器也要加载 `.ca`。如果 `.ca` 在
   PosterBoard 进程里加载失败（动画求值失败也算一种加载失败——图层树实例化后
   没有有效内容），编辑器打不开。最小测试的 `.ca` 加载成功，所以能点进、能设锁屏。

所以修复的重心在**让快照服务能成功渲染**，而不是改画廊的列出逻辑（列出已经通了，
8 张全在）。

## 九、最小修复方案（按可能性排序）

### 已做的改动（本地代码，`BizhiGongfang/Inject/DescriptorBuilder.swift`，只改了这一个文件）

**改动 1（主修复）：`caml()` 里 `calculationMode="linear"` → `calculationMode="discrete"`**
（第 464 行）。理由：

- Cipher 的 26 个 CAKeyframeAnimation 全是 discrete；Apple 文档规定 `contents`
  序列动画用 discrete；这是唯一同时满足「两类描述符不一样」和「与真包不一样」的差异。
- 不补 keyTimes：Cipher 的 `contents` 动画也没有 keyTimes；discrete + 无 keyTimes =
  关键帧均匀分摊，45 帧 / 3 秒正好是 15fps。
- 零风险：最小测试只有 1 个值，discrete 和 linear 行为完全一样，不会破坏已能用的情况。
- 其余动画属性不动：`beginTime="1e-100"`、`duration`、`repeatCount="inf"`、
  `removedOnCompletion="0"`、`autoreverses="0"` 都与 Cipher 一致；`repeatDuration="0"`
  是默认值（未设置），不用改。

**改动 2（顺手笔误修正）：`makeDescriptorMetadata()` 里 `"#00000"` → `"#000000"`**
（第 332 行）。理由：5 位十六进制不是合法颜色值（Placard 模板笔误）；改成 6 位黑。
**明确说明：这不是黑 tile 的原因**（最小测试同样有 `#00000` 且能用），只是顺手把
明确的错误值修掉，避免严格解析器在读 prominent color 时出问题。

两处改动已验证：括号平衡 0:0:0；文件里不再有 `linear`；`discrete` 出现 1 次。
未改其他文件，未动 `ControlDescriptor.swift`（对照包是原样真包，不该动）。

### 下一步候选（按顺序，等判别实验 + v17 结果再决定做哪项）

1. **先验证 discrete 修复**：编一版（只含上面两处改动），做一张变身壁纸写入，
   respring → 划掉 PosterBoard → 看第 7 步快照 + 画廊 tile。
   快照生成 / tile 显示照片 = 修好了；仍黑 = 原因 2（环境）是主因，继续第 2 项。
2. **v17 权限对照 + PosterBoard 重启确认**（已备好，见诊断 3 第十节）：看文件权限对照
   区；确认 respring 后划掉 PosterBoard 再看快照。
3. **向 Cipher 对齐 index.xml**（低风险打包项）：`documentResizesToView: false`、
   `loopingEnabled: true`、`loopEnd: +infinity`。单项都不是区分因素，打包做一次验证即可。
4. **补 Foreground 空包 + `foregroundAnimationFileName`**（向真包对齐）：Foreground 的
   main.caml 是空根层（390×844，`geometryFlipped="1"`，带 `<scriptComponents/>`），
   照 Cipher 的抄一份（尺寸换成我们的输出尺寸）。成本低，但同样不是区分因素。
5. **`appearanceAware` 改 `false`、删 `contentVersion`**（向真包对齐）：同上，打包验证。
6. **尺寸实验**：如果判别实验指向尺寸，把 `devicePortraitOutputSize()` 改回
   1080×1920（最小测试的尺寸），或全套改点尺寸 390×844 + iPhone 类
   （文件名、Wallpaper.plist、index.xml、CAML 坐标一起改，见诊断 3 原因 1）。
7. **终极环境对照**：Placard/Camlo 同机装一次 Cipher，看快照生不生成。
   如果也黑，问题与我们的写入路径完全无关，是设备/系统版本层面的。

### 明确不做

- 不补 keyTimes（Cipher 没有；均匀分摊正好是抽帧节奏）。
- 不往 gallery-index.json 里登记（诊断 2、3 已证伪，仍然不做）。
- 不预生成快照 `.atx`（它是系统渲染器生成的专有格式，伪造不了；Camlo 归一化时
  会清掉外来的 `.atx`，说明系统自己会重新生成）。
- 不改写路径、不改 `ControlDescriptor.swift`。

## 十、判别实验：单帧真照片（最小设计）

### 目的

一次实验同时回答两个问题：

1. **动画问题，还是照片内容/尺寸问题？**（单帧真照片能不能渲染）
2. **黑的 3 张到底是不是视频？**（新 tile 自带可识别的照片内容，写完后看它排第几位、总数变几张，反推画廊排序）

### 实现（一个构建，诊断页加一个按钮；只动 `DescriptorBuilder.swift` + `InjectDiagnosticsView.swift`）

- 新增 `DescriptorBuilder.buildSinglePhotoDescriptor(photo: UIImage, size: CGSize, in workspace: URL)`：
  走和 `buildMinimalDescriptor` **完全相同的路径**（同一 `makeDescriptorMetadata`、
  同一 `caml()`、同一 `indexXML`、同一 `blankCAML`、同一 `seedDescriptorFiles`），
  只把那一帧换成一张真照片（用 PhotoPicker 让用户现场选一张，或复用变身编辑器里
  已选的第一张照片；照片按 `drawAspectFill` 的方式裁成目标尺寸后存成 JPEG 0.7）。
- 两个探针（同一批写入，先后各写一张）：
  - **探针 A：单帧真照片，1080×1920**——与最小测试**完全一致，只换帧内容**
    （固蓝 JPEG → 真照片）。隔离"帧内容"这一个变量。
  - **探针 B：单帧真照片，886×1920**——与视频**完全一致，只换帧数**
    （45 帧 → 1 帧）。隔离"帧数"这一个变量，同时测尺寸。
- 诊断页加按钮「写入单帧照片测试」（复用 `InjectFlow.injectMinimalTest` 的写入路径，
  走同一 `writeDescriptors` + `postWriteRefresh`）；UUID 记下来，第 7 步核对里
  一起显示快照状态；诊断页「清理测试壁纸」能删掉它们。

### 步骤（用户操作）

1. 装新版（discrete 修复已在内，不影响本实验的判断——实验测的是单帧，discrete/linear
   对单帧没区别；但为避免混淆，最好先用**当前 v16 同款代码 + 只加实验按钮**编一版，
   或直接用含 discrete 修复的新版——两种都可以，因为单帧不受 calculationMode 影响）。
2. 跑直写诊断，记下第 5 步张数（应为 13：原来 12 张 + 探针 A；写探针 B 后是 14）。
3. 点「写入单帧照片测试」写探针 A → respring → 划掉 PosterBoard → 进画廊，
   找新 tile（照片内容自带身份，不会和蓝 tile 混淆），记下它在第几位、能不能点、
   点进去是什么。
4. 同样写探针 B，再看一次。
5. 跑直写诊断，看第 7 步：探针 A / B 的快照是"已生成"还是"未生成"。

### 结果解读

| 结果 | 解读 | 下一步 |
|---|---|---|
| A 是照片 tile、能点、快照已生成；B 也是照片 tile | 静态真照片能渲染，尺寸没问题。**问题就是多帧动画**（linear 已修，下一版验证 discrete 是否解决） | 编 discrete 修复版，做变身壁纸验证 |
| A 是照片 tile；B 是黑的、点不动、快照未生成 | 动画没问题，**尺寸 886×1920 有问题** | 把输出尺寸改回 1080×1920（或全套改点尺寸 390×844 + iPhone 类）再测 |
| A 和 B 都是黑的、点不动、快照未生成 | 连单帧真照片都不渲染，**问题不在动画**，在照片内容（JPEG 编码/EXIF/色彩空间）或环境（快照服务） | 查 v17 权限对照；换一张图（例如用最小测试同款生成方式画一张带图案的图）再试，区分"照片文件"还是"渲染服务" |
| A 和 B 都是蓝 tile（纯蓝、无照片） | 静态内容没画出来，tile 只显示了底色。**渲染服务本身有问题**（环境），不是动画 | 重点查原因 2：PosterBoard 重启确认、权限对照、Placard 同机对照 |
| A 或 B 出现后总数不是 13/14，或新 tile 的位置能反推排序 | 排序规则有线索：结合黑 tile 的位置，确认黑的 3 张到底是不是视频 | 若黑的不是视频，回到第六节可能 A 重新分析 |

### 实验成本

- 代码：1 个新函数（约 30 行，复用现有路径）+ 诊断页 1 个按钮 + 第 7 步 2 行显示。
- 构建：1 次。用户操作：两次写入 + 两次进画廊，总共约 5 分钟。
- 注意：实验前先把诊断页的测试描述符清一清（诊断页已有清理按钮），避免蓝 tile
  越来越多、数不清楚；但不要删变身 15:46 / 16:23 和对照 Cipher（它们是本轮的
  对照组）。

## 十一、来源清单

- 本地：`BizhiGongfang/Inject/DescriptorBuilder.swift`（`caml` 第 464 行已改
  `discrete`；`makeDescriptorMetadata` 第 332 行已改 `#000000`）、
  `BizhiGongfang/Inject/ControlDescriptor.swift`（未动）、
  `BizhiGongfang/Inject/PosterBoardStore.swift`（`writeDescriptors`、`hasSnapshot`）、
  `BizhiGongfang/Inject/ControlDescriptorData.swift`（80 个文件，本次逐个解码核对）。
- 地面实况：`/tmp/cipher`（本次解码）：Background `main.caml` 184,606 字节（26 个
  CAKeyframeAnimation 全 discrete；10 个 `contents` 动画，3–5 个值，无 keyTimes）、
  Background `index.xml`（390/844，`documentResizesToView: false`，`loopingEnabled: true`，
  `loopEnd: +infinity`）、Floating `main.caml`（2,709 字节，CAPlayground 空根层）、
  Foreground `main.caml`（1,146 字节，空根层，`geometryFlipped="1"`）、
  `Wallpaper.plist`（`appearanceAware: false`，无 `contentVersion` / `preferredProminentColor`）、
  资源引用核查 47/47 对得上、种子平均色 home r0.336/g0.494/b0.458、lock r0.345/g0.496/b0.468。
- Placard（frs0n/placard，main 分支，2026-11-20 取回）：`placard/VideoWallpaper.swift`
  （841 行，第 462 行 `calculationMode="linear"`，无 keyTimes——与我们的模板逐字一致）、
  `placard/Exploit/WorseQuery.swift`（463 行，`installedWallpapers`：缩略图来源
  `RuntimeSnapshot-lock.atx` / 索引 `Resources/Composite.atx`；没有时报错
  "The system has not generated a readable Lock Screen snapshot yet."）。
- Camlo（kianuni/Camlo，main 分支，2026-11-20 取回）：`Camlo/Bridge/PosterBoardBridge.swift`
  （1558 行，无生成视频 CAML 的代码；`healParameterizedCAMLIfNeeded` 只修 ParameterizedCA）。
- Apple 文档：CAKeyframeAnimation 参考（`calculationMode` / `keyTimes`；
  `kCAAnimationDiscrete` = "Each keyframe value is used in turn, no interpolated values
  are calculated"；`contents` 帧动画的标准写法是 discrete）。
- 前序报告：`INJECT_DIAGNOSIS2.md`（删除问题：assetManifest + 种子 + 收尾动作）、
  `INJECT_DIAGNOSIS3.md`（第 1–8 节对照表与结论、第 10 节构建 #17 准备：权限对照 + 偏好 false）。
