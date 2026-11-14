<!-- docs/HANDOVER.md -->
# Keepnear（内部名 LocalRoll）交接文档

> 截至 2026-11-14，最新版本 **v0.1.0-beta.124**。
> 新接手的开发者请先把本文完整读一遍，再动手。
> 每一版的细节在项目文档《betaNN-…》里（每版一篇，只写结论）。方案类文档见第 10 节。

---

## 0. 一句话现状

- **产品**：Keepnear 是本地优先的「手机 ↔ 电脑」工具。核心是把 iPhone / Android 的原片通过家里 Wi-Fi 传到 Windows，收到后能直接看、能播放，需要时再高质量转换。在这个基础上加了媒体库、播放器、录屏 / 讲解、屏幕画笔、图章、常用工具、格式转换、访客传输等。
- **三端**：Windows 桌面、Android、iPhone，都在 **v0.1.0-beta.124**。
- **测试情况**：beta.52 以后大部分改动只确认了编译通过和 CI 自动检查通过，**没有系统地在真机上测过**。用户 Xue 自己在两台 Windows 电脑、一台 iPhone 和安卓手机上抽测，再把日志发回来。
- **名字**：显示名 **Keepnear**。内部 id、注册表名、发布包名还是 **LocalRoll**。正式名字用户还没最终定。
- **产品宗旨**（用户 11-09）：像社区 7-11 便利店，常用的都有，每样把最主要的需求做好；**本地传输要做到市面上最好**。

---

## 1. 和用户合作的固定规则（必须遵守）

### 沟通
- **回复用中文，简洁**。先分析，再动手。
- **写代码前必须先和用户确认**。讨论阶段不改代码，用户说「开始」才改。用户说「不要改」时只分析。
- 用户看不懂时，**举例子说明**。给方案时先写结论，再列需要用户拍板的点，每点附上建议。
- **界面和图形类的改动，先出示意图**：写 HTML+SVG，用 Playwright 截图，发给用户确认。
- **token 有限**：尽量几个任务一起做、一起编译、一起发一版，少来回。
- 没有真机可测，所以每次都要说：「只确认了编译通过，请在真机上看一下」。

### 代码
- **只给 Git Bash 命令**，不给 PowerShell 或 CMD。
- 源码在用户电脑的 `C:\Users\lixue\Projects\localroll`。
- **每个代码文件第一行写路径注释**，例如 `// apps/desktop/lib/ui/xxx.dart`、`# scripts/xxx.sh`、`<!-- README.md -->`。仓库里的所有文件都已经这样写。
- **隐私、安全、可靠排第一**。
- 安卓签名密钥文件夹 `C:\Users\lixue\Projects\LocalRoll-keys` **绝对不能提交**。签名信息只放在 GitHub Secrets 里：`LR_KEYSTORE_B64`、`LR_KEYSTORE_PASSWORD`、`LR_KEY_ALIAS`、`LR_KEY_PASSWORD`。

### 发版与文档
- **发版由开发者（Claude）自己完成**，等三端都编译完。
- **发版后一定要给用户命令行**（见第 3.5 节）。
- 每发完一版，写一篇项目文档 `claude/betaNNN-简短描述.md`，**只写结论**。重大变化同时更新本交接文档。

### 产品原则
- **跨设备**：电脑有的功能手机也应该有，除非工作量太大，或手机系统自带的功能已经够好。
- **全在本机**：智能功能（搜图、人脸、OCR、自动分类）都用本机规则或本机模型，不接云端 AI，不产生费用。
- **功能融合**：所有产出都能发给任何设备，也能分享给访客。
- **界面风格**：学用户给的参考图的风格，不照搬内容和图片，只做我们有的功能。弹窗一律用浅色。
- **许可证**：收费前所有组件都要能闭源商用。ffmpeg 已经是 LGPL 版，CI 会检查。新加的第三方组件要写进 设置 → 关于 →「开源许可」。
- **闭源**：仓库现在是**公开**的（GPL-3.0）。**任何公开曝光之前，要先改成私有**，换掉 LICENSE，并检查依赖的许可。到时候要提醒用户。

### 用户明确说过「不做 / 不动」的
- 「回家自动备份」不做。
- 收到文件**不自动转换格式**。
- **不给安装包瘦身**（ffprobe、ffmpeg 不动）。
- 人脸模型以后再改成可选。
- 图章库、录讲解保持现状；浮动面板的改进「再说」。

