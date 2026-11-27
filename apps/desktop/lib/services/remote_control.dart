// apps/desktop/lib/services/remote_control.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../ui/library_tools.dart' show aiPackBase, makeAiPack;
import '../ui/screen/screen_record.dart' show ScreenRecorder;
import '../ui/send_paths.dart' show sendFilesOf, sendTargetFor;
import '../ui/theme.dart' show lrFontFallback;
import '../ui/tools/convert_run.dart';
import 'bg_tasks.dart';
import 'converter.dart';
import 'copy_in.dart';
import 'file_tools.dart';
import 'format_convert.dart';
import 'office_engines.dart';
import 'pdf_open.dart';
import 'tool_outputs.dart';
import 'file_actions.dart';
import 'pc_files.dart';
import 'remote_page.dart';
import 'remote_screen.dart';
import 'win_screen.dart';
import 'settings.dart';

/// How long the PC allows a phone.
enum RemoteGrant { once, hour, always, no }

/// A phone controlling this PC (for now: finding, looking at and taking
/// "Other files on this PC"). The PC allows each phone once — this time,
/// for an hour, or always (until 30 days unused) — and then the phone just
/// does things, nothing asked again. Every request is written to the log;
/// while a phone is at it the PC shows who, with a button to stop it.
class RemoteControl extends ChangeNotifier {
  RemoteControl(this.s);

  final AppServices s;

  /// This PC's screen and its mouse / keyboard, for a phone.
  late final RemoteScreen screen = RemoteScreen(() => s.ffmpeg.ffmpeg);
  final Map<String, int> _sentFrame = {};

  /// Small picture of a file anywhere on this PC (set by AppServices).
  Future<File?> Function(String path)? thumb;

  /// Asks on this PC (set by the UI): may [name] control it, and how long.
  Future<RemoteGrant> Function(String name)? ask;

  /// Allowed this time / for an hour (not kept after Keepnear closes).
  final Map<String, DateTime> _until = {};
  final Map<String, DateTime> _refused = {};

  /// Stopped on this PC: shut out for 10 minutes, even when always allowed.
  final Map<String, DateTime> _stopped = {};
  final Map<String, Future<RemoteGrant>> _asking = {};

  /// The phone at it now (a request in the last 2 minutes), and its name.
  String? activeId, activeName;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _idle;

  static const Duration unused = Duration(days: 30);

  AppSettings get _settings => s.settings;

