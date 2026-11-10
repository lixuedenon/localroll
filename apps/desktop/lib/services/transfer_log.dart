// apps/desktop/lib/services/transfer_log.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'settings.dart' show randomId;

/// One transfer, as the "Transfers" page lists it afterwards: who, which
/// way, how much, how it ended.
class TransferRecord {
  TransferRecord({
    required this.id,
    required this.out,
    required this.deviceId,
    required this.deviceName,
    required this.title,
    required this.startMs,
    this.files = 0,
    this.done = 0,
    this.bytes = 0,
    this.media = 0,
    this.already = 0,
    this.endMs = 0,
    this.result = 'ok',
    this.text,
    List<String>? paths,
  }) : paths = paths ?? [];

  final String id;

  /// Sent from here (false: received).
  final bool out;
  final String deviceId;
  String deviceName;
  String title;
  final int startMs;
  int endMs;

  /// Files offered / done (saved or sent), bytes, of which photos / videos.
  int files;
  int done;
  int bytes;
  int media;
  int already;

  /// 'ok', 'failed', 'cancelled', 'partial'.
  String result;

  /// Received text (a link, a code…).
  String? text;

  /// Sent: the files (to send again); received: where they went (a few).
  final List<String> paths;

  int get lastMs => endMs > 0 ? endMs : startMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'out': out,
        'dev': deviceId,
        'name': deviceName,
        'title': title,
        'start': startMs,
        'end': endMs,
        'files': files,
        'done': done,
        'bytes': bytes,
        'media': media,
        'already': already,
        'result': result,
        'text': ?text,
        if (paths.isNotEmpty) 'paths': paths,
      };

  static TransferRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return TransferRecord(
        id: j['id'] as String,
        out: j['out'] == true,
        deviceId: j['dev'] as String? ?? '',
        deviceName: j['name'] as String? ?? '',
        title: j['title'] as String? ?? '',
        startMs: (j['start'] as num).toInt(),
        endMs: (j['end'] as num?)?.toInt() ?? 0,
        files: (j['files'] as num?)?.toInt() ?? 0,
        done: (j['done'] as num?)?.toInt() ?? 0,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        media: (j['media'] as num?)?.toInt() ?? 0,
        already: (j['already'] as num?)?.toInt() ?? 0,
        result: j['result'] as String? ?? 'ok',
        text: j['text'] as String?,
        paths: [for (final p in (j['paths'] as List? ?? const [])) if (p is String) p],
      );
    } catch (_) {
      return null;
    }
  }
}

/// What a phone last said it still has to back up here.
class PhoneBackupState {
  const PhoneBackupState(this.pending, this.bytes, this.ms);

  final int pending;
  final int bytes;
  final int ms;

  DateTime get when => DateTime.fromMillisecondsSinceEpoch(ms);
}

/// The transfer history (newest first; at most [keep] records or [keepFor]),
/// kept on this PC, plus what each phone reported about its backup.
class TransferLog extends ChangeNotifier {
  TransferLog(this.dir);

  final Directory dir;
  static const int keep = 500;
  static const Duration keepFor = Duration(days: 90);

  /// Received files that arrive within this time of the last one from the
  /// same device belong to the same record.
  static const Duration together = Duration(minutes: 3);

  final List<TransferRecord> records = [];
  final Map<String, PhoneBackupState> backup = {};
  final Set<String> _logged = {};

  File get _file => File('${dir.path}${Platform.pathSeparator}transfer_log.json');
  File get _backupFile => File('${dir.path}${Platform.pathSeparator}backup_status.json');

  Future<void> load() async {
    try {
      final j = jsonDecode(await _file.readAsString());
      if (j is List) {
        for (final r in j) {
          final t = TransferRecord.fromJson(r);
          if (t != null) records.add(t);
        }
      }
    } catch (_) {}
    try {
      final j = jsonDecode(await _backupFile.readAsString());
      if (j is Map) {
        for (final e in j.entries) {
          final v = e.value;
          if (v is Map) backup['${e.key}'] = PhoneBackupState((v['n'] as num).toInt(), (v['b'] as num?)?.toInt() ?? 0, (v['t'] as num).toInt());
        }
      }
    } catch (_) {}
    _trim();
    notifyListeners();
  }

  void _trim() {
    final oldest = DateTime.now().subtract(keepFor).millisecondsSinceEpoch;
    records.removeWhere((r) => r.lastMs < oldest);
    records.sort((a, b) => b.lastMs.compareTo(a.lastMs));
    if (records.length > keep) records.removeRange(keep, records.length);
  }