---

## 2. 总体功能

### 2.1 电脑端（Windows）

左栏依次是：首页、传输、媒体库、播放器、录屏幕、工具、设置。

| 模块 | 内容 |
|---|---|
| **首页** | 状态卡片；常用工具 12 格（可以把文件拖进去）；我的设备；最近收到；需要处理的事 |
| **传输** | 双向互传、断点续传、SHA-256 校验、去重；传输记录；拖放发送、多选、离线排队、右键「发送到」；连接体检；访客传输（网页收发，有二维码，可续传）；剪贴板（beta.123 起能发复制的文件、图片、文字）；从媒体库选文件发送；请手机「现在备份」和备份体检；**右下角传输进度卡**（beta.124） |
| **媒体库** | 家庭 / 设备视图、可见性、「最近删除」（30 天）；以文搜图（CLIP）、人脸、文字搜索（OCR）；PDF / Office 查看和 PDF 缩略图；自然语言搜索、自动分类、清理建议、打包给 AI；右键直接用对应工具；工具做出来的文件右键可以「打开原文件位置」 |
| **播放器** | 新风格首页（beta.118）、视频播放、笔记、截图、剪片段、标注 / 涂鸦、录讲解、讲解编辑（回放、重录一段） |
| **录屏幕** | 录全屏 / 窗口 / 区域；摄像头小窗；录电脑声音，说话时压低背景声；屏幕画笔和浮动工具面板；图章（753 个彩色图章 + 行业包）；K 线面板；录屏编辑；「我录的」 |
| **工具** | 工具记录（在顶部）+ 全部工具 + 转换队列。工具包括：**格式转换**（beta.124 新模块，见 2.3）、PDF 工具（合并、拆分、签名、压缩等）、图片编辑、照片转 PDF、压缩照片、剪视频、压缩视频、二维码、截图取字（全局快捷键，默认 Ctrl+Alt+X）等 |
| **设置** | 设备名、端口、媒体库位置、语言（17 种）、工具结果保存位置、快捷键、诊断日志导出、开源许可 |

- **工具结果**：原文件不动。结果默认存进媒体库的「Keepnear 工具」文件夹并登记；也可以选「原文件旁边」或「两处都存」。每个结果都记得自己的原文件。
- **对话框**：全部用浅色（beta.124 起统一走 `showLrDialog`）。

### 2.2 手机端（Android + iPhone）

- 互传、备份（只读相册原片，不转码）、清理空间、配对（二维码 / PIN）、浏览电脑相册、看照片视频、PDF / Office 查看、扫描文档、我的文件、17 种语言、诊断日志。
- 首页：本机名字、添加设备、剪贴板卡片、常用工具 9 格；播放器；视频涂鸦片段。
- Office 转 PDF 交给电脑来做（接口 `/api/v1/tools/office-pdf`）。
- 手机端**还没有**：图章 / K 线、标注同步、录讲解、「我录的」。

### 2.3 格式转换模块（beta.124）

- 分四类：图片 / 视频 / 音频 / 文档。左右两个滚轮分别选「原格式」和「转成」，转不了或不用转的格式灰色划线。
- 文件可以从电脑选、从媒体库选，或直接拖进来。
- 图片、视频、音频：交给 ffmpeg 转换队列（`ConverterService`）在后台转。
- 文档：
  - 内置：PDF → JPG / PNG / TXT（扫描件走 OCR）、TXT → PDF、JPG / PNG → PDF。
  - 需要电脑装 Microsoft Office（走 COM）：PDF → Word、Word ↔ TXT、Excel ↔ CSV、PPT → 图片、Word / Excel / PPT → PDF。
- 旧的 HEIC → JPG、视频 → 音频、Office → PDF 三个工具磁贴已经并进这个模块。

---

## 3. 开发环境与 GitHub 工作流

这一节最重要。下面写的是 Claude 在云端会话里怎么改代码、怎么发版、怎么把东西交给用户。

### 3.1 拿代码

- 仓库：**github.com/lixuedenon/localroll**，主分支 `main`，直接推 main，不走 PR。
- 新会话的步骤：
  1. 先用 `add_repo` 加仓库：owner `lixuedenon`，repo `localroll`，access 选 `push`。
  2. 克隆：`git clone --depth 1 <它给的地址> /home/claude/localroll`。