  bool allowed(String id) {
    final t = _until[id];
    if (t != null && DateTime.now().isBefore(t)) return true;
    final used = _settings.remoteAlways[id];
    if (used == null) return false;
    if (DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(used)) > unused) {
      // 30 days without it: allowed no more.
      unawaited(_settings.update((x) => x.remoteAlways.remove(id)));
      DiagLog.log('remote', '$id: not used for 30 days, no longer allowed');
      return false;
    }
    return true;
  }

  /// Stops [id] now (its "always" too when [forGood]).
  void stop(String id, {bool forGood = false}) {
    _until.remove(id);
    if (forGood) unawaited(_settings.update((x) => x.remoteAlways.remove(id)));
    _stopped[id] = DateTime.now();
    screen.stop();
    if (activeId == id) {
      activeId = null;
      activeName = null;
    }
    DiagLog.log('remote', '$id: stopped${forGood ? ' (no longer allowed)' : ''}');
    notifyListeners();
  }

  void _seen(TrustedDevice d) {
    final now = DateTime.now();
    if (_settings.remoteAlways.containsKey(d.id) && now.difference(_lastAt) > const Duration(minutes: 10)) {
      unawaited(_settings.update((x) => x.remoteAlways[d.id] = now.millisecondsSinceEpoch));
    }
    _lastAt = now;
    if (activeId != d.id) {
      activeId = d.id;
      activeName = d.name;
      notifyListeners();
    }
    _idle?.cancel();
    _idle = Timer(const Duration(minutes: 2), () {
      activeId = null;
      activeName = null;
      notifyListeners();
    });
  }

  Future<RemoteGrant> _askOnce(TrustedDevice d) {
    final r = _refused[d.id];
    if (r != null && DateTime.now().difference(r) < const Duration(minutes: 1)) return Future.value(RemoteGrant.no);
    return _asking[d.id] ??= () async {
      final a = ask;
      final g = a == null ? RemoteGrant.no : await a(d.name);
      final now = DateTime.now();
      switch (g) {
        case RemoteGrant.once:
          _until[d.id] = now.add(const Duration(minutes: 30));
        case RemoteGrant.hour:
          _until[d.id] = now.add(const Duration(hours: 1));
        case RemoteGrant.always:
          await _settings.update((x) => x.remoteAlways[d.id] = now.millisecondsSinceEpoch);
        case RemoteGrant.no:
          _refused[d.id] = now;
      }
      DiagLog.log('remote', '${d.name}: ${g.name}');
      return g;
    }().whenComplete(() => _asking.remove(d.id));
  }

  /// Answers a phone's request under /api/v1/remote/.
  Future<void> handle(HttpRequest req, TrustedDevice d, String path) async {
    final res = req.response;
    final what = path.substring(LrProtocol.pathRemote.length + 1);
    final stopped = _stopped[d.id];
    if (stopped != null && DateTime.now().difference(stopped) < const Duration(minutes: 10)) {
      await req.drain<void>();
      return _json(res, 403, {'error': 'stopped'});
    }
    if (!allowed(d.id)) {
      await req.drain<void>();
      // The first knock asks on the PC; the phone waits and knocks again.
      if (what == 'hello') unawaited(_askOnce(d));
      final refused = _refused[d.id] != null && DateTime.now().difference(_refused[d.id]!) < const Duration(minutes: 1);
      return _json(res, 403, {'error': refused ? 'refused' : 'asking'});
    }
    _seen(d);
    final q = req.uri.queryParameters;
    switch (what) {
      case 'hello':
        await req.drain<void>();
        return _json(res, 200, {'ok': true, 'pc': _settings.deviceName});
      case 'ui':
        await req.drain<void>();
        res.headers.contentType = ContentType.html;
        res.write(remotePage());
        return res.close();
      case 'files':
        await req.drain<void>();
        return _json(res, 200, await _files(q));
      case 'screens':
        await req.drain<void>();
        return _json(res, 200, {
          'screens': [
            for (final x in WinScreen.screens()) {'w': x.rect.width.round(), 'h': x.rect.height.round(), 'primary': x.primary},
          ],
        });
      case 'frame':
        await req.drain<void>();
        final f = await screen.frame(
          index: int.tryParse(q['s'] ?? '') ?? 0,
          sharp: q['hd'] == '1',
          after: _sentFrame[d.id] ?? 0,
        );
        if (f == null) return _json(res, 503, {'error': 'no_picture'});
        _sentFrame[d.id] = f.$1;
        res.headers.contentType = ContentType('image', 'jpeg');
        res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        res.add(f.$2);
        return res.close();
      case 'input':
        await req.drain<void>();
        screen.input(q);
        return _json(res, 200, {'ok': true});
      case 'tools':
        await req.drain<void>();
        return _json(res, 200, await _tools(q, d));
      case 'tasks':
        await req.drain<void>();
        return _json(res, 200, _tasks());
      case 'act':
        await req.drain<void>();
        return _json(res, 200, await _act(d, q));
      case 'shot':
        await req.drain<void>();
        final shot = await _shot();
        if (shot == null) return _json(res, 500, {'error': 'no_shot'});
        DiagLog.log('remote', '${d.name}: screenshot');
        res.headers.contentType = ContentType('image', 'jpeg');
        await res.addStream(shot.openRead());
        await res.close();
        try {
          await shot.delete();
        } catch (_) {}
        return;
      case 'thumb':
      case 'file':
        await req.drain<void>();
        final p = q['p'] ?? '';
        if (!mayTake(p)) {
          DiagLog.log('remote', '${d.name}: refused (not a listed file)');
          return _json(res, 404, {'error': 'not_found'});
        }
        if (what == 'file') {
          DiagLog.log('remote', '${d.name}: takes ${p.split(Platform.pathSeparator).last}');
          return s.server.serveFile(req, File(p));
        }
        final t = await thumb?.call(p);
        if (t == null) return _json(res, 404, {'error': 'no_picture'});
        res.headers.contentType = ContentType('image', 'jpeg');
        res.headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600');
        await res.addStream(t.openRead());
        return res.close();
    }
    await req.drain<void>();
    return _json(res, 404, {'error': 'not_found'});
  }

  // ------------------------------------------------------------ tools

  /// Files made here for phones (they may take them), newest first.
  final List<String> _made = [];

  /// Converter jobs started from a phone.
  final Set<ConvertJob> _jobs = {};

  List<String> _paths(Map<String, String> q) {
    try {
      final l = jsonDecode(q['ps'] ?? '[]');
      return [for (final p in (l is List ? l : const [])) if (p is String && s.pcFiles.allowed(p)) p];
    } catch (_) {
      return const [];
    }
  }

  void _madeAdd(Iterable<String> paths) {
    for (final p in paths) {
      _made.remove(p);
      _made.insert(0, p);
    }
    if (_made.length > 200) _made.removeRange(200, _made.length);
  }

  /// May a phone take [path]: listed, or made here for a phone.
  bool mayTake(String path) => s.pcFiles.allowed(path) || (_made.contains(path) && File(path).existsSync());

  /// What the chosen files can become (from the first), the printers and
  /// the other devices (to send to).
  Future<Map<String, Object?>> _tools(Map<String, String> q, TrustedDevice d) async {
    final ps = _paths(q);
    final choices = ps.isEmpty ? const <ConvChoice>[] : FormatTable.choicesFor(ps.first, FormatTable.find(ps.first, ConvCat.image)?.$1 ?? ConvCat.image);
    final printers = <Map<String, Object?>>[];
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Console]::OutputEncoding=[Text.Encoding]::UTF8; @(Get-CimInstance Win32_Printer | Select-Object Name, Default) | ConvertTo-Json -Compress',
      ], stdoutEncoding: utf8);
      final j = jsonDecode('${r.stdout}'.trim());
      for (final p in (j is List ? j : [j])) {
        if (p is Map && p['Name'] != null) printers.add({'name': '${p['Name']}', 'default': p['Default'] == true});
      }
    } catch (_) {}
    return {
      'convert': [for (final c in choices) {'to': c.to.id, 'label': c.to.label, 'use': tr(c.useKey), 'best': c.recommended}],
      'printers': printers,
      'devices': [
        for (final id in {...s.settings.peers.keys, ...s.settings.trusted.keys})
          if (id != d.id) {'id': id, 'name': s.deviceName(id), 'online': s.isOnline(id) || s.phoneTarget(id) != null, 'pc': s.settings.peers.containsKey(id)},
      ],
    };
  }

  /// The background work started here (from a phone or not) and the
  /// files made for phones.
  Map<String, Object?> _tasks() {
    final conv = s.converter;
    _jobs.removeWhere((j) => !conv.jobs.contains(j));
    return {
      'tasks': [
        for (final t in BgTasks.instance.tasks.reversed.take(10))
          {'title': t.title, 'progress': t.progress, 'state': t.state.name},
        for (final j in _jobs)
          {'title': '${j.path.split(Platform.pathSeparator).last} → ${j.label}', 'progress': j.progress, 'state': j.state.name},
      ],
      'made': [
        for (final p in _made)
          if (File(p).existsSync()) {'path': p, 'name': p.split(Platform.pathSeparator).last, 'size': File(p).lengthSync(), 'kind': PcFiles.kindOf(p)?.name},
      ],
    };
  }

  /// A tool run on the chosen files (in the background here).
  Future<Map<String, Object?>> _tool(TrustedDevice d, String what, Map<String, String> q) async {
    final ps = _paths(q);
    if (ps.isEmpty) return {'ok': false, 'error': 'nothing'};
    DiagLog.log('remote', '${d.name}: $what (${ps.length} files)');
    switch (what) {
      case 'convert':
        final to = q['to'] ?? '';
        final small = q['small'] == '1';
        final rest = <ConvOp, List<String>>{};
        for (final p in ps) {
          final cat = FormatTable.find(p, ConvCat.image)?.$1 ?? ConvCat.image;
          final c = FormatTable.choicesFor(p, cat).where((x) => x.to.id == to).firstOrNull;
          if (c == null) continue;
          final op = c.op;
          if (op is MediaOp) {
            s.converter.enqueueFile(p, op.format, preset: small ? ConvertPreset.share : ConvertPreset.compatible);
            _watchJob(p);
          } else {
            (rest[op] ??= []).add(p);
          }
        }
        if (rest.isNotEmpty) {
          unawaited(BgTasks.instance.run<void>(
            title: tr('rpc.converting', {'count': rest.values.fold<int>(0, (n, l) => n + l.length)}),
            job: (t) async {
              final outs = <String>[];
              final failed = <String>[];
              for (final e in rest.entries) {
                await convertFiles(s, e.key, e.value, outs, failed);
              }
              _madeAdd(outs);
              DiagLog.log('remote', '${d.name}: converted ${outs.length}, failed ${failed.length}');
            },
          ));
        }
        return {'ok': true};
      case 'compress':
        var n = 0;
        for (final p in ps) {
          final k = PcFiles.kindOf(p);
          if (k != PcKind.photo && k != PcKind.video) continue;
          s.converter.enqueueFile(p, null, preset: ConvertPreset.share);
          _watchJob(p);
          n++;
        }
        return {'ok': n > 0};
      case 'merge':
        final pdfs = [for (final p in ps) if (p.toLowerCase().endsWith('.pdf')) p];
        if (pdfs.length < 2) return {'ok': false, 'error': 'two_pdfs'};
        unawaited(BgTasks.instance.run<void>(
          title: tr('rpc.merging', {'count': pdfs.length}),
          job: (t) async {
            final pages = <PdfPlanPage>[];
            for (final p in pdfs) {
              final doc = await openPdfLoose(p);
              for (var i = 0; i < doc.pages.length; i++) {
                pages.add(PdfFromDoc(p, i));
              }
              await doc.dispose();
            }
            final out = toolOutPath(s, pdfs.first, '-${pdfs.length}', 'pdf');
            final err = await PdfBuilder.build(out, pages);
            if (err == null) _madeAdd([out]);
            DiagLog.log('remote', '${d.name}: merged ${pdfs.length} PDF ${err ?? 'ok'}');
          },
        ));
        return {'ok': true};
      case 'print':
        final printer = q['printer'] ?? '';
        if (printer.isEmpty) return {'ok': false, 'error': 'no_printer'};
        unawaited(BgTasks.instance.run<void>(
          title: tr('rpc.printing', {'count': ps.length}),
          job: (t) async {
            final tmp = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}lr_remote_print');
            await tmp.create(recursive: true);
            final photos = [for (final p in ps) if (PcFiles.kindOf(p) == PcKind.photo) p];
            final list = <String>[for (final p in ps) if (p.toLowerCase().endsWith('.pdf')) p];
            if (photos.isNotEmpty) {
              final out = '${tmp.path}${Platform.pathSeparator}photos-${DateTime.now().millisecondsSinceEpoch}.pdf';
              if (await photosToPdf(s, photos, out) == null) list.add(out);
            }
            for (final p in ps) {
              final k = PcFiles.kindOf(p);
              if (k == PcKind.word || k == PcKind.excel || k == PcKind.ppt || k == PcKind.text) {
                final name = p.split(Platform.pathSeparator).last;
                final out = '${tmp.path}${Platform.pathSeparator}$name.pdf';
                final err = k == PcKind.text
                    ? await FormatConverter.textPdf(p, out, lrFontFallback(translator.language))
                    : await OfficeEngines.run('pdf', p, out);
                if (err == null && File(out).existsSync()) list.add(out);
              }
            }
            for (var i = 0; i < list.length; i++) {
              t.setProgress(i / list.length);
              final err = await PdfBuilder.print(list[i], printer, [for (var k = 0; k < 2000; k++) k]);
              DiagLog.log('remote', '${d.name}: printed ${list[i].split(Platform.pathSeparator).last} ${err ?? 'ok'}');
            }
          },
        ));
        return {'ok': true};
      case 'send':
        final ids = () {
          try {
            final l = jsonDecode(q['to'] ?? '[]');
            return [for (final x in (l is List ? l : const [])) if (x is String) x];
          } catch (_) {
            return const <String>[];
          }
        }();
        final files = await sendFilesOf(ps);
        if (files.isEmpty || ids.isEmpty) return {'ok': false};
        final title = ps.length == 1 ? ps.first.split(Platform.pathSeparator).last : tr('send.n_files', {'count': files.length});
        var n = 0;
        for (final id in ids) {
          final p = sendTargetFor(s, id);
          if (p == null) continue;
          if (s.settings.peers.containsKey(id)) {
            s.sender.add(p, files, title);
          } else {
            // A phone: as they are (no question here: the phone asked).
            s.sender.add(p, files, title, toPhone: true, platform: s.settings.trusted[id]?.platform ?? '');
          }
          n++;
          DiagLog.log('remote', '${d.name}: sends ${files.length} files to ${s.deviceName(id)}');
        }
        return {'ok': n > 0};
      case 'split':
        final pdfs = [for (final p in ps) if (p.toLowerCase().endsWith('.pdf')) p];
        if (pdfs.isEmpty) return {'ok': false};
        unawaited(BgTasks.instance.run<void>(
          title: tr('rpc.splitting', {'count': pdfs.length}),
          job: (t) async {
            for (final p in pdfs) {
              final doc = await openPdfLoose(p);
              final n = doc.pages.length;
              await doc.dispose();
              final outs = <String>[];
              for (var i = 0; i < n; i++) {
                t.setProgress(i / n);
                final out = toolOutPath(s, p, '-p${i + 1}', 'pdf');
                if (await PdfBuilder.build(out, [PdfFromDoc(p, i)]) == null) outs.add(out);
              }
              _madeAdd(outs.reversed);
              DiagLog.log('remote', '${d.name}: split ${p.split(Platform.pathSeparator).last} into ${outs.length}');
            }
          },
        ));
        return {'ok': true};
      case 'aipack':
        unawaited(BgTasks.instance.run<void>(
          title: tr('rpc.packing', {'count': ps.length}),
          job: (t) async {
            final now = DateTime.now();
            String two(int v) => v.toString().padLeft(2, '0');
            final name = 'Keepnear-AI-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}-${ps.length}files';
            final made = await makeAiPack(s, const [], ps, aiPackBase(s), name);
            if (made != null) _madeAdd([made.$1]);
          },
        ));
        return {'ok': true};
    }
    return {'ok': false, 'error': 'unknown'};
  }

  /// A converter job for [path] (just queued): its result is the phone's.
  void _watchJob(String path) {
    final j = s.converter.jobs.where((j) => j.path == path).firstOrNull;
    if (j == null) return;
    _jobs.add(j);
    void check() {
      if (j.state == JobState.done && j.outputPath != null) {
        _madeAdd([j.outputPath!]);
        s.converter.removeListener(check);
      } else if (j.state == JobState.failed) {
        s.converter.removeListener(check);
      }
    }

    s.converter.addListener(check);
  }

  /// A whole-screen picture (all screens), JPEG.
  Future<File?> _shot() async {
    final exe = s.ffmpeg.ffmpeg;
    if (exe == null) return null;
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}lr_remote_shot_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await Process.run(exe, ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'gdigrab', '-i', 'desktop', '-frames:v', '1', '-q:v', '3', f.path],
        environment: const {'__COMPAT_LAYER': 'HighDpiAware'});
    return f.existsSync() ? f : null;
  }

  /// One thing done on this PC for a phone (allowed already: not asked again).
  Future<Map<String, Object?>> _act(TrustedDevice d, Map<String, String> q) async {
    final what = q['do'] ?? '';
    final p = q['p'] ?? '';
    final sep = Platform.pathSeparator;
    String nameOf(String x) => x.split(sep).last;
    Map<String, Object?> no(String why) {
      DiagLog.log('remote', '${d.name}: $what refused ($why)');
      return {'ok': false, 'error': why};
    }

    if (const {'convert', 'compress', 'merge', 'split', 'print', 'send', 'aipack'}.contains(what)) return _tool(d, what, q);
    switch (what) {
      case 'rec_start':
        DiagLog.log('remote', '${d.name}: started recording the screen');
        await ScreenRecorder.instance.startQuick();
        return {'ok': ScreenRecorder.instance.recording || ScreenRecorder.instance.countdown > 0};
      case 'rec_stop':
        DiagLog.log('remote', '${d.name}: stopped recording the screen');
        unawaited(ScreenRecorder.instance.stop());
        return {'ok': true};
      case 'rec_state':
        return {'ok': true, 'recording': ScreenRecorder.instance.recording};
      // --- files (only those listed) ---
      case 'delete':
        if (!s.pcFiles.allowed(p)) return no('not_listed');
        final gone = await moveToRecycleBin([p]);
        DiagLog.log('remote', '${d.name}: ${nameOf(p)} → Recycle Bin (${gone.isNotEmpty ? 'done' : 'failed'})');
        if (gone.isNotEmpty) s.pcFiles.files.removeWhere((f) => f.path == p);
        return {'ok': gone.isNotEmpty};
      case 'rename':
        if (!s.pcFiles.allowed(p)) return no('not_listed');
        var to = sanitizeFileName((q['name'] ?? '').trim());
        if (to.isEmpty) return no('bad_name');
        final dot = p.lastIndexOf('.');
        if (!to.contains('.') && dot > p.lastIndexOf(sep)) to = '$to${p.substring(dot)}';
        final dest = '${File(p).parent.path}$sep$to';
        if (File(dest).existsSync()) return no('taken');
        await File(p).rename(dest);
        DiagLog.log('remote', '${d.name}: renamed ${nameOf(p)} → $to');
        await s.pcFiles.list(fresh: true);
        return {'ok': true, 'path': dest};
      case 'move':
        if (!s.pcFiles.allowed(p)) return no('not_listed');
        final into = q['to'] ?? '';
        final places = [...PcFiles.usualFolders(), ..._settings.pcFilesExtra];
        if (!places.any((x) => x.toLowerCase() == into.toLowerCase()) || !Directory(into).existsSync()) return no('bad_place');
        var dest = '$into$sep${nameOf(p)}';
        if (File(dest).existsSync()) {
          final n = nameOf(p);
          final dot = n.lastIndexOf('.');
          var k = 2;
          do {
            dest = '$into$sep${dot > 0 ? '${n.substring(0, dot)} ($k)${n.substring(dot)}' : '$n ($k)'}';
            k++;
          } while (File(dest).existsSync());
        }
        try {
          await File(p).rename(dest);
        } on FileSystemException {
          // Another drive: copied, then the original to the Recycle Bin.
          await File(p).copy(dest);
          await moveToRecycleBin([p]);
        }
        DiagLog.log('remote', '${d.name}: moved ${nameOf(p)} → $into');
        await s.pcFiles.list(fresh: true);
        return {'ok': true, 'path': dest};
      case 'copyin':
        if (!s.pcFiles.allowed(p)) return no('not_listed');
        final r = await CopyIn.copy(s, [p]);
        DiagLog.log('remote', '${d.name}: copied ${nameOf(p)} into the library');
        return {'ok': r.failed.isEmpty, 'had': r.had.isNotEmpty};
      // --- the PC itself ---
      case 'clip_get':
        final c = await Clipboard.getData(Clipboard.kTextPlain);
        DiagLog.log('remote', '${d.name}: read the clipboard');
        return {'ok': true, 'text': c?.text ?? ''};
      case 'clip_set':
        await Clipboard.setData(ClipboardData(text: q['text'] ?? ''));
        DiagLog.log('remote', '${d.name}: set the clipboard');
        return {'ok': true};
      case 'vol_up':
      case 'vol_down':
      case 'mute':
        final key = switch (what) { 'vol_up' => 175, 'vol_down' => 174, _ => 173 };
        final times = what == 'mute' ? 1 : 5;
        await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$w=New-Object -ComObject WScript.Shell; 1..$times | % { \$w.SendKeys([char]$key) }",
        ]);
        return {'ok': true};
      case 'lock':
        DiagLog.log('remote', '${d.name}: locked the PC');
        await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
        return {'ok': true};
      case 'sleep':
        DiagLog.log('remote', '${d.name}: put the PC to sleep');
        // Answered first: the PC is asleep a moment later.
        Timer(const Duration(seconds: 2), () {
          unawaited(Process.run('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r"Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)",
          ]));
        });
        return {'ok': true};
      case 'shutdown':
      case 'restart':
        // In 60 s, so it can still be called off ("cancel").
        DiagLog.log('remote', '${d.name}: ${what == 'shutdown' ? 'shut down' : 'restart'} in 60 s');
        await Process.run('shutdown', [what == 'shutdown' ? '/s' : '/r', '/t', '60', '/c', 'Keepnear: ${d.name}']);
        return {'ok': true};
      case 'cancel':
        DiagLog.log('remote', '${d.name}: shut down / restart called off');
        await Process.run('shutdown', ['/a']);
        return {'ok': true};
    }
    return no('unknown');
  }

  Future<Map<String, Object?>> _files(Map<String, String> q) async {
    final pc = s.pcFiles;
    await pc.list(fresh: q['fresh'] == '1');
    final words = (q['q'] ?? '').trim();
    List<PcFile> base = pc.files;
    if (q['inside'] == '1' && words.isNotEmpty) base = await pc.searchInside(words) ?? pc.files;
    final kinds = (q['kinds'] ?? '').split(',').where((e) => e.isNotEmpty).toSet();
    final now = DateTime.now();
    bool when(PcFile f) {
      final t = f.when;
      return switch (q['when']) {
        'week' => now.difference(t).inDays < 7,
        'month' => t.year == now.year && t.month == now.month,
        'year' => t.year == now.year,
        'last_year' => t.year == now.year - 1,
        _ => true,
      };
    }

    const mb = 1024 * 1024;
    bool size(PcFile f) => switch (q['size']) {
          'small' => f.size < mb,
          'medium' => f.size >= mb && f.size < 100 * mb,
          'big' => f.size >= 100 * mb && f.size < 1024 * mb,
          'huge' => f.size >= 1024 * mb,
          _ => true,
        };
    final place = (q['place'] ?? '').toLowerCase();
    final w = words.toLowerCase();
    final list = [
      for (final f in base)
        if ((kinds.isEmpty || kinds.contains(f.kind?.name)) &&
            when(f) &&
            size(f) &&
            (place.isEmpty || f.path.toLowerCase().startsWith('$place\\')) &&
            (q['inside'] == '1' || w.isEmpty || f.name.toLowerCase().contains(w)))
          f,
    ];
    switch (q['sort']) {
      case 'oldest':
        list.sort((a, b) => a.when.compareTo(b.when));
      case 'name':
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case 'biggest':
        list.sort((a, b) => b.size.compareTo(a.size));
      default:
        list.sort((a, b) => b.when.compareTo(a.when));
    }
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = (int.tryParse(q['limit'] ?? '') ?? 100).clamp(1, 500);
    return {
      'total': list.length,
      'source': pc.source.name,
      'files': [for (final f in list.skip(offset).take(limit)) f.toJson()],
      'places': [
        for (final p in [...PcFiles.usualFolders(), ..._settings.pcFilesExtra]) {'path': p, 'name': p.split(Platform.pathSeparator).last},
      ],
    };
  }

  static Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
