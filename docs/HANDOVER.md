<!-- docs/HANDOVER.md -->
# LocalRoll 交接文档（2026-10-16 晚，最新 beta.51）

> 新窗口请**先完整读完本文**，再按需读《开发进度》（只记到 beta.38）、《总体规划-当前版》《路线图-拓展方向》。本文覆盖 beta.39 – beta.51 的全部改动、工作约定和下一步计划。

---

## 0. 一句话现状

- 电脑端（Windows）、iPhone、Android 三端都在 **v0.1.0-beta.51**，CI 全绿，真机基本可用。
- 最近一天做了：
  - 电脑端界面整体改版；
  - 手机“我的文件”；
  - PDF、Office、文本、Google 文档在 App 内查看；
  - 两台电脑时发送前选目标；
  - 家人改访客时权限自动降级。
- **下一步建议先做：完整回归测试 + 出新的测试清单**，然后做“从其他 App 分享到 LocalRoll”（见第 5 节）。

---

## 1. 工作约定（用户 Xue 的固定要求，必须遵守）

- **回复用中文，简洁**；先分析再动手，用户说过“先别盲目地改”。拿不准的行为变更先问。
- **只给 Git Bash 命令**。源码在用户电脑 `C:\Users\lixue\Projects\localroll`。
- 交付的代码文件**第一行写路径注释**（如 `// apps/desktop/lib/ui/xxx.dart`）。仓库里所有文件都已遵守。
- **每次发版后给更新命令**：
  ```bash
  cd /c/Users/lixue/Projects/localroll && git pull
  bash scripts/update-windows.sh      # 两台电脑
  bash scripts/download-android.sh
  bash scripts/download-ios.sh
  ```
  只改了电脑端就只给前两行，只改了手机就只给手机的。
- **隐私、安全、可靠第一**。
- Android 签名密钥文件夹 `C:\Users\lixue\Projects\LocalRoll-keys` **绝不提交**，只在用户电脑和 GitHub secrets 里。
- 没有真机：每次都要说明“只确认了编译通过，请真机看一下”。

---

## 2. 开发与发布流程（技术备忘）

- **仓库**：github.com/lixuedenon/localroll（公开，GPL-3.0）。Flutter monorepo：
  - `packages/core`：纯 Dart，协议、模型、工具，**不依赖 Flutter**；
  - `apps/desktop`：Windows；
  - `apps/mobile`：iOS / Android。
- **本环境没有 Flutter/Dart**，也连不上 pub.dev 和 storage.googleapis.com。所有 analyze / test / 构建都靠 GitHub Actions。
- **发版**：
  ```
  gh api -X POST repos/lixuedenon/localroll/actions/workflows/ci.yml/dispatches -f ref=main -f 'inputs[release]=v0.1.0-beta.N'
  ```
  - 先 push，再 dispatch。**发版进行中再 push 会取消发版**（concurrency）。
  - 下一个版本号是 **beta.52**。
- **看 CI 失败原因**：日志下载打不开，要读 check-run 的 annotations：
  ```
  gh api repos/lixuedenon/localroll/check-runs/<job id>/annotations
  ```
  - CI 会把 analyze/test 错误（含 core，beta.51 起）写成 annotations；
  - iOS 构建失败时会把 Xcode 错误行和日志尾部写成 annotations。
- **Flutter 版本**：桌面和 Android 用 3.35.4，iOS 用 3.47.6（UIScene）。
  - 依赖版本要能在 3.35 上编译：pdfrx 1.x（**只给桌面用**，放到手机会让 iOS 签名失败）、share_plus 11.x、image <4.6、file_picker <11、image_picker <1.3。
  - photo_manager 3.x 没有 containsEmptyAlbum。
- **多语言**（17 种）：
  - 文字放在 `apps/desktop/l10n/<lang>.json`、`apps/mobile/l10n/<lang>.json`；
  - 加 key 时 17 个文件都要加（用一次性 python 脚本批量写）；
  - 然后运行 `python scripts/gen_l10n.py`，并用 `--check` 验证。代码里不写死文字。
- **手机原生通道**（不加第三方库）：
  - `localroll/background`：后台传输、电量、空间；
  - `localroll/diag`：iOS 权限诊断；
  - `localroll/pdf`：iOS 用 PDFKit，Android 用 PdfRenderer，渲染 PDF 页为 JPEG；
  - `localroll/files`：iOS 用 QuickLook 系统预览；两端都有 openUrl，只允许 https。
  - 代码位置：`ios/Runner/AppDelegate.swift`、`android/.../MainActivity.kt`。
- **电脑看门狗**（`services/watchdog.dart`）：独立 isolate，界面卡住时立即在日志写 “[watchdog] NOT RESPONDING … Last events”。
  - 文件对话框由 `WinDialogs` 统一打开并记日志（`ownThread=false`，用的是普通对话框）；`saveFile` 是 beta.49 新增的。