- 推送标签会被拒绝。本环境的 `gh` 可以读 Actions（`gh run list` / `gh run view --log-failed`），但不要靠它推送。
- pub.dev 在本环境被挡住了。要看第三方包的源码，就到 GitHub 上 `git clone` 那个包。

### 3.2 本环境没有 Flutter，全靠 GitHub Actions 编译

- `.github/workflows/ci.yml` 在**每次推送 main 时**都会跑这些 job：
  - `bootstrap`：判断提交信息里有没有 release 行，并补生成平台文件夹。
  - `analyze`：检查翻译是否完整；对 core、desktop、mobile 跑 analyze 和 test。
  - `build-windows`：编译后还会实测几个辅助程序（屏幕画笔、电脑声音、摄像头）、onnxruntime 和人脸模型能否加载、ffmpeg（必须是 LGPL 版），以及 **lr_pdf.exe 的 `--thumb`**。
  - `build-android`：用 Secrets 里的密钥签名。
  - `build-ios`：在 macOS runner 上编译，产出未签名的 ipa。
- Flutter 版本：Windows 和 Android 用 **3.35.4**；iOS 用 **3.47.6**（看 `env`）。
- **analyze 出现 warning 或 error 就算失败，info 不算**。查错误：
  ```bash
  gh run view <id> --log-failed | grep -E " error • | warning • "
  ```
- 平时的流程：
  1. 改代码，`git commit`，`git push`。
  2. 等 CI。一般 analyze 约 3 分钟，Windows 约 10 分钟，iOS 约 15–25 分钟。
  3. 有错就修，再推。
- 等 CI 时的轮询写法：
  ```bash
  H=$(git rev-parse HEAD)
  gh run list -L5 --json headSha,status,conclusion,databaseId \
    -q ".[]|select(.headSha==\"$H\")"
  ```
  前台命令最多跑 10 分钟，更久的要用后台任务。前台**不能直接 `sleep`**，要用 `python3 -c "import time;time.sleep(60)"`。

### 3.3 发版（Release）

- 方法：推一个提交信息里**单独一行写 `release: v0.1.0-beta.N`** 的提交，空提交也可以。CI 编完三端后，`release` job 会建 GitHub Release，挂上三个文件：`LocalRoll-Windows.zip`、`LocalRoll-Android.apk`、`LocalRoll-iOS-unsigned.ipa`。
- 发版脚本放在会话的 scratchpad 里，叫 `relNNN.sh`，每次从上一版用 `sed 's/123/124/g' rel123.sh > rel124.sh` 生成。它做三件事：
  1. 等当前 HEAD 的 analyze 通过；
  2. 推带 release 行的空提交；
  3. 每分钟查一次 `releases/latest`，直到 tag 正确并且有 3 个文件（打印 `RELEASED N`），失败时打印 `RELEASE FAIL`。

  模板如下，新会话需要自己重建：
  ```bash
  set -u; cd /home/claude/localroll
  api=https://api.github.com/repos/lixuedenon/localroll
  sha=$(git rev-parse --short=7 HEAD)
  # 1) 等 analyze 通过（用 $api/actions/runs?per_page=1&branch=main，再看 /jobs 里 name=='analyze' 的那个 job）
  # 2) git commit --allow-empty -m "beta.N release

  release: v0.1.0-beta.N" && git push origin main
  # 3) 轮询 $api/releases/latest，直到 tag_name=v0.1.0-beta.N 且 assets 有 3 个
  ```
- 用 `run_in_background` 跑这个脚本，大约需要 30–40 分钟。
- **注意事项**：
  - **发版跑完之前，不要再推 main**。`concurrency: cancel-in-progress` 会把正在跑的发版取消掉。
  - 脚本有时会读到**上一次 run** 的状态，误报 FAIL。先去 Actions 页面核实，再决定是否重发。
  - iOS job 偶尔会被 runner 取消（超过 15 分钟）。补一个新提交重新发版即可。
- 下一个版本号：**beta.125**。

### 3.4 怎么把东西交给用户

- **代码**：不给用户发代码文件。代码直接推到 GitHub，用户在自己电脑上 `git pull`。
- **安装包**：全部从 GitHub Release 下载，用户用下面的脚本更新。
- **示意图**：
  1. 写 HTML+SVG，放在 scratchpad；
  2. 用 Playwright 截图，`deviceScaleFactor: 2`；
  3. 用 `SendUserFile` 发 PNG。
