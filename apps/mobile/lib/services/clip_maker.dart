// apps/mobile/lib/services/clip_maker.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'discovery.dart';
import 'mobile_settings.dart';

/// Set once at start (main.dart): what sending a clip needs.
class ClipEnv {
  static MobileSettings? settings;
  static DesktopDiscovery? discovery;
}

/// Seconds kept before / after the drawing (0–30, remembered).
class ClipAround {
  static const int max = 30;
  static const int fallback = 5;

  static Future<(int, int)> load() async {
    final p = await SharedPreferences.getInstance();
    return (
      (p.getInt('clipBefore') ?? fallback).clamp(0, max),
      (p.getInt('clipAfter') ?? fallback).clamp(0, max),
    );
  }

  static Future<void> save(int before, int after) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('clipBefore', before);
    await p.setInt('clipAfter', after);
  }
}

/// The time span the drawing covers in a video: from the first mark to when
/// the last one goes (ms).
(int, int) drawingSpan(List<Note> notes) {
  var from = 1 << 40, to = 0;
  for (final n in notes) {
    if (n.inks.isEmpty) continue;
    from = math.min(from, n.startMs);
    to = math.max(to, n.endMs);
  }
  return from > to ? (0, 0) : (from, to);
}

/// A part of a video with the drawings laid into the picture, made by the
/// phone's own video tools (iPhone: AVFoundation; Android: Media3), so
/// whoever gets it sees the drawings in any player.
class ClipMaker {
  static const _ch = MethodChannel('localroll/clip');

  /// [input]: the video file; [width] × [height]: its picture as shown
  /// (turned upright); [fromMs]–[toMs]: the part kept; [notes]: drawn on it.
  static Future<File> make({
    required String input,
    required int width,
    required int height,
    required int fromMs,
    required int toMs,
    required List<Note> notes,
    int maxSide = 0,
  }) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/clips');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final overlays = <Map<String, Object>>[];
    // Where what is shown changes: each stretch between them is one still
    // picture laid over the video (marks on the phone are drawn whole).
    final cuts = <int>{fromMs, toMs};
    for (final n in notes) {
      cuts
        ..add(n.startMs)
        ..add(n.endMs);
      for (final i in n.inks) {
        cuts.add(i.atMs ?? n.startMs);
      }
    }
    final times = cuts.where((t) => t >= fromMs && t <= toMs).toList()..sort();
    final size = ui.Size(width.toDouble(), height.toDouble());
    for (var k = 0; k + 1 < times.length; k++) {
      final a = times[k], b = times[k + 1];
      if (b - a < 20) continue;
      final mid = (a + b) ~/ 2;
      final shown = [
        for (final n in notes)
          if (n.shownAt(mid) && n.inks.any((i) => n.inkShownAt(i, mid))) n,
      ];
      if (shown.isEmpty) continue;
      final rec = ui.PictureRecorder();
      paintNotes(ui.Canvas(rec), size, shown, video: true, now: mid);
      final img = await rec.endRecording().toImage(width, height);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (png == null) continue;
      final f = File('${dir.path}/o$k.png');
      await f.writeAsBytes(png.buffer.asUint8List());
      overlays.add({'path': f.path, 'startMs': a - fromMs, 'endMs': b - fromMs});
    }
    final out = File('${dir.path}/clip_${DateTime.now().millisecondsSinceEpoch}.mp4');
    DiagLog.log('clip', 'making ${toMs - fromMs} ms, ${width}x$height, ${overlays.length} pictures');
    await _ch.invokeMethod<bool>('make', {
      'input': input,
      'output': out.path,
      'startMs': fromMs,
      'endMs': toMs,
      'width': width,
      'height': height,
      'overlays': overlays,
      'maxSide': maxSide,
    });
    if (!await out.exists()) throw StateError('no clip');
    return out;
  }

  /// Keeps [clip] in the phone's photo library.
  static Future<void> saveToAlbum(File clip, String title) async {
    await PhotoManager.editor.saveVideo(
      clip,
      title: title,
      relativePath: Platform.isAndroid ? 'Movies/Keepnear' : null,
    );
  }
}