  Timer? _saveSoon;

  void _changed() {
    notifyListeners();
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(seconds: 2), () => unawaited(_save()));
  }

  Future<void> _save() async {
    _trim();
    try {
      await _file.writeAsString(jsonEncode([for (final r in records) r.toJson()]));
    } catch (e) {
      DiagLog.log('xfer', 'history not saved: $e');
    }
  }

  void clear() {
    records.clear();
    _changed();
  }

  void remove(TransferRecord r) {
    records.remove(r);
    _changed();
  }

  // ------------------------------------------------------------- received

  TransferRecord _inRecord(String deviceId, String name) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = records.where((r) => !r.out && r.deviceId == deviceId && r.text == null).firstOrNull;
    if (last != null && now - last.lastMs < together.inMilliseconds) {
      last.deviceName = name;
      return last;
    }
    final r = TransferRecord(id: randomId(10), out: false, deviceId: deviceId, deviceName: name, title: '', startMs: now);
    records.insert(0, r);
    return r;
  }

  /// A phone / PC offered [files] files ([already] of them already here).
  void inSession(String deviceId, String name, int files, int bytes, int already) {
    final r = _inRecord(deviceId, name);
    r
      ..files += files
      ..already += already
      ..endMs = DateTime.now().millisecondsSinceEpoch;
    _changed();
  }

  /// One file arrived and was saved at [path].
  void inFile(String deviceId, String name, String path, int bytes, {required bool media}) {
    final r = _inRecord(deviceId, name);
    r
      ..done += 1
      ..bytes += bytes
      ..media += media ? 1 : 0
      ..endMs = DateTime.now().millisecondsSinceEpoch;
    if (r.files < r.done + r.already) r.files = r.done + r.already;
    if (r.paths.length < 20) r.paths.add(path);
    _changed();
  }

  void inText(String deviceId, String name, String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    records.insert(
        0,
        TransferRecord(
          id: randomId(10),
          out: false,
          deviceId: deviceId,
          deviceName: name,
          title: '',
          startMs: now,
          endMs: now,
          files: 1,
          done: 1,
          text: text.length > 2000 ? text.substring(0, 2000) : text,
        ));
    _changed();
  }

  // ------------------------------------------------------------- sent

  /// A send finished ([result] 'ok' / 'failed' / 'cancelled' / 'partial');
  /// recorded once per [jobId].
  void outDone({
    required String jobId,
    required String deviceId,
    required String name,
    required String title,
    required DateTime started,
    required int files,
    required int done,
    required int bytes,
    required int media,
    required String result,
    required List<String> paths,
  }) {
    if (!_logged.add(jobId)) return;
    records.insert(
        0,
        TransferRecord(
          id: jobId,
          out: true,
          deviceId: deviceId,
          deviceName: name,
          title: title,
          startMs: started.millisecondsSinceEpoch,
          endMs: DateTime.now().millisecondsSinceEpoch,
          files: files,
          done: done,
          bytes: bytes,
          media: media,
          result: result,
          paths: paths.length > 2000 ? paths.sublist(0, 2000) : paths,
        ));
    _changed();
  }

  void outText(String deviceId, String name, String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    records.insert(
        0,
        TransferRecord(
          id: randomId(10),
          out: true,
          deviceId: deviceId,
          deviceName: name,
          title: '',
          startMs: now,
          endMs: now,
          files: 1,
          done: 1,
          text: text.length > 2000 ? text.substring(0, 2000) : text,
        ));
    _changed();
  }

  // ------------------------------------------------------------- backup

  void phoneReported(String deviceId, int pending, int bytes) {
    backup[deviceId] = PhoneBackupState(pending, bytes, DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
    unawaited(() async {
      try {
        await _backupFile.writeAsString(jsonEncode({
          for (final e in backup.entries) e.key: {'n': e.value.pending, 'b': e.value.bytes, 't': e.value.ms},
        }));
      } catch (_) {}
    }());
  }
}

/// A web address in received text (the first one), or null.
String? linkIn(String text) => RegExp(r'https?://[^\s<>"]+').firstMatch(text)?.group(0);

/// A one-time code ("Your code is 482913"): 4–8 digits on their own.
String? codeIn(String text) {
  if (text.length > 200) return null;
  return RegExp(r'(?<![\d])(\d{4,8})(?![\d])').firstMatch(text)?.group(1);
}