- **文档**：写进 claude.ai 项目「iPhone to windows」（`Projects` 工具 `project_write`，路径 `claude/...md`）。

### 3.5 发版后给用户的命令（固定格式）

只给改动了的平台：
```bash
cd /c/Users/lixue/Projects/localroll && git pull
bash scripts/update-windows.sh      # 两台电脑都要跑：下载最新 Windows 包到 ../LocalRoll-app 并启动
bash scripts/download-ios.sh        # 覆盖 C:\Users\lixue\Projects\LocalRoll-ios\LocalRoll-unsigned.ipa，用户在 Sideloadly 里 renew
```
Android：在手机上直接打开
https://github.com/lixuedenon/localroll/releases/latest/download/LocalRoll-Android.apk

### 3.6 用户发来的日志

- 用户从 设置 → 诊断日志 → 导出日志 拿到日志，电脑端和手机端都有。
- 判断是不是闪退：先看每个 `[start]` 的**前一行**。
- 写日志：`DiagLog.log('分类', '内容')`，在 `localroll_core` 里。

---

## 4. 多语言（17 种）

- 语言：zh、zh_Hant、en、ja、ko、de、fr、es、pt、it、ru、ar、hi、id、th、tr、vi。
- 文字放在 `apps/desktop/l10n/<语言>.json` 和 `apps/mobile/l10n/<语言>.json`。
- 改完运行：
  ```bash
  python3 scripts/gen_l10n.py && python3 scripts/gen_l10n.py --check
  ```
  这会生成 `lib/l10n/translations.g.dart`。CI 也会检查翻译是否完整。
- 代码里用 `tr('键', {'参数': 值})`，占位符写成 `{name}`。
- 新增文字时，最好一次写全 17 种。做法：在 scratchpad 写一个 Python 脚本，按语言列表合并进 json（beta.124 的 `l10n124.py` 就是这样）。
- 改**已有的键**时，只改中文、繁体、英文，**不要把其他语言原有的译文覆盖成英文**。

---

## 5. 文件架构

```
localroll/
├─ apps/desktop/            Windows 应用（Flutter）
│  ├─ lib/main.dart          启动：单实例、窗口大小、托盘、主框架（左栏 + 页面 + 传输进度卡）
│  ├─ lib/app_services.dart  全局服务容器 AppServices（settings, library, server, peers, sender, converter, ffmpeg, tools, guest, textIndexer, faceIndexer, pictureIndexer, recordings, notes …）
│  ├─ lib/server/            transfer_server.dart（HTTP/HTTPS 接收服务、全部 /api/v1 接口）、port_mux.dart
│  ├─ lib/services/          业务逻辑（下表）
│  ├─ lib/ui/                界面（下表）
│  ├─ l10n/*.json            翻译源文件
│  └─ windows/
│     ├─ runner/             C++ 宿主：flutter_window.cpp（全局快捷键通道 keepnear/hotkeys 等）
│     └─ pdf/pdf.cpp         lr_pdf.exe：用随包的 pdfium.dll 写 PDF、做 PDF 缩略图（--thumb）
├─ apps/mobile/             手机应用（Flutter，iOS + Android）
│  ├─ lib/services/          desktop_client, discovery, uploader, file_sender, background_transfer, phone_server（手机也能接收）, clipboard_sync, backup_plan, my_library, pc_library, scan_pdf, clip_maker …
│  ├─ lib/ui/                home_page, transfer_page, backup_page, cleanup_page, tools_page, pc_library_page, my_library_page, ink_editor_page …
│  ├─ android/…/kotlin/      MainActivity.kt（原生通道：toJpeg, clipboardImage …）、TransferService.kt（前台服务）、ClipMaker.kt
│  └─ ios/Runner/AppDelegate.swift  原生通道（iOS 版）
├─ packages/core/           两端共用：protocol（端口、接口）、models、pairing、tls、hashing、exif、live、diag_log、i18n、office 文档解析（docx/xlsx/pptx 简易预览）
├─ packages/ink/            标注和图章：ink_mark/ink_paint、stamp、packs（行业包，real.g.dart 是 753 个彩色图章）、candle（K 线）、tools/photo_edit.dart（共享图片编辑器）、signature_pad.dart
├─ tools/stamps/            用 Python 生成图章库的脚本
├─ scripts/                 gen_l10n.py、update-windows.sh/.ps1、download-ios.sh、download-android.sh、setup-android-signing.sh、patch_platforms.py、ffmpeg-pin.env、models/export_clip.py
├─ docs/                    ARCHITECTURE.md（协议说明，较旧）、HANDOVER.md（本文）
└─ .github/workflows/       ci.yml（主流程）、faces.yml、models.yml、pin-deps.yml
```

