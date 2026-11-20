// apps/desktop/lib/services/clipboard_files.dart
// 复制: files onto the Windows clipboard (pasted into a folder as copies);
// one photo also as a picture (pasted into a chat, Word, Paint, an email).
// A HEIC photo goes as an ordinary picture (most programs can't read HEIC);
// the file itself is never changed.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog, MediaKind;

import '../app_services.dart';
import 'file_tools.dart';

/// Copies [paths]; false if the clipboard could not be filled.
Future<bool> copyToClipboard(AppServices s, List<String> paths) async {
  if (!Platform.isWindows || paths.isEmpty) return false;
  Uint8List? bgra;
  var w = 0, h = 0;
  final one = paths.length == 1 ? paths.first : null;
  if (one != null && MediaKind.fromName(one.split(Platform.pathSeparator).last) == MediaKind.image) {
    try {
      // The photo upright, as a plain JPEG (HEIC, RAW… too), at most
      // 6000 px on its long side.
      final j = await uprightJpeg(s, one, max: 6000);
      if (j != null) {
        final (jpg, jw, jh) = j;
        final big = jw > 6000 || jh > 6000;
        final codec = await ui.instantiateImageCodec(
          await File(jpg).readAsBytes(),
          targetWidth: big && jw >= jh ? 6000 : null,
          targetHeight: big && jh > jw ? 6000 : null,
        );
        final frame = await codec.getNextFrame();
        final im = frame.image;
        final data = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        w = im.width;
        h = im.height;
        im.dispose();
        if (data != null) {
          final b = data.buffer.asUint8List();
          for (var i = 0; i + 3 < b.length; i += 4) {
            final r = b[i];
            b[i] = b[i + 2];
            b[i + 2] = r;
          }
          bgra = b;
        }
      }
    } catch (e) {
      DiagLog.log('ui', 'copy: picture not made: $e');
    }
  }
  try {
    final ok = await const MethodChannel('keepnear/shell').invokeMethod<bool>('copy', {
          'files': paths,
          'bgra': bgra,
          'w': w,
          'h': h,
        }) ??
        false;
    DiagLog.log('ui', 'copied ${paths.length} file(s)${bgra != null ? ' + picture ${w}x$h' : ''}: $ok');
    return ok;
  } catch (e) {
    DiagLog.log('ui', 'copy failed: $e');
    return false;
  }
}
