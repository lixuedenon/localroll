// apps/desktop/lib/ui/player/snapshot.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/library_index.dart';
import 'ink_paint.dart';
import 'player_entry.dart';

/// HDR video frames brought to ordinary colours (as the converter does).
const String _toneMap = 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
    'tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv';

/// Screenshots: the original's own pixels (a 4K video gives a 4K picture),
/// with the marks drawn on at full size, saved as JPEG in the library's
/// screenshot folder (it shows up in the library).
class Snapshots {
  Snapshots._();

  /// The folder: in the library, else in Windows' Pictures.
  static String folder(AppServices s, {bool clips = false, bool narration = false, bool screen = false}) {
    final m = s.player;
    final String name;
    if (screen) {
      name = m.screensFolder ?? tr('screen.folder');
      if (m.screensFolder == null) m.setScreen(folder: name);
    } else if (narration) {
      name = m.narrationsFolder ?? tr('rec.folder');
      if (m.narrationsFolder == null) m.setNarrationsFolder(name);
    } else {
      name = (clips ? m.clipsFolder : m.shotsFolder) ?? tr(clips ? 'ink.clips_folder' : 'ink.shots_folder');
      if (clips && m.clipsFolder == null) m.setClipsFolder(name);
      if (!clips && m.shotsFolder == null) m.setShotsFolder(name);
    }
    final lib = s.library;
    final sep = Platform.pathSeparator;
    if (lib.rootPath.isNotEmpty && !lib.offline && Directory(lib.rootPath).existsSync()) return '${lib.rootPath}$sep${sanitizeFileName(name)}';
    final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return '$home${sep}Pictures$sep${sanitizeFileName(name)}';
  }

  static String _secs(int ms) => (ms / 1000).toStringAsFixed(3);

  static String stamp(int ms) {
    final d = Duration(milliseconds: ms);
    String two(int n) => n.toString().padLeft(2, '0');
    final t = '${two(d.inMinutes % 60)}-${two(d.inSeconds % 60)}';
    return d.inHours > 0 ? '${d.inHours}-$t' : t;
  }

  /// Takes one: [ms] into a video (photos: ignored), with [inks] drawn on.
  /// Null when it could not be made.
  static Future<File?> take(AppServices s, PlayerEntry e, {required int ms, required List<InkMark> inks}) async {
    final ff = s.ffmpeg;
    final dir = folder(s);
    final sep = Platform.pathSeparator;
    final tmp = <File>[];
    File tempFile(String ext) {
      final f = File('${Directory.systemTemp.path}${sep}lr_shot_${DateTime.now().microsecondsSinceEpoch}_${tmp.length}.$ext');
      tmp.add(f);
      return f;
    }

    try {
      await Directory(dir).create(recursive: true);
      final base = e.name.contains('.') ? e.name.substring(0, e.name.lastIndexOf('.')) : e.name;
      final out = LibraryIndex.uniquePath(dir, sanitizeFileName('${base}_${e.video ? stamp(ms) : 'note'}.jpg'));

      // 1. The picture itself, upright, full size.
      String src;
      if (e.video) {
        final hdr = (await ff.probe(e.path)).isHdr;
        if (inks.isEmpty) {
          final ok = await ff.run([
            '-ss', _secs(ms), '-i', e.path, '-frames:v', '1',
            '-vf', [if (hdr) _toneMap, 'format=yuvj420p'].join(','),
            '-q:v', '2', out,
          ]);
          return ok ? await done(s, File(out)) : null;
        }
        final png = tempFile('png');
        final ok = await ff.run([
          '-ss', _secs(ms), '-i', e.path, '-frames:v', '1',
          '-vf', [if (hdr) _toneMap, 'format=rgb24'].join(','),
          png.path,
        ]);
        if (!ok) return null;
        src = png.path;
      } else if (nativelyDecodableImages.contains(e.extension)) {
        src = e.path;
      } else {
        final p = e.item != null ? await ff.preview(e.item!) : await ff.previewFile(e.path, size: e.size, modifiedMs: e.modifiedMs);
        if (p == null) return null;
        src = p.path;
      }

      // 2. The marks drawn on at full size (Flutter turns photos upright
      // the way they are shown).
      final codec = await ui.instantiateImageCodec(await File(src).readAsBytes());
      final image = (await codec.getNextFrame()).image;
      final size = Size(image.width.toDouble(), image.height.toDouble());
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.high);
      for (final i in inks) {
        InkGeometry.paint(canvas, size, i);
      }
      final drawn = await rec.endRecording().toImage(image.width, image.height);
      final bytes = await drawn.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      drawn.dispose();
      if (bytes == null) return null;
      final png = tempFile('png');
      await png.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

      // 3. JPEG (far smaller); without ffmpeg the PNG is kept.
      if (await ff.run(['-i', png.path, '-q:v', '2', out])) return await done(s, File(out));
      final keep = LibraryIndex.uniquePath(dir, out.split(sep).last.replaceAll(RegExp(r'\.jpg$'), '.png'));
      await png.copy(keep);
      return await done(s, File(keep));
    } catch (err) {
      DiagLog.log('player', 'screenshot failed: $err');
      return null;
    } finally {
      for (final f in tmp) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// In the library at once (not only after it notices the new file).
  static Future<File> done(AppServices s, File f, {bool video = false}) async {
    final lib = s.library;
    final root = '${lib.rootPath}${Platform.pathSeparator}';
    if (lib.rootPath.isNotEmpty && f.path.toLowerCase().startsWith(root.toLowerCase())) {
      final now = DateTime.now().millisecondsSinceEpoch;
      lib.add(MediaItem(
        relPath: f.path.substring(root.length).replaceAll(Platform.pathSeparator, '/'),
        name: f.path.split(Platform.pathSeparator).last,
        size: await f.length(),
        kind: video ? MediaKind.video : MediaKind.image,
        captureMs: now,
        receivedMs: now,
      ));
    }
    DiagLog.log('player', video ? 'clip saved' : 'screenshot saved');
    return f;
  }
}
