# 壁纸工坊

免费开源的 iPhone 壁纸制作工具：自己做互动锁屏壁纸，导出为 Live Photo，或者一键直接写入锁屏画廊。

## 功能

- **我的壁纸**：已制作的壁纸列表，预览、播放动态、重新保存到相册、分享、删除；已写入锁屏的会标"已写入锁屏"，可以在详情页只删锁屏里的那一张
- **变身壁纸**：选两张照片（锁定画面 / 解锁后画面），滑块实时预览变身效果（交叉淡化 / 滑动切换），导出 3 秒 Live Photo 或一键写入锁屏
- **景深壁纸**：选一张照片，倾斜手机实时预览视差效果，导出 3 秒 Live Photo 或一键写入锁屏
- **视频壁纸**：从相册选一段视频，裁剪到 3 秒，导出 Live Photo 或一键写入锁屏
- **一键写入锁屏**：把做好的壁纸直接写进系统锁屏画廊，不用经过相册（iOS 26.0 – 27.3 beta 1 可用，27.3 beta 2 起苹果已封堵）。"我的壁纸"右上角有"直写诊断"，可以一步一步检查直写通不通
- **直写诊断**：检查系统版本、App Group、PosterBoard 容器、读写权，并写一个空白描述符做测试

## 怎么用

1. 打开「制作」，选一种壁纸。
2. 选照片（或视频），在应用内预览效果。
3. 点「导出 Live Photo 到相册」，或者点「一键写入锁屏」。
4. 导出的话：去「照片」打开这张 Live Photo → 点分享 → 「设为墙纸」→ 打开 Live Photo，设为锁屏壁纸。
5. 一键写入的话：去多任务界面把 PosterBoard（锁屏）划掉，再长按锁屏点 +，在画廊里找到刚写入的壁纸添加即可。

⚠️ **别升级系统**：一键写入只在 iOS 26.0 – 27.3 beta 1 上可用，苹果在 27.3 beta 2 堵了这个口子。升级后一键写入会永久失效（只能导出 Live Photo），请关闭自动更新。

## 怎么编译（用 GitHub Actions，不用 Mac）

1. 把这个仓库传到 GitHub（新建一个仓库，把这些文件推上去）。
2. 打开仓库的 **Actions** 标签页，等 `Build iOS App` 跑完。
3. 跑完后在页面下方 **Artifacts** 里下载 `BizhiGongfang-unsigned-ipa`，得到 `BizhiGongfang-unsigned.ipa`。

## 怎么用 Codemagic 编译

