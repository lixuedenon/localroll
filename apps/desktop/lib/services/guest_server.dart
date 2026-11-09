// apps/desktop/lib/services/guest_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import 'library_index.dart';
import 'network.dart';
import 'received_files.dart';

/// A guest's file (shared with them, or received from them).
class GuestFile {
  GuestFile(this.path, this.name, this.size) : id = ++_next;

  static int _next = 0;

  /// Stays the same while the list changes (the page asks by it).
  final int id;
  final String path;
  final String name;
  final int size;
}

/// What a guest wants to send: asked on this PC first.
typedef GuestOffer = ({String guest, List<({String name, int size})> files});

/// Visitors without LocalRoll: their phone or computer opens a page in the
/// browser (scan the QR code, or type this PC's address and the 6-digit
/// code) on the same network, sends files here (each batch is accepted on
/// this PC first) and downloads what this PC shares with them. Only while
/// the guest window is open, at most [life] each time; nothing goes through
/// the internet.
class GuestServer extends ChangeNotifier {
  GuestServer(this.s);

  final AppServices s;

  static const Duration life = Duration(minutes: 10);

  HttpServer? _http;
  int port = 0;
  String code = '';
  List<String> addresses = const [];
  DateTime? until;
  Timer? _timer;

  /// Shared with the guests (downloads).
  final List<GuestFile> shared = [];

  /// Received from guests this time.
  final List<GuestFile> received = [];

  /// Guests who joined (names they gave).
  final Set<String> guests = {};

  /// Asks the person at this PC; true: accept.
  Future<bool> Function(GuestOffer offer)? ask;

  final Map<String, String> _tokens = {}; // token -> guest name
  final Map<String, Set<String>> _allowed = {}; // batch -> file names allowed
  final Map<String, (int, DateTime)> _wrong = {}; // ip -> tries, since

  bool get running => _http != null;

  /// The address to type (short: no port when it is 80).
  String get shortAddress => addresses.isEmpty ? '' : (port == 80 ? addresses.first : '${addresses.first}:$port');

  /// What the QR code opens (the code in it: no typing).
  String get link => addresses.isEmpty ? '' : 'http://$shortAddress/?c=$code';

  Future<bool> start() async {
    if (_http != null) {
      extend();
      return true;
    }
    for (final p in const [80, 8080, 8090, 8888]) {
      try {
        _http = await HttpServer.bind(InternetAddress.anyIPv4, p);
        port = p;
        break;
      } catch (_) {}
    }
    final http = _http;
    if (http == null) return false;
    code = (Random.secure().nextInt(900000) + 100000).toString();
    addresses = await localIPv4Addresses();
    _tokens.clear();
    _allowed.clear();
    guests.clear();
    received.clear();
    http.listen((req) => unawaited(_handle(req).catchError((Object e) {
          DiagLog.log('guest', 'request failed: $e');
          try {
            req.response.statusCode = 500;
            unawaited(req.response.close());
          } catch (_) {}
        })));
    extend();
    DiagLog.log('guest', 'guest page open on port $port');
    notifyListeners();
    return true;
  }

  /// Another [life] from now.
  void extend() {
    until = DateTime.now().add(life);
    _timer?.cancel();
    _timer = Timer(life, () => unawaited(stop()));
    notifyListeners();
  }

  Future<void> stop() async {
    _timer?.cancel();
    final http = _http;
    _http = null;
    _tokens.clear();
    until = null;
    await http?.close(force: true);
    if (http != null) DiagLog.log('guest', 'guest page closed');
    notifyListeners();
  }

  void share(List<String> paths) {
    for (final p in paths) {
      if (shared.any((x) => x.path == p)) continue;
      try {
        final f = File(p);
        shared.add(GuestFile(p, p.split(RegExp(r'[\\/]')).last, f.lengthSync()));
      } catch (_) {}
    }
    notifyListeners();
  }

