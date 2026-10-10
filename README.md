<!-- README.md -->
# LocalRoll

把 iPhone / Android 手机里的**原片**照片和视频，通过家里的 Wi-Fi 直接传到 Windows 电脑，收到后马上能看、能播放，需要时再高质量转换。全程本地，不经过任何云端。

- **手机端（iOS + Android）**：直接读取相册原片，不转码、不用等转圈，支持断点续传，传完由电脑做 SHA-256 校验。
- **电脑端（Windows）**：接收 + 媒体库 + 播放器 + 转换器。HEIC、HEVC、HDR、杜比视界原片直接打开。
- **转换**：原片永远保留。「通用高质量」（H.264 CRF 18，HDR→SDR 色调映射，保留拍摄时间/GPS）和「分享小体积」两种预设。

## 目录结构

```
apps/desktop/     Windows 应用（Flutter）：接收服务、媒体库、查看器、转换
apps/mobile/      手机应用（Flutter，iOS + Android）：选原片、发现电脑、分块上传
packages/core/    两端共用：传输协议、数据模型、SHA-256
scripts/          patch_platforms.py：给 flutter create 生成的平台文件夹加权限等配置
docs/             架构与协议说明
.github/workflows CI：分析、测试、构建 Windows / Android / iOS（云端 Mac）
```

## 本地开发（Windows）

需要：Flutter 3.35+、Visual Studio（含「使用 C++ 的桌面开发」）、Android Studio。

```powershell
cd C:\Users\lixue\Projects
git clone https://github.com/lixuedenon/localroll.git
cd localroll

# 共享包
cd packages\core;  dart pub get;  dart test;  cd ..\..

# 电脑端
cd apps\desktop
flutter pub get
flutter run -d windows

# 手机端（另开一个终端，手机用 USB 连接并打开开发者模式）
cd apps\mobile
flutter pub get
flutter run
```

> 平台文件夹（`apps/desktop/windows`、`apps/mobile/android`、`apps/mobile/ios`）由 CI 第一次运行时自动生成并提交。如果你本地还没有，先 `git pull`。

### ffmpeg

HEIC 显示、缩略图和转换需要 ffmpeg **7.1 或更新版本**。CI 构建出的 Windows 包已经自带（`ffmpeg\ffmpeg.exe`）。本地 `flutter run` 时，任选一种：

1. 把 `ffmpeg.exe` 和 `ffprobe.exe` 放进系统 PATH；或
2. 在应用「设置」里填写 `ffmpeg.exe` 的完整路径。

下载：<https://github.com/BtbN/FFmpeg-Builds/releases>（`ffmpeg-master-latest-win64-gpl.zip`）。

## 不用 Mac 也能装到 iPhone

1. 每次推送到 `main`，GitHub Actions 会在云端 Mac 上编译，产出 `LocalRoll-iOS-unsigned`（在仓库 **Actions** 页面对应运行的 Artifacts 里下载）。
2. 在 Windows 上安装 [Sideloadly](https://sideloadly.io/)，用你的 Apple ID 给这个 `.ipa` 签名并装到 iPhone。
3. 免费 Apple ID 签的应用 7 天后过期，需要重新安装；以后注册 Apple 开发者账号（$99/年）可以用 TestFlight。

Android 测试包：同样在 Artifacts 里下载 `LocalRoll-Android`，直接安装 APK。
Windows 测试包：下载 `LocalRoll-Windows`，解压后运行 `LocalRoll.exe`。

## 使用

1. 电脑打开 LocalRoll → 「接收」页显示二维码和 6 位配对码。
2. 手机打开 LocalRoll → 右上角「连接电脑」→ 扫码（或在自动发现的电脑上输入配对码）。
3. 选照片/视频 →「发送」。以后打开 App 会自动找到已配对的电脑。
4. 手机连不上？在电脑「接收」页点「允许防火墙」，并确认这个 Wi-Fi 在 Windows 里是「专用网络」。

收到的原片按 `年/月` 存在 `图片\LocalRoll`（可在设置里改），转换结果在 `_converted` 子文件夹。

## 多语言

界面支持 17 种语言：English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch、Português、Русский、Italiano、العربية、हिन्दी、Bahasa Indonesia、Tiếng Việt、ไทย、Türkçe。默认跟随系统语言，也可以在电脑端「设置」或手机端右上角的 🌐 按钮里手动切换。

- 翻译文件：`apps/desktop/l10n/<语言>.json`、`apps/mobile/l10n/<语言>.json`（`en.json` 是基准）。
- 改完翻译后运行 `python scripts/gen_l10n.py` 重新生成 `lib/l10n/translations.g.dart`。
- CI 会检查每种语言是否缺词、`{占位符}` 是否一致。
- 加新语言：见 `packages/core/l10n/README.md`。

## 当前限制

- 局域网传输还是 HTTP + 配对令牌，没有加密（计划：HTTPS + 配对时核对证书指纹）。
- 家庭组的"仅自己可见"只在 LocalRoll 里隐藏，电脑文件夹本身不加密（计划：Pro 私密保险箱）。
- 还不能在外面（不在同一个 Wi-Fi）连回家里的电脑。
- 翻译说明见 `packages/core/l10n/README.md`。

## 许可

本项目以 **GNU General Public License v3.0**（GPL-3.0）开源，全文见 [LICENSE](LICENSE)。
你可以自由使用、修改和分发；分发修改后的版本时，必须同样以 GPL-3.0 公开源代码。
Windows 版打包的 ffmpeg 也是 GPL 构建，与本许可兼容。