### 5.1 电脑端主要服务（`apps/desktop/lib/services/`）

| 文件 | 作用 |
|---|---|
| `settings.dart` | 设置、已配对设备、dataDir（`randomId` 也在这里） |
| `library_index.dart` | 媒体库索引（`.localroll/index.json`），`add`、`absPath`、`withLive` |
| `received_files.dart` | 非媒体文件列表（文档页） |
| `peers.dart` | 设备目录 + `PeerSender`（发送队列 `SendJob`，可暂停、取消、离线排队） |
| `receive_hub.dart` | 接收进度（`TransferProgress`） |
| `transfer_log.dart` | 传输记录 |
| `guest_server.dart` | 访客网页传输 |
| `ffmpeg.dart`、`converter.dart` | ffmpeg 封装；转换队列 `ConvertFormat`、`ConvertPreset`、`enqueueFile` |
| `format_convert.dart` | beta.124：格式表 `FormatTable`、文档转换 `FormatConverter`（Office COM、PDF ↔ 图片 / 文字） |
| `file_tools.dart` | `PdfBuilder`（调用 lr_pdf.exe）、`photosToPdf`、`OfficePdf`、`VideoTools` |
| `tool_outputs.dart` | `toolOutPath`、`ToolSaveTo`、`ToolRecords`（`s.tools`，记录写在 `tools.json`） |
| `windows_ocr.dart`、`text_indexer.dart`、`text_index.dart` | OCR 和文字搜索 |
| `picture_model.dart`、`picture_index.dart`、`smart_query.dart` | 以文搜图（CLIP，onnxruntime）、自然语言搜索 |
| `face_engine.dart`、`face_indexer.dart`、`people.dart` | 人脸 |
| `recordings.dart`、`player_memory.dart`、`annotations.dart` | 录制、播放记录、标注 |
| `win_screen.dart`、`screen_pick.dart`、`pen_overlay.dart`、`camera_bubble.dart`、`loopback.dart`、`mic.dart` | 录屏、画笔、摄像头、电脑声音 |
| `global_keys.dart` | 全局快捷键（截图取字） |
| `clipboard_send.dart` | 读剪贴板（PowerShell STA） |
| `window_memory.dart` | 记住窗口大小和是否最大化 |
| `win_dialogs.dart` | 系统文件对话框 |
| `run_flag.dart`、`watchdog.dart`、`single_instance.dart` | 防闪退标记、看门狗、单实例 |

### 5.2 电脑端主要界面（`apps/desktop/lib/ui/`）

| 文件 | 作用 |
|---|---|
| `home_shell.dart`、`app_nav.dart`、`title_bar.dart` | 主框架、导航、自绘标题栏（拖动、双击最大化） |
| `dashboard_page.dart` | 首页 |
| `devices_page.dart`、`transfer_records.dart`、`send_paths.dart`、`net_check.dart`、`transfers_panel.dart`、`transfer_float.dart` | 传输页、传输记录、发送、连接体检、传输面板、右下角进度卡 |
| `library_page.dart`（最大，约 95k）、`files_view.dart`、`library_tools.dart`、`library_picker.dart`、`media_thumb.dart`、`pdf_thumb.dart` | 媒体库、文档、媒体库选择器、缩略图 |
| `player/` | 播放器：`player_page.dart`、`player_home.dart`、`narration*.dart`（讲解）、`ink_editor.dart` |
| `screen/` | 录屏：`screen_record.dart`（含截图取字 `snipScreen`、切换窗口小条）、`float_panel.dart`、`pen_bar.dart`、`screen_editor.dart`、`recordings_view.dart` |
| `tools/` | 工具：`tools.dart`（`Tool` 枚举、`ToolsGrid`、`openTool`、`showToolResult`）、`convert_page.dart`、`pdf_tool_page.dart`、`video_tool_page.dart`、`image_tool_page.dart`、`qr_tool.dart`、`tool_records.dart` |
| `jobs_page.dart` | 工具页（`AppNav.convert`） |
| `theme.dart` | 深色主题，`lrFontFallback`（按语言排字体回退顺序） |
| `light_look.dart` | 浅色配色 |
| `lr_dialog.dart` | `showLrDialog`：所有对话框都用它 |
| `light_dialog.dart` | 旧的浅色弹窗 |

