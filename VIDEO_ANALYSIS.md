# 录屏逐帧分析：用户以前做成的那张动态壁纸

来源：用户 2026-11-20 17:27 CST 发的录屏
`workspace/user/media_library/video/57/57918f9e707ba8ca20710b242d7dfbb7d9d31f6cd5e5bc339b4306ab3b73aa98.mp4`
（2.0 秒，61 帧，720×1558，HEVC）

## 逐帧测量的结果

从录屏抽帧（每 0.5 秒一帧）做像素差：

| 区域 | f01→f02 平均像素差 | f02→f03 平均像素差 |
|---|---|---|
| 地球（手里那颗，x 10–140, y 370–510） | 38.0（约 50% 像素变化 >20） | 39.2（约 60%） |
| 顶部红玫瑰区（无图标的背景） | 9.8 | 9.9 |
| 女孩脸部 | 13.8 | 14.4 |

地球在转（大陆图案逐帧换位置），红色光 streak 也在动；图标本身不动。
录屏全程是**主屏幕**（带 app 图标和程序坞），最后 0.5 秒滑出控制中心。

## 结论

1. 这是一张真正的动态 PosterBoard 壁纸（.tendies/Mica），不是 Live Photo。
   Live Photo 只在锁屏动，**主屏幕上永远不动**。主屏幕上地球持续旋转，说明
   PosterBoard 的多帧渲染管线在这台 iPhone 13 Pro、iOS 27.0.1 上是通的。
2. 所以问题不在“这台手机渲不出多帧壁纸”，而在我们写进去的描述符/写入方式。
   这和构建 #16 对照测试（原样 Cipher 也不渲染）放在一起看，指向写入路径或
   描述符内容，而不是设备能力。
3. 这张壁纸现在就是正在用的壁纸 → 它的描述符此刻就在 PosterBoard 容器里。
   下一步最有决定性的检查：用诊断工具读出**这张正在用的壁纸的描述符**，
   逐项对照我们的——logicalScreenClass、包数量（有没有 Foreground）、
   CAML calculationMode、帧尺寸、快照文件（RuntimeSnapshot-lock.atx 是否存在）、
   权限/扩展属性。不用找到那个 App 也能拿到答案。
   （建议在 #19 测完之后再做，别在 #19 之前又叠一版。）

## 主屏幕上那两个 App 不是壁纸 App

录屏第一页可见：Grok、Hark、Claude、Gemini、ChatGPT、Muse、Wabi（角标 2）、
翻译、GitHub；程序坞：备忘类、导航、Safari、F。

- **Wabi**：个人软件平台，用对话生成 mini-App（三个圆点图标就是它的
  “小球”品牌元素），不是壁纸 App。
- **Hark**：Hark Pro，Brett Adcock 的 AI 助手（2026-10-06 发布），不是壁纸 App。

所以那个 App 不在这一页主屏幕上。更可能的去处：

- **LiveContainer 的客 App 列表**——经 LiveContainer 装的 App 不会出现在主屏幕，
  Placard / Pocket Poster / AirCard 这类侧载 App 都在里面；
- App 资源库搜“壁纸 / wallpaper / live”；
- 设置 → 通用 → iPhone 储存空间，按 App 列表翻；
- App Store → 已购项目里找壁纸类 App。
- 也可能根本不是用户自己装的 App：Placard 自带社区壁纸目录，这张动漫图
  很像目录里的内容——如果是经 Placard 目录装的，说明 Placard 的**导入路径**
  （原样 .tendies 包）是通的，问题就只剩我们**从头生成描述符**这一步。

## 走不同路子的两个对照 App（Camlo 不算：它和我们同一条 worse_query 路）

### AirCard-iOS v1.3.2（首选对照）

- 仓库：https://github.com/Mak5er/AirCard-iOS ，Releases 里找 v1.3.2 的 IPA
- 明确支持 iOS 27.0–27.0.1，支持 LiveContainer 安装
- **写入机制完全不同**：配对文件 + AirTraffic/airlift 漏洞经 LocalDevVPN，
  不是 worse_query 沙盒逃逸；iOS 27 上可本机配对（设置 → 隐私 → 开发者模式），
  或从 LiveContainer 里 SideStore 的 Documents 导入 ALTPairingFile
- 导 .tendies 安装；v1.3.2 修了“装好的壁纸从锁屏画廊消失”的问题
- 判读：AirCard 装的视频壁纸显示成照片 → worse_query 这条路是问题所在；
  AirCard 也黑 tile → 问题在描述符内容/渲染，不在写入路径
- 注意：别升级到 27.2 beta 3+（airlift 已被封）；27.0.1 正好在支持范围里

### Pocket Poster v3.2.2（备选）

- 原仓库 https://github.com/lengfeng222/Pocket-Poster ；iOS 18–27 beta 4 能用的
  分支是 JordsTechStuff/Pocket-Poster（13.7 MB IPA）；聚合页 https://nugget.host/ipa
- 另一套代码 lineage（PosterRestore / Nugget），导社区 .tendies 安装
- 代价：首次配置要在电脑上跑 Nugget 取 App Hash/UUID——用户正好有 Windows
  电脑 desktop-881vjmk，Muse 可经 Tailscale SSH 操作，这一步做得了

## #19 状态

构建 #19 的 5 文件 zip 已于 2026-11-20 17:14 CST 发给用户自行上传，
尚未传。测试顺序不变：先看诊断权限是不是 777 → 变身壁纸一键写入看快照 →
点「静态写入」看两个探针 tile。