1. 把仓库传到 GitHub（或 GitLab、Bitbucket）。
2. 打开 [codemagic.io](https://codemagic.io)，用传代码的账号登录，Add application 选这个仓库。
3. Start new build，选 `ios-unsigned`，跑完在 **Artifacts** 里下载 `BizhiGongfang-unsigned.ipa`。

## 怎么免费装到 iPhone 上

编出来的 IPA 是**未签名**的，不能直接装，需要用你的免费 Apple ID 重新签名。有两个常用办法：

### 办法一：AltStore（推荐）

1. 电脑上装 [AltStore](https://altstore.io/)（Windows 或 Mac 都可以），手机上装 AltStore。
2. 把 `BizhiGongfang-unsigned.ipa` 传到手机（微信发给自己、AirDrop、网盘都行）。
3. 在手机上用 AltStore 打开这个 IPA，输入你的 Apple ID 和密码（只用来签名，不会上传到别处），装好就能用。
4. 免费账号签名的 App 每 7 天要刷新一次，AltStore 会在同一 WiFi 下自动帮你续。

### 办法二：SideStore

和 AltStore 类似，但不需要电脑常开，适合不想总开电脑的人。见 [SideStore 官网](https://sidestore.io/)。

### 有 Mac 的话

在 Mac 上装 Xcode，打开项目（`xcodegen generate` 生成 `BizhiGongfang.xcodeproj` 后打开），把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你自己的（比如 `com.你的名字.wallpaperstudio`），选你的 Apple ID 做签名，直接点运行装到手机上。

## 在自己电脑上编译

需要一台 Mac + Xcode：

```bash
brew install xcodegen
xcodegen generate
open BizhiGongfang.xcodeproj
```

## 文件说明

```
BizhiGongfang/
  BizhiGongfangApp.swift       App 入口
  ContentView.swift            底部 Tab：我的壁纸 / 制作
  Models/WallpaperStore.swift  已制作的壁纸（本地保存）
  LivePhoto/
    LivePhotoMetadata.swift    Live Photo 配对元数据（content identifier、still-image-time）
    VideoRenderer.swift        AVAssetWriter 逐帧画视频（H.264 MOV 1080x1920 30fps）
    VideoCropper.swift         视频裁剪（AVAssetExportSession + 直通重封装）
    LivePhotoExporter.swift    保存 Live Photo 到相册
    PhotoPicker.swift          相册选择器
    ShareSheet.swift           系统分享菜单
  Inject/                      一键写入锁屏（直写，GPL-3.0，见下）
    WorseQuery.h / WorseQuery.m
                               沙盒逃逸核心（移植自 forcequitOS/worse_query，经 Placard 改进的备份恢复版）
    ContainerEnumeration.h/.m  枚举系统容器（移植自 Placard）
    GestaltAppGroupResolver.h/.m
                               从签名里读 App Group（移植自 Placard）
    GroupRoot.h / GroupRoot.m  LiveContainer 替身 App Group 修正 + 系统 build 号判断（自己写）
    PosterBoardStore.swift     找 PosterBoard 容器、读写描述符
    DescriptorBuilder.swift    视频抽帧生成 PosterBoard 描述符（.ca CAML 包）
    InjectSupport.swift        版本门禁 + 共用注入流程
    InjectButton.swift         三个编辑器共用的"一键写入锁屏"按钮
    InjectDiagnosticsView.swift 直写诊断页（一步一步检查）
  Views/
    WallpaperListView.swift    我的壁纸列表（含直写诊断入口、已写入锁屏标记）
    WallpaperDetailView.swift  壁纸详情：播放动态、保存、分享、删除、删锁屏里的壁纸
    MakeView.swift             制作页：三种壁纸入口
    MorphEditorView.swift      变身壁纸制作
    DepthEditorView.swift      景深壁纸制作（陀螺仪预览）
    VideoEditorView.swift      视频壁纸制作
  BizhiGongfang.entitlements  App Group 权限（group.com.wallpaperstudio.app，直写必需）
  BizhiGongfang-Bridging-Header.h
                               ObjC 直写代码的桥接头文件
project.yml                    xcodegen 配置
LICENSE                        GPL-3.0 许可证全文
.github/workflows/ios.yml      GitHub Actions 编译流程
codemagic.yaml                 Codemagic 编译流程
```

## 原理说明

本应用导出的是系统标准的 **Live Photo**（一张静态图 + 一段 3 秒视频，靠同一个 content identifier 配对）。设为锁屏壁纸后，iOS 会在按压屏幕或解锁时播放这段视频，看起来就像会动的互动壁纸。

**一键写入锁屏**是另一条路：用 worse_query 沙盒逃逸（App Group 权限 + 把 Library/Caches 换成指向 PosterBoard 容器的符号链接，让系统签发读写权），把做好的壁纸描述符（视频抽帧 + CAML 动画包）直接写进锁屏画廊。不越狱，不是内核漏洞。只在 iOS 26.0 – 27.3 beta 1 上可用（苹果在 27.3 beta 2 封堵），且 App 必须用带 App Group 的签名安装（SideStore / AltStore 可以，Sideloadly 不行）；在 LiveContainer 里跑时，用的是 LiveContainer 自己的签名和 App Group。

第一版的一键写入是"视频循环播放"：变身、景深、视频三种壁纸都当 3 秒视频处理。真正的"上滑解锁跟手变身"（两张图随解锁进度渐变）是下一阶段。

## 许可证

本项目是 **GPL-3.0** 开源（见 LICENSE 文件）。一键写入功能直接用了 GPL-3.0 的代码：

- forcequitOS/worse_query（沙盒逃逸核心）
- frs0n/placard（描述符生成、安装流程、容器枚举、App Group 解析）

按 GPL-3.0 的要求，整个项目（包括原来那部分）都必须同样 GPL-3.0 开源。

## 诚实说明

这份代码**没有在真机上编译和实测过**（作者这边没有 Mac，也没有 iPhone）。如果你编译时报错、或者导出的 Live Photo 配对不上、设不成壁纸，请把报错截图或文字发回来，我会修。