### 5.3 通信要点

- 电脑默认监听 **53530** 端口，被占用时依次试 41530 / 31530 / 21530 / 8530。
- 用 mDNS（`_localroll._tcp`）发现设备；配对二维码以 `LOCALROLL:` 开头，后面是 base64url 编码的 JSON。
- 现在是 TLS 加证书固定（`tls_identity.dart`）。
- 分块续传、SHA-256 校验、按 `(deviceId, assetId)` 去重。这几项的细节见 `docs/ARCHITECTURE.md`（端口和接口部分基本仍然有效）。

---

## 6. 各功能完成情况

✔ = 已完成并且用户真机用过 ； ◐ = 已完成，只确认了编译通过 ； ✗ = 没做

| 功能 | 状态 | 说明 |
|---|---|---|
| 手机 → 电脑传原片、续传、校验、去重 | ✔ | 核心功能，最稳定 |
| 电脑 → 手机、电脑 ↔ 电脑互传 | ✔ | |
| 传输页（记录、拖放、多选、离线排队、连接体检） | ◐ | beta.112–113 |
| 访客传输（网页）、续传 | ◐ | |
| 发送剪贴板、从媒体库选文件（beta.123） | ◐ | |
| 传输进度卡、任务栏进度（beta.124） | ◐ | |
| 媒体库基础（浏览、删除、最近删除、可见性） | ✔ | |
| 以文搜图、人脸、OCR、自然语言搜索、自动分类、清理建议 | ◐ | 分类靠规则，不一定准 |
| PDF 缩略图（lr_pdf --thumb） | ✔ | beta.121 修好，用户确认已经很快 |
| 窗口最大化和记忆 | ◐ | beta.122 修了窗口跑到屏幕外、拖不动 |
| 播放器新风格、笔记、剪片段 | ◐ | |
| 录屏、摄像头、电脑声音、画笔、浮动面板、图章、K 线、录屏编辑 | ◐ | 这一大块都没在真机系统测过 |
| 录讲解、讲解编辑 | ◐ | |
| 常用工具（电脑 12 格 / 手机 9 格） | ◐ | beta.114 |
| 工具结果进媒体库、工具记录 | ◐ | beta.115 |
| 截图取字全局快捷键、切换窗口 | ◐ | beta.116、beta.118 |
| 浅色对话框统一、字体修正（beta.124） | ◐ | |
| 格式转换模块（beta.124） | ◐ | Office 相关的转换要在装了 Office 的电脑上测 |
| 手机：图章 / K 线、标注同步、录讲解、我录的 | ✗ | 用户同意先不做 |
| 远程访问（不在同一 Wi-Fi） | ✗ | 暂不做；原则是只牵线、不中转 |
| 安装包（MSIX / Inno）、代码签名、TestFlight | ✗ | 现在是 zip、未签名 ipa |
| 收费 | ✗ | 方案见《商业模式与收费功能》，未定 |

---

## 7. 已知问题和注意事项

### 传输和网络
- iPhone 必须打开 App 才能被找到、接收文件、响应「现在备份」。电脑不能主动从 iPhone 拉东西。
- 访客传输：
  - 80 端口被占用时会换端口；
  - Windows 防火墙第一次需要管理员确认；
  - 热点要手动开；
  - zip 超过 4 GB 不提供；
  - 网页必须开着、不锁屏；
  - iPhone 网页不能一键存进相册（因为是 http）。
- 去重只比较有 SHA-256 的条目。

### 界面和显示
- 多屏且缩放比例不同的电脑上，选窗口或选区域可能会偏。
- 截图取字快捷键 Ctrl+Alt 在部分欧洲键盘上等于 AltGr，可能冲突。可以在设置里换键。
- 媒体库**多选后底部选择条上的转换按钮**还是旧的转换窗口（`convert_dialog.dart`，只能转图片和视频）。右键菜单已经改成打开新模块。**待统一**。

### 格式转换（beta.124）
- PDF → Word 用的是 Word 自带的转换，排版复杂的 PDF 会走样。
- Excel → CSV 用 UTF-8（SaveAs 62），老版本 Office 会退回到 6，中文可能变成乱码。
- PPT → 图片每页生成一个文件，命名是 `原名-N.jpg`。
- 没装 Office 时会弹提示。