---

## 3. beta.39 – beta.51 做了什么

### 电脑端
- **beta.39–41（卡死排查）**：
  - 看门狗；
  - 每个页面、对话框、PDF 阅读器、视频播放器都记日志；
  - 接收完成后文件被 Windows 占用时重试改名；
  - 发送时分块完整收齐再写。
  - 那台“点发送就卡死”的电脑：用户测了一轮没再复现，**原因仍未确认**。复现时要用户发电脑日志（`%APPDATA%\io.github.lixuedenon\localroll_desktop\logs`）。
- **beta.44 界面改版**：
  - 左栏 5 项：首页 · 设备 · 媒体库 · 转换 · 设置。原来的接收、发送、家庭三页合并成“设备”。
  - **设备页**：
    - 按“家人 / 访客”分组，每台一行；“发送 ▾”菜单（文件 / 文件夹，发给电脑还有文字）。
    - 点一行打开右侧详情：身份切换、媒体库权限、属于哪位家人、我在它那里的身份、发送、最近传输、断开 / 忘记 / 取消配对。
    - 附近未配对的电脑在页面底部。
  - **添加设备弹窗**：手机 / 电脑两个标签；手机标签有配对二维码和配对码。
  - **标题栏“传输”按钮**：收发记录统一放在这个面板里。
  - **首页**：三个数字卡、设备方块、最近收到；有问题时才显示“需要注意”。
- **beta.45**：媒体库工具栏合成一行：“新收到 N · 查看”、“所有人 ▾”、排序 ▾。
- **beta.46**：
  - 转换页、设置页改成统一样式（设置分组：这台电脑 / 通用 / 接收 / 存储 / 网络 / 关于）。
  - 媒体库缩略图大小可选小 / 中 / 大，会记住（`settings.thumbSize`）。
- **beta.47**：
  - 设备详情里身份和三档权限都配上了白话说明；
  - 媒体库标题旁提示“实况照片和视频：鼠标停在上面就会播放”。
- **beta.48**：家人改成访客时，媒体库权限自动降为“不能浏览”（`setFamily` 里把 access 设为 null）；有自动测试。改回家人后恢复默认“可以浏览”。
- **beta.49**：
  - “文档”里的 PDF 显示第一页缩略图（pdfrx，一次只处理一个，缓存成 PNG 放在媒体库的 .localroll/cache）。
  - .txt / .md / .log 在 LocalRoll 文本窗口打开，可以另存为，编码自动识别 UTF-8 / UTF-16 / GBK。
  - 收到文字的窗口有“存到‘文档’”和“另存为…”两个保存按钮。
- **beta.50**：Google 快捷方式（.gdoc / .gsheet / .gslides 等）弹出说明，可在浏览器打开（只认 Google 的 https 地址）。
- **beta.51**：Office 简易预览（见第 4 节）。
  - 电脑装了 Office 或 WPS 时照常用它打开（查注册表 `hasProgramFor`）；没装就用 LocalRoll 预览。
  - 每个 Office 文件那一行都有 👁 预览按钮。

### 手机端
- **beta.42 “我的文件”**：
  - 收到的东西和留下的扫描件统一放进一个库，按发送人分类：
    - 相册名“LocalRoll · 发送人”；
    - 文件放在 LocalRoll 文件夹的“类别 / 发送人 /”下。
  - 可以按类别和发送人筛选，可以搜索、分享、发送、改名、删除；“最近删除”保留 30 天。
  - 代码：`services/my_library.dart`、`media_saver.dart`、`ui/my_library_page.dart`。
- **beta.43 新首页**：
  - 一排设备（点设备弹出可以做什么，其中有“设为备份电脑”）；
  - 备份卡片；
  - 发送 · 扫描 · 清理；
  - 最近收到；
  - 底部标签：首页 · 照片 · 文件 · 电脑；
  - 发送流程统一为“先选发什么，再选发给谁”。
  - 简易模式不变，只加了设备条。
- **beta.44**：iPhone 语言选择改用系统滚轮（CupertinoPicker），Android 是列表。
- **beta.49**：
  - **配对了两台以上电脑（或附近有手机）时，每次发送都让用户选**，备份电脑会标出来。
  - PDF 在 App 内阅读（翻页、放大、分享），“我的文件”里显示第一页缩略图。
- **beta.50**：`ui/open_file.dart` 统一处理“打开文件”：
  - PDF：用自己的阅读器；
  - Google 快捷方式：说明卡片，可在浏览器打开；
  - **iPhone**：其他文件用系统预览（Word、Excel、PPT、iWork、文本、CSV、RTF、网页、音频）；
  - **Android**：文本、CSV（表格）在 App 内显示；
  - 其他：信息卡，提供“用其他 App 打开”和“发送到电脑”。