  /// All shared files fit in one plain .zip (no ZIP64: under 4 GB).
  bool get zipOk => shared.length > 1 && shared.fold<int>(0, (n, f) => n + f.size) < 0xF0000000;

  void unshare(GuestFile f) {
    shared.remove(f);
    notifyListeners();
  }

  // ---------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final r = req.response;
    r.headers.set('Cache-Control', 'no-store');
    r.headers.set('X-Content-Type-Options', 'nosniff');
    final path = req.uri.path;
    if (req.method == 'GET' && (path == '/' || path == '/index.html')) {
      final zh = (req.headers.value('accept-language') ?? '').toLowerCase().startsWith('zh');
      r.headers.contentType = ContentType.html;
      r.write(guestPage(zh: zh));
      return r.close();
    }
    if (req.method == 'POST' && path == '/api/join') return _join(req);
    final guest = _tokens[req.uri.queryParameters['t'] ?? ''];
    if (guest == null) return _json(r, 403, {'ok': false});
    extend();
    if (req.method == 'GET' && path == '/api/list') {
      return _json(r, 200, {
        'ok': true,
        'files': [for (final f in shared) {'i': f.id, 'name': f.name, 'size': f.size}],
        'zip': zipOk,
      });
    }
    if (req.method == 'GET' && path.startsWith('/api/get/')) {
      final i = int.tryParse(path.substring(9));
      final f = shared.where((x) => x.id == i).firstOrNull;
      if (f == null) return _json(r, 404, {'ok': false});
      // The real type: the phone then knows a photo is a photo (gallery).
      r.headers.contentType = ContentType.parse(mimeOf(f.name));
      r.headers.set('Content-Disposition', "attachment; filename*=UTF-8''${Uri.encodeComponent(f.name)}");
      r.headers.contentLength = f.size;
      await r.addStream(File(f.path).openRead());
      return r.close();
    }
    if (req.method == 'GET' && path == '/api/zip') return _zip(r);
    if (req.method == 'POST' && path == '/api/offer') return _offer(req, guest);
    if (req.method == 'PUT' && path == '/api/up') return _upload(req, guest);
    return _json(r, 404, {'ok': false});
  }

  Future<void> _join(HttpRequest req) async {
    final ip = req.connectionInfo?.remoteAddress.address ?? '';
    final w = _wrong[ip];
    if (w != null && w.$1 >= 5 && DateTime.now().difference(w.$2) < const Duration(minutes: 1)) {
      return _json(req.response, 429, {'ok': false, 'wait': true});
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    } catch (_) {
      return _json(req.response, 400, {'ok': false});
    }
    if ('${j['code']}'.trim() != code) {
      final n = (w == null || DateTime.now().difference(w.$2) > const Duration(minutes: 1)) ? 1 : w.$1 + 1;
      _wrong[ip] = (n, w == null || n == 1 ? DateTime.now() : w.$2);
      return _json(req.response, 403, {'ok': false});
    }
    _wrong.remove(ip);
    final name = '${j['name'] ?? ''}'.trim();
    final guest = name.isEmpty ? 'Guest ${ip.split('.').last}' : (name.length > 30 ? name.substring(0, 30) : name);
    final token = base64Url.encode(List.generate(18, (_) => Random.secure().nextInt(256)));
    _tokens[token] = guest;
    guests.add(guest);
    notifyListeners();
    DiagLog.log('guest', 'a guest joined');
    return _json(req.response, 200, {'ok': true, 'token': token, 'pc': s.settings.deviceName});
  }

  Future<void> _offer(HttpRequest req, String guest) async {
    Map<String, dynamic> j;
    try {
      j = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    } catch (_) {
      return _json(req.response, 400, {'ok': false});
    }
    final files = [
      for (final f in (j['files'] as List? ?? const []))
        if (f is Map) (name: sanitizeFileName('${f['name']}'), size: (f['size'] as num?)?.toInt() ?? 0),
    ];
    if (files.isEmpty) return _json(req.response, 400, {'ok': false});
    final ok = await (ask?.call((guest: guest, files: files)) ?? Future.value(false));
    if (!ok) return _json(req.response, 200, {'ok': false});
    final batch = base64Url.encode(List.generate(12, (_) => Random.secure().nextInt(256)));
    _allowed[batch] = {for (final f in files) f.name};
    return _json(req.response, 200, {'ok': true, 'batch': batch});
  }

  Future<void> _upload(HttpRequest req, String guest) async {
    final q = req.uri.queryParameters;
    final name = sanitizeFileName(q['n'] ?? '');
    final allowed = _allowed[q['b'] ?? ''];
    if (allowed == null || !allowed.remove(name)) return _json(req.response, 403, {'ok': false});
    final sep = Platform.pathSeparator;
    final ext = extensionOf(name);
    final kind = imageExtensions.contains(ext) ? MediaKind.image : (videoExtensions.contains(ext) ? MediaKind.video : MediaKind.other);
    final now = DateTime.now();
    final String folder;
    if (kind == MediaKind.other) {
      folder = await s.server.folderPath(document: isDocumentName(name));
    } else {
      folder = '${s.library.rootPath}$sep${now.year}$sep${now.month.toString().padLeft(2, '0')}';
    }
    await Directory(folder).create(recursive: true);
    final dest = LibraryIndex.uniquePath(folder, name);
    final part = File('$dest.part');
    final sink = part.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var length = 0;
    try {
      await for (final chunk in req) {
        sink.add(chunk);
        hasher.add(chunk);
        length += chunk.length;
      }
      await sink.close();
      hasher.close();
    } catch (e) {
      await sink.close();
      try {
        await part.delete();
      } catch (_) {}
      return _json(req.response, 500, {'ok': false});
    }
    await part.rename(dest);
    if (kind == MediaKind.other) {
      await s.server.files.received(dest, FileOwner('guest', guest));
    } else {
      final rel = dest.substring(s.library.rootPath.length + 1).replaceAll(sep, '/');
      s.library.add(MediaItem(
        relPath: rel,
        name: rel.substring(rel.lastIndexOf('/') + 1),
        size: length,
        kind: kind,
        captureMs: now.millisecondsSinceEpoch,
        receivedMs: now.millisecondsSinceEpoch,
        sha256: digest.value?.toString(),
        deviceId: 'guest',
        deviceName: guest,
        assetId: 'guest-${now.microsecondsSinceEpoch}',
        private: false,
      ));
    }
    received.insert(0, GuestFile(dest, name, length));
    notifyListeners();
    DiagLog.log('guest', 'received a file from a guest (${length ~/ 1024} KB)');
    return _json(req.response, 200, {'ok': true});
  }

  /// Everything shared, as one .zip streamed as it is read (stored, not
  /// compressed: photos and videos are compressed already).
  Future<void> _zip(HttpResponse r) async {
    if (!zipOk) return _json(r, 404, {'ok': false});
    final now = DateTime.now();
    r.headers.contentType = ContentType.parse('application/zip');
    r.headers.set('Content-Disposition', "attachment; filename*=UTF-8''${Uri.encodeComponent('Keepnear-${now.month}-${now.day}.zip')}");
    final dosTime = (now.hour << 11) | (now.minute << 5) | (now.second ~/ 2);
    final dosDate = ((now.year - 1980) << 9) | (now.month << 5) | now.day;
    final central = BytesBuilder();
    var offset = 0;
    final names = <String>{};
    for (final f in List.of(shared)) {
      var name = f.name;
      for (var k = 2; !names.add(name); k++) {
        final dot = f.name.lastIndexOf('.');
        name = dot > 0 ? '${f.name.substring(0, dot)} ($k)${f.name.substring(dot)}' : '${f.name} ($k)';
      }
      final n = utf8.encode(name);
      final head = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 0x0808, Endian.little) // sizes after the data; UTF-8 names
        ..setUint16(8, 0, Endian.little)
        ..setUint16(10, dosTime, Endian.little)
        ..setUint16(12, dosDate, Endian.little)
        ..setUint16(26, n.length, Endian.little);
      r.add(head.buffer.asUint8List());
      r.add(n);
      var crc = 0xFFFFFFFF, size = 0;
      await for (final chunk in File(f.path).openRead()) {
        crc = _crc32(crc, chunk);
        size += chunk.length;
        r.add(chunk);
      }
      crc ^= 0xFFFFFFFF;
      final desc = ByteData(16)
        ..setUint32(0, 0x08074b50, Endian.little)
        ..setUint32(4, crc, Endian.little)
        ..setUint32(8, size, Endian.little)
        ..setUint32(12, size, Endian.little);
      r.add(desc.buffer.asUint8List());
      final c = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0808, Endian.little)
        ..setUint16(12, dosTime, Endian.little)
        ..setUint16(14, dosDate, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, size, Endian.little)
        ..setUint32(24, size, Endian.little)
        ..setUint16(28, n.length, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central
        ..add(c.buffer.asUint8List())
        ..add(n);
      offset += 30 + n.length + size + 16;
    }
    final cd = central.takeBytes();
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, names.length, Endian.little)
      ..setUint16(10, names.length, Endian.little)
      ..setUint32(12, cd.length, Endian.little)
      ..setUint32(16, offset, Endian.little);
    r.add(cd);
    r.add(end.buffer.asUint8List());
    DiagLog.log('guest', 'a guest downloaded the zip (${names.length} files)');
    await r.close();
  }

  static final List<int> _crcTable = List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc32(int crc, List<int> data) {
    for (final b in data) {
      crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return crc;
  }

  Future<void> _json(HttpResponse r, int status, Map<String, Object?> body) async {
    r.statusCode = status;
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    await r.close();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// The type a browser needs to know what a file is.
String mimeOf(String name) => switch (extensionOf(name)) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'bmp' => 'image/bmp',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      '3gp' => 'video/3gpp',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain; charset=utf-8',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };

/// Adds a firewall rule for the guest page's port (asks for admin once;
/// skipped when the rule is there).
Future<bool> allowGuestPort(int port) async {
  if (!Platform.isWindows) return false;
  try {
    final has = await Process.run('netsh', ['advfirewall', 'firewall', 'show', 'rule', 'name=LocalRoll Guest $port']);
    if (has.exitCode == 0 && '${has.stdout}'.contains('$port')) return true;
    final cmd = 'netsh advfirewall firewall add rule name=\\"LocalRoll Guest $port\\" dir=in action=allow protocol=TCP localport=$port profile=private,domain';
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath cmd -ArgumentList '/c $cmd' -Verb RunAs -Wait -WindowStyle Hidden",
    ]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// The page a guest sees (no app needed): join with the code, send files,
/// download what is shared. Chinese or English by the browser's language.
String guestPage({required bool zh}) {
  final t = zh
      ? {
          'title': 'Keepnear 访客传输',
          'code': '输入电脑上显示的 6 位连接码',
          'name': '你的名字（可不填）',
          'join': '连接',
          'bad': '连接码不对，请再看一下电脑屏幕',
          'wait': '试错太多次，请 1 分钟后再试',
          'send': '发送文件到电脑',
          'pick': '选择照片或文件',
          'asking': '等待电脑上确认…',
          'declined': '电脑上没有接受',
          'done': '已发送',
          'get': '电脑分享给你的文件',
          'none': '暂时没有',
          'keep': '传送时请不要关闭这个页面或锁屏',
          'connected': '已连接到',
          'dl': '下载',
          'all': '全部下载',
          'zip': '打包下载（一个 zip）',
          'saved': '已下载',
          'failed': '没下载成功，再点一次',
          'open': '打开',
          'save': '保存到手机',
          'press': '长按上面的照片 →「存储到照片」/「保存图片」',
          'ios': '<b>存进相册：</b>一张照片——下载后长按照片 →「存储到照片」。<br><b>很多照片 / 视频：</b>点「打包下载」→ 打开「文件」App →「下载」→ 点一下 zip 解开 → 打开解出的文件夹 → 右上角「选择」→ 全选 → 分享 →「存储 N 个项目」，一次全部进相册。<br>PDF / Office：下载后点「打开」查看，或「保存到手机」存进「文件」App。',
          'android': '下载的照片和视频会出现在相册的「Download / 下载」相册里，不用再一张张保存；其他文件在「文件管理 → Download」。下载后也可以点「打开」查看。',
          'pc': '文件会存到这台电脑的「下载」文件夹。',
          'app': '常传的话，装 Keepnear App，照片会直接存进相册。',
        }
      : {
          'title': 'Keepnear guest transfer',
          'code': 'Enter the 6-digit code shown on the computer',
          'name': 'Your name (optional)',
          'join': 'Connect',
          'bad': 'Wrong code — please check the computer screen',
          'wait': 'Too many tries — please wait a minute',
          'send': 'Send files to the computer',
          'pick': 'Choose photos or files',
          'asking': 'Waiting for the computer to accept…',
          'declined': 'Not accepted on the computer',
          'done': 'Sent',
          'get': 'Files shared with you',
          'none': 'Nothing yet',
          'keep': 'Keep this page open (and the screen on) while sending',
          'connected': 'Connected to',
          'dl': 'Download',
          'all': 'Download all',
          'zip': 'Download as one zip',
          'saved': 'Downloaded',
          'failed': 'Failed — tap again',
          'open': 'Open',
          'save': 'Save to phone',
          'press': 'Long-press the photo above → "Save to Photos" / "Download image"',
          'ios': '<b>Into Photos:</b> one photo — after downloading, long-press it → "Save to Photos".<br><b>Many photos / videos:</b> tap "Download as one zip" → Files app → Downloads → tap the zip to unpack → open the folder → Select → Select All → Share → "Save N Items".<br>PDF / Office: tap "Open" to view, or "Save to phone" to keep it in Files.',
          'android': 'Downloaded photos and videos show up in your gallery (album "Download"); other files are in Files → Download. You can also tap "Open".',
          'pc': 'Files are saved to this computer\'s Downloads folder.',
          'app': 'Sending often? With the Keepnear app, photos go straight into your photo library.',
        };
  final js = jsonEncode(t);
  return '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${t['title']}</title><style>
*{box-sizing:border-box}body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;background:#eef4ff;color:#16213e}
.wrap{max-width:560px;margin:0 auto;padding:20px 16px 40px}h1{font-size:22px;margin:8px 0 16px;color:#2f6bff}
.card{background:#fff;border-radius:16px;padding:18px;margin-bottom:14px;box-shadow:0 4px 16px #1d3b8a14}
input[type=text],input[type=tel]{width:100%;font-size:20px;padding:12px;border:2px solid #d0dbf0;border-radius:12px;margin:6px 0}
#code{letter-spacing:8px;text-align:center;font-size:28px}
button,.btn{display:block;width:100%;font-size:18px;padding:14px;border:0;border-radius:12px;background:#2f6bff;color:#fff;font-weight:600;cursor:pointer;text-align:center}
.muted{color:#6b7a99;font-size:14px}.err{color:#e5484d;margin-top:8px}.row{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid #eef1f7;gap:8px}
.row a{color:#2f6bff;font-weight:600;text-decoration:none;white-space:nowrap}.bar{height:6px;background:#e3e9f5;border-radius:3px;overflow:hidden;margin-top:6px}.bar i{display:block;height:100%;background:#2fb344;width:0}
.hide{display:none}.name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;min-width:0}
.sb{width:auto;display:inline-block;font-size:15px;padding:8px 14px;border-radius:10px;white-space:nowrap}.sb.light{background:#e8efff;color:#2f6bff}
.item{border-bottom:1px solid #eef1f7;padding:8px 0}.item .row{border:0;padding:2px 0}.prev{max-width:100%;border-radius:10px;margin-top:6px;display:block}
.tip{background:#f3f7ff;border-radius:12px;padding:12px;font-size:14px;line-height:1.6;color:#33415e;margin-top:12px}.ok{color:#2fb344;font-weight:600;white-space:nowrap}
.btns{display:flex;gap:8px;margin-top:10px}.btns .sb{flex:1;text-align:center}
</style></head><body><div class="wrap"><h1>${t['title']}</h1>
<div id="join" class="card"><div class="muted" id="lc"></div><input id="code" type="tel" inputmode="numeric" maxlength="6" autocomplete="one-time-code">
<input id="name" type="text" maxlength="30"><button id="go"></button><div id="err" class="err"></div></div>
<div id="main" class="hide"><div class="card"><div class="muted" id="pc"></div><h3 id="ls"></h3>
<label class="btn" for="files" id="lp"></label><input id="files" type="file" multiple class="hide"><div class="muted" id="lk" style="margin-top:10px"></div><div id="up"></div></div>
<div class="card"><h3 id="lg"></h3><div id="list" class="muted"></div><div class="btns"><button class="sb" id="ball"></button><a class="sb btn light hide" id="bzip"></a></div>
<div class="tip" id="tip"></div></div></div></div>
<script>
const T=$js;let tok='';const q=new URLSearchParams(location.search);
const \$=id=>document.getElementById(id);\$('lc').textContent=T.code;\$('name').placeholder=T.name;\$('go').textContent=T.join;
\$('ls').textContent=T.send;\$('lp').textContent=T.pick;\$('lk').textContent=T.keep;\$('lg').textContent=T.get;
if(q.get('c'))\$('code').value=q.get('c');
function size(n){return n>1048576?(n/1048576).toFixed(1)+' MB':Math.max(1,Math.round(n/1024))+' KB'}
async function join(){const r=await fetch('/api/join',{method:'POST',body:JSON.stringify({code:\$('code').value,name:\$('name').value})});
if(r.status==429){\$('err').textContent=T.wait;return}const j=await r.json().catch(()=>({}));if(!j.ok){\$('err').textContent=T.bad;return}
tok=j.token;\$('join').classList.add('hide');\$('main').classList.remove('hide');\$('pc').textContent=T.connected+' '+j.pc;list();setInterval(list,5000)}
\$('go').onclick=join;
const ua=navigator.userAgent,IOS=/iP(hone|ad|od)/.test(ua)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1),AND=/Android/i.test(ua);
\$('tip').innerHTML=(IOS?T.ios:AND?T.android:T.pc)+(IOS||AND?'<br><span class="muted">'+T.app+'</span>':'');\$('ball').textContent=T.all;\$('bzip').textContent=T.zip;
let files=[],sig='';const st={};const BIG=300*1048576;
const isImg=n=>/\\.(jpe?g|png|gif|webp|heic|heif|bmp)\$/i.test(n);
const u=f=>'/api/get/'+f.i+'?t='+encodeURIComponent(tok);
async function list(){const r=await fetch('/api/list?t='+encodeURIComponent(tok));const j=await r.json().catch(()=>({}));if(!j.ok)return;
files=j.files;\$('bzip').href='/api/zip?t='+encodeURIComponent(tok);\$('bzip').classList.toggle('hide',!j.zip);\$('ball').classList.toggle('hide',files.length<2||IOS);
const ns=JSON.stringify(files);if(ns!==sig){sig=ns;draw()}}
function save(url,name){const a=document.createElement('a');a.href=url;a.download=name;document.body.appendChild(a);a.click();a.remove()}
function draw(){const l=\$('list');l.innerHTML='';if(!files.length){l.textContent=T.none;return}
for(const f of files){const s=st[f.i]||{};const d=document.createElement('div');d.className='item';
d.innerHTML='<div class="row"><span class="name"></span><span class="act"></span></div>';d.querySelector('.name').textContent=f.name+' · '+size(f.size);
const act=d.querySelector('.act');
if(s.s=='run'){act.innerHTML='<span class="muted" id="t'+f.i+'">0%</span>';d.insertAdjacentHTML('beforeend','<div class="bar"><i id="p'+f.i+'"></i></div>')}
else if(s.s=='done'){act.innerHTML='<span class="ok">✓ '+T.saved+'</span>';
 if(s.url&&!isImg(f.name)){const o=document.createElement('a');o.className='sb btn light';o.style.marginLeft='6px';o.textContent=T.open;o.href=s.url;o.target='_blank';act.appendChild(o);
  if(IOS){const b=document.createElement('button');b.className='sb light';b.style.marginLeft='6px';b.textContent=T.save;b.onclick=()=>save(s.url,f.name);act.appendChild(b)}}
 if(s.url&&isImg(f.name)){const im=document.createElement('img');im.className='prev';im.src=s.url;d.appendChild(im);if(IOS||AND)d.insertAdjacentHTML('beforeend','<div class="muted">'+T.press+'</div>')}}
else{const b=document.createElement('button');b.className='sb';b.textContent=s.s=='err'?T.failed:T.dl;b.onclick=()=>dl(f);act.appendChild(b)}
l.appendChild(d)}}
async function dl(f){const s=st[f.i];if(s&&s.s=='run')return;
if(f.size>BIG){save(u(f),f.name);st[f.i]={s:'done'};draw();return}
st[f.i]={s:'run'};draw();
try{const r=await fetch(u(f));if(!r.ok)throw 0;const rd=r.body.getReader(),parts=[];let got=0;
for(;;){const x=await rd.read();if(x.done)break;parts.push(x.value);got+=x.value.length;const p=Math.min(100,Math.round(got*100/Math.max(1,f.size)));
const e=document.getElementById('p'+f.i);if(e)e.style.width=p+'%';const t=document.getElementById('t'+f.i);if(t)t.textContent=p+'%'}
const url=URL.createObjectURL(new Blob(parts,{type:r.headers.get('content-type')||''}));
if(!IOS)save(url,f.name);st[f.i]={s:'done',url}}catch(e){st[f.i]={s:'err'}}draw()}
\$('ball').onclick=async()=>{for(const f of files){const s=st[f.i];if(!s||s.s=='err')await dl(f)}};
\$('files').onchange=async e=>{const fs=[...e.target.files];if(!fs.length)return;const up=\$('up');up.innerHTML='<div class="muted">'+T.asking+'</div>';
const r=await fetch('/api/offer?t='+encodeURIComponent(tok),{method:'POST',body:JSON.stringify({files:fs.map(f=>({name:f.name,size:f.size}))})});
const j=await r.json().catch(()=>({}));if(!j.ok){up.innerHTML='<div class="err">'+T.declined+'</div>';e.target.value='';return}up.innerHTML='';
for(const f of fs){const d=document.createElement('div');d.style.marginTop='10px';d.innerHTML='<div class="name"></div><div class="bar"><i></i></div>';d.querySelector('.name').textContent=f.name;up.appendChild(d);
await new Promise(res=>{const x=new XMLHttpRequest();x.open('PUT','/api/up?t='+encodeURIComponent(tok)+'&b='+encodeURIComponent(j.batch)+'&n='+encodeURIComponent(f.name));
x.upload.onprogress=ev=>{if(ev.lengthComputable)d.querySelector('i').style.width=(ev.loaded*100/ev.total)+'%'};
x.onload=x.onerror=()=>{d.querySelector('i').style.width='100%';d.querySelector('.name').textContent=f.name+' ✓ '+T.done;res()};x.send(f)})}
e.target.value=''};
if(q.get('c')&&q.get('c').length==6)join();
</script></body></html>''';
}