### 工具
- 视频合并要求每个视频都有声音。剪视频选「原画质」时不重新压缩，切点落在最近的关键帧。
- PDF：
  - 电脑签名保留文字；手机签名或编辑后，每页变成图片（已有提示）；
  - PDF 压缩 = 每页变成图片（已有提示）；
  - 有密码的 PDF 打不开。
- 二维码识别用的是纯 Dart 库，背景复杂时可能认不出。
- beta.114 及更早版本的工具结果存在 `%TEMP%\Keepnear`（当时的路径错误），不会自动搬进媒体库。

### 录屏和画笔
- K 线只能整体移动、缩放。
- 只画不录时，画的内容结束后不保存。
- 浮动面板是一个独立进程，占 60–100 MB。
- 真实图章的文字用 App 默认粗体；渐变色只取一种颜色。

### 其他
- 11-07 有一次闪退发生在视频悬停预览上，已经加了防护和开关（`MediaThumb.hoverPreview`、`run_flag.dart`）。
- README 停在早期版本，以本文为准。

### 写代码常见的坑（CI 经常因为这些失败）
- `clamp` 的参数要写成 `1.0`，不能写 `1`。
- 漏 import。`baseNameOf` 在 `ui/send_page.dart`；`randomId` 在 `services/settings.dart`；`DiagLog` 在 `package:localroll_core`。
- 可空变量在闭包里不会自动提升成非空。
- 没用到的 import 或字段会报 warning，算失败。
- 常量要用小驼峰命名，例如不能写 `_3gp`。
- C++ 在 `WIN32_LEAN_AND_MEAN` 下要自己 include `shellapi.h`。
- 字符串插值里不能放方法名：`${s.server.folderPath}` 是函数，不是路径。
- 改 `windows/pdf/pdf.cpp`，最好先在本地用 MinGW 编译一下。
- PowerShell 调 Office 或剪贴板时，用 `-EncodedCommand`（UTF-16LE 编码），剪贴板还要加 `-STA`。

---

## 8. 需要继续做的事（按建议顺序）

1. **用户真机测 beta.123–124**：剪贴板发送、从媒体库选文件、浅色对话框和字体、传输进度卡、格式转换（重点测 Office 相关的几项）。根据用户发来的日志修问题。
2. **统一入口**：媒体库多选条上的「转换」改成打开新的格式转换模块；然后考虑删除旧的 `convert_dialog.dart`。
3. **其他页面换新风格**：等用户给风格参考图。
4. **录屏增强**：ddagrab、画质选项、录前检查、中断后找回、放大、打码等。
5. **集中真机回归测试一轮** → 准备对外发布：
   - **先把仓库改成私有**，换 LICENSE，检查依赖许可；
   - 做安装包和代码签名；
   - iPhone 上 TestFlight。
6. 以后再说：浮动面板改进、人脸模型改成可选、手机端补图章 / 录讲解、远程访问、收费。

---

## 9. 新会话快速上手清单

1. 读完本文，再读最近 3–5 篇《betaNNN-…》。
2. `add_repo`（lixuedenon / localroll，push），然后 `git clone --depth 1` 到 `/home/claude/localroll`。
3. 用户提出需求 → 先分析，并给示意图（如果涉及界面）→ 等用户说「开始」。
4. 改代码（每个文件第一行写路径注释）→ 补 17 种语言并运行 `gen_l10n.py --check` → 提交、推送 → 等 CI 通过。
5. 写发版脚本 `relNNN.sh`，在后台运行 → 等到 `RELEASED N`。
6. 写《betaNNN-…》项目文档 → 用中文给用户命令行，说明测什么，并提醒「只确认了编译通过，请在真机上看一下」。

---

## 10. 相关项目文档

- 每版记录：《beta82…》到《beta124-浅色对话框-传输进度卡-格式转换模块》。
- 方案类：
  - 《总体规划-当前版》
  - 《路线图-拓展方向》
  - 《播放器-功能清单与方案》
  - 《画笔图章与行业包-方案》
  - 《录制保存与查找-方案》
  - 《文件传输改进-对标LocalSend》
  - 《商业模式与收费功能》
  - 《竞品与差异化》
- 早期：《MVP范围与关键细节》《v1-代码分析与改进方案》《v2-产品方向与架构建议》《开发进度》（只记到 beta.38）。