- **beta.51**：
  - Android 上的 Word、Excel、PPT 用 Office 简易预览打开。
  - 浏览电脑相册时视频播不了：日志记录原因，并提供“保存到这部手机”（电脑会先转换）。
  - 用户报告的“滑到视频就不能播放”，在 beta.51 上已经不再出现，原因不明。复现时要日志。

### core
- beta.50：`google_links.dart`（有测试）。
- beta.51：`office/zip_reader.dart`、`office/xml_lite.dart`、`office/office_doc.dart`（有测试，fixtures 在 `packages/core/test/fixtures/sample.docx|xlsx|pptx`）。

---

## 4. 几个设计概念（用户问过，已解释并认可）

- **家人 / 访客**：每台**接收方电脑**各自保存一份名单，没有全局的“家庭组”。
  - 家人发来的直接收下（用于备份）；访客发来的每次都要点“接受”。
  - 可以有几台电脑加几部手机；两台电脑可以互相设为家人。
  - **名单不在电脑之间同步**，这是待做项。
  - 手机作为接收方时一律先确认。
  - “你的名字”相同的几部手机算同一位家人（FamilyDirectory）。
- **媒体库权限**（每台电脑按设备设置）：
  - 三档：不能浏览 / 可以浏览（只看）/ 可以浏览和删除（进回收站，不能修改）。
  - 默认家人“可以浏览”、访客“不能浏览”。
  - 家人改访客时自动降级（beta.48）。
  - “仅本人可见”的照片别人都看不到。
- **备份电脑**：每部手机自己选一台，存在 `currentDesktopId`。
  - “备份”和“自动发送”只发到这台。
  - 设置位置：手机首页设备条 → 点电脑 → “设为备份电脑”。
  - 和“家人”是两个概念。
- **文件打开的总方案**（用户要求不装第三方软件也能看）：
  - ① 优先用系统自带能力，在 App 内看（iPhone 系统预览；三端的 PDF、文本）——已完成；
  - ② LocalRoll 自带 Office 简易浏览器——已完成，只读 docx / xlsx / pptx，旧版 doc / xls / ppt 不支持；
  - ③ 电脑装了 Office 时，发给 Android 前自动转 PDF——**未做**；
  - ④ 兜底信息卡、Google 卡片——已完成。

---

## 5. 下一步计划（已和用户讨论，按建议顺序）

1. **完整回归测试（建议马上做）**
   - 出一份新的**可打印测试清单**（HTML 页面），覆盖 beta.39–51 的全部改动，在两台电脑、iPhone、Android 上测。
   - 同时把《开发进度》补到 beta.51（可以直接把本文第 3 节并进去）。
2. **补齐传输（阶段 B）**
   - **从其他 App 分享到 LocalRoll**：
     - 手机：iOS Share Extension、Android 的“分享”菜单；
     - 电脑：资源管理器右键“发送到 → LocalRoll”。
     - 用户最常用，建议先做。
   - **Android 后台接收**：iPhone 系统不允许，做不了。
   - **热点扫码连接**：没有 Wi‑Fi 时用。
3. **手机浏览电脑相册的改进**（用户说“先不动”，以后再做）：
   - 双击放大；放大后拖动不翻页；
   - 视频显示时间、全屏横屏；
   - 放大到一定程度自动换原图（现在是最长边 2560 的预览）；
   - 手机播不了的视频由电脑边转边播（MKV / AVI 等现在浏览时播不了，“保存到手机”会自动转换）。
4. **对外发布准备（阶段 C）**
   - 定名字（候选见《开发进度》文末，要带“自己家的免费云”的意思，不能用 iCloud 或 i 前缀），查商标和域名；
   - 苹果开发者账号（99 美元 / 年），上 TestFlight；
   - 介绍网页、隐私政策。
5. **零散待做**：
   - 两台电脑之间同步家人名单；
   - Office 转 PDF（第 4 节第③项）；
   - OCR；
   - 给访客限定开放时间段；
   - iPhone 上 GBK 编码的 .txt 会乱码（QuickLook 不识别 GBK，可以改成先自己解码再显示）；
   - 电脑卡死的根本原因（等看门狗日志）。

---

## 6. 已知问题和注意事项

- 电脑 PDF 缩略图和阅读器都用 pdfrx。之前怀疑卡死和“打开第二个 PDF”有关，没有证实；缩略图已改成一次只处理一个。
- 手机浏览电脑相册时，视频是原文件经手机本地中转直接播放（`pc_library.dart` 的 relay，只监听 127.0.0.1）。手机不支持的格式播不了。
- iPhone 必须打开 LocalRoll 才能被找到和接收（iOS 限制）。
- Office 简易预览：Excel 只显示前 500 行、40 列；Word 不还原排版；EMF / WMF 图片不显示。
- “另存为…”用的是 Windows 普通保存对话框。如果那台会卡的电脑在这里卡住，日志里会有 “save dialog opened”。
