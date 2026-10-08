<!-- docs/ARCHITECTURE.md -->
# LocalRoll 架构与协议

## 组成

| 模块 | 作用 | 关键依赖 |
|---|---|---|
| `packages/core` | 协议常量、数据模型、配对二维码编码、流式 SHA-256 | `crypto` |
| `apps/desktop` | HTTP 接收服务、媒体库索引、缩略图/预览、转换队列、UI | `media_kit`（libmpv 播放）、`nsd`（mDNS 广播）、`qr_flutter`、ffmpeg.exe |
| `apps/mobile` | 读取相册原片、发现/配对电脑、分块断点续传 | `photo_manager`、`nsd`、`mobile_scanner`、`wakelock_plus` |

为什么不用 WebRTC：v1 的问题就出在 WebRTC（无 STUN、依赖 mDNS 候选，iPhone↔Windows 经常连不上）。手机本来就能通过 HTTP 访问电脑，直接 HTTP 分块上传最稳。

为什么不用网页上传：iOS Safari 的文件选择器会先导出、常常转码（缩略图上的转圈），拿不到稳定的原片。原生 App 通过 PhotoKit / MediaStore 直接读原始数据。

## 网络

- 电脑监听 TCP **53530**（与 LocalSend 的 53317 错开，可以同时运行）。
- mDNS 服务类型 `_localroll._tcp`，TXT `id=<电脑 deviceId>`。
- 配对二维码：`LOCALROLL:` + base64url(JSON `{v,id,name,hosts[],port,pin}`)。`hosts` 已把 Hyper-V/WSL/VPN 等虚拟网卡排到最后。

## 协议 v1（HTTP/1.1，JSON + 原始字节）

认证：配对后每个请求带 `x-lr-device: <手机 deviceId>` 和 `x-lr-token: <token>`。

```
GET  /api/v1/info                         -> DeviceInfo                 （无需认证）
POST /api/v1/pair      {device, pin}      -> {token, desktop}           （PIN 错 5 次自动换新 PIN）
POST /api/v1/sessions  {files:[FileOffer]}-> {sessionId, results:{fileId:{status, offset}}}
                                             status = duplicate（已有，跳过）| ready（从 offset 续传）
GET  /api/v1/sessions/S/files/F           -> {offset}
PUT  /api/v1/sessions/S/files/F?offset=N&total=T   <8 MB 原始字节>  -> {offset}
                                             offset 与电脑上已有长度不一致时返回 409 {offset}
POST /api/v1/sessions/S/files/F/complete  {size, sha256} -> {saved, path}
                                             电脑重新计算整个文件的 SHA-256，不一致返回 422 并删除临时文件
```

### 续传如何做到跨会话

临时文件名 = `shortKey(手机deviceId | assetId | modifiedMs)`，存在 `<媒体库>/.localroll/incoming/`。所以 App 被杀、Wi-Fi 断开、电脑重启后，新会话仍能从已收到的字节继续。照片被编辑过（modifiedMs 变化）会重新传。

### 去重

电脑索引里记录 `(deviceId, assetId)`；同一张照片再次发送时 `/sessions` 直接返回 `duplicate`，手机连原片都不用读取（对 iCloud 上的照片尤其省时间）。

## 电脑端存储

```
<媒体库>/2026/10/IMG_1234.HEIC         原片（文件修改时间 = 拍摄时间）
<媒体库>/_converted/compatible/2026/10/IMG_1234.mp4
<媒体库>/.localroll/index.json           媒体库索引
<媒体库>/.localroll/incoming/*.part      未完成的上传
<媒体库>/.localroll/cache/*.jpg          缩略图与 HEIC 预览
%APPDATA%\...\settings.json              设备名、端口、已配对手机、ffmpeg 路径
```

## 转换参数

- 视频「通用高质量」：`libx264 -crf 18 -preset slow -profile:v high`，AAC 192k，`-map_metadata 0 -movflags +faststart+use_metadata_tags`（保留拍摄时间、GPS）。
- HDR（`color_transfer` 为 `arib-std-b67` HLG 或 `smpte2084` PQ）：`zscale → tonemap=hable → bt709`，否则画面发灰。
- 「分享小体积」：长边 ≤ 1920，CRF 23，AAC 128k；照片长边 ≤ 2048。
- 照片：ffmpeg 解码 HEIC（需 7.1+）→ JPEG（`-q:v 2`）。

## 下一步（建议顺序）

1. Live Photo：同时发送 `originFileWithSubtype`（MOV），电脑端配对显示。
2. exiftool：转换后的 JPEG 写回 EXIF。
3. 传完清理手机空间（iOS PhotoKit / Android MediaStore 删除请求，系统弹窗确认）。
4. 后台传输（iOS `URLSession` background、Android WorkManager）。
5. 安装包（MSIX 或 Inno Setup）+ 安装时添加防火墙规则 + 代码签名。
