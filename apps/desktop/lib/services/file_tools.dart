// apps/desktop/lib/services/file_tools.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import 'library_index.dart';
import 'video_encoders.dart';

// The "tools" (Home's everyday tools, the Tools page): what they do on this
// PC. Originals are never changed; a new file is made beside them.

/// Where a tool's result goes: beside [src]; a file of the library goes to
/// the received-files folder's "Keepnear" folder (the library keeps only
/// what came from devices). [suffix] e.g. "-signed"; [ext] without the dot.
String toolOutPath(AppServices s, String src, String suffix, String ext) {
  final sep = Platform.pathSeparator;
  final lib = s.library.rootPath;
  var dir = File(src).parent.path;
  if (lib.isNotEmpty && src.toLowerCase().startsWith('${lib.toLowerCase()}$sep')) {
    dir = '${s.server.folderPath}${sep}Keepnear';
  }
  try {
    Directory(dir).createSync(recursive: true);
  } catch (_) {
    dir = '${Directory.systemTemp.path}${sep}Keepnear';
    Directory(dir).createSync(recursive: true);
  }
  final name = baseNameOf(src);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return LibraryIndex.uniquePath(dir, sanitizeFileName('$stem$suffix.$ext'));
}

// ------------------------------------------------------------- PDF builder

/// A page for [PdfBuilder]: one from a PDF, or one made from a photo.
sealed class PdfPlanPage {
  const PdfPlanPage();
}

class PdfFromDoc extends PdfPlanPage {
  const PdfFromDoc(this.path, this.page, {this.turns = 0, this.stamps = const []});

  final String path;

  /// 0-based.
  final int page;

  /// Quarter turns clockwise.
  final int turns;
  final List<PdfStamp> stamps;
}

/// A picture laid on a page: raw BGRA pixels; where, 0–1 of the page as
/// shown (from the top left).
class PdfStamp {
  const PdfStamp(this.bgra, this.width, this.height, this.rect);

  final List<int> bgra;
  final int width, height;
  final ui.Rect rect;
}

/// A page made from a JPEG photo: [pageW]×[pageH] points, the photo at
/// [rect] (points from the bottom left).
class PdfFromJpeg extends PdfPlanPage {
  const PdfFromJpeg(this.jpeg, this.pageW, this.pageH, this.rect);

  final String jpeg;
  final double pageW, pageH;
  final ui.Rect rect;
}

/// lr_pdf.exe (next to the app; pdfium underneath): writes PDFs from pages
/// of other PDFs (turned, signed) and photos. Text stays text.
class PdfBuilder {
  PdfBuilder._();

  static String get exe => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lr_pdf.exe';

  static bool get available => Platform.isWindows && File(exe).existsSync();

  /// Writes [pages] to [out]; null when done, else why not.
  static Future<String?> build(String out, List<PdfPlanPage> pages) async {
    if (!available) return 'lr_pdf.exe missing';
    final tmp = await Directory.systemTemp.createTemp('lr_pdf');
    try {
      final docs = <String>[];
      final plan = StringBuffer();
      final part = '$out.part';
      plan.writeln('OUT $part');
      var n = 0;
      for (final p in pages) {
        switch (p) {
          case PdfFromDoc():
            var di = docs.indexOf(p.path);
            if (di < 0) {
              docs.add(p.path);
              di = docs.length - 1;
              plan.writeln('DOC ${p.path}');
            }
            plan.writeln('PAGE $di|${p.page}|${p.turns % 4}');
            for (final st in p.stamps) {
              final f = File('${tmp.path}${Platform.pathSeparator}s${n++}.bgra');
              await f.writeAsBytes(st.bgra);
              final r = st.rect;
              plan.writeln('STAMP ${f.path}|${st.width}|${st.height}|${r.left}|${r.top}|${r.width}|${r.height}');
            }
          case PdfFromJpeg():
            final r = p.rect;
            plan.writeln('IMAGE ${p.jpeg}|${p.pageW}|${p.pageH}|${r.left}|${r.top}|${r.width}|${r.height}');
        }
      }
      final planFile = File('${tmp.path}${Platform.pathSeparator}plan.txt');
      await planFile.writeAsString(plan.toString(), encoding: utf8);
      final r = await Process.run(exe, [planFile.path], stdoutEncoding: utf8).timeout(const Duration(minutes: 10));
      final said = '${r.stdout}'.trim();
      if (!said.startsWith('ok')) {
        DiagLog.log('tools', 'pdf not made: $said');
        try {
          await File(part).delete();
        } catch (_) {}
        return said.isEmpty ? 'no answer' : said;
      }
      if (await File(out).exists()) await File(out).delete();
      await File(part).rename(out);
      return null;
    } catch (e) {
      return '$e';
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// An upright JPEG of a photo (HEIC and others too) no bigger than [max]
/// pixels, and its size.
Future<(String, int, int)?> uprightJpeg(AppServices s, String path, {int max = 2400}) async {
  final f = File(path);
  if (!f.existsSync()) return null;
  final pic = await s.ffmpeg.previewFile(path, size: max, modifiedMs: f.lastModifiedSync().millisecondsSinceEpoch);
  if (pic == null) return null;
  try {
    final codec = await ui.instantiateImageCodec(await pic.readAsBytes());
    final frame = await codec.getNextFrame();
    final w = frame.image.width, h = frame.image.height;
    frame.image.dispose();
    return (pic.path, w, h);
  } catch (_) {
    return null;
  }
}

/// Photos into one PDF: one photo per A4 page (turned to suit the photo),
/// in the order given. Null when done, else why not.
Future<String?> photosToPdf(AppServices s, List<String> photos, String out) async {
  final pages = <PdfPlanPage>[];
  for (final p in photos) {
    final j = await uprightJpeg(s, p);
    if (j == null) continue;
    final (jpg, w, h) = j;
    final landscape = w > h;
    final pw = landscape ? 842.0 : 595.0, ph = landscape ? 595.0 : 842.0;
    const m = 24.0;
    final k = math.min((pw - 2 * m) / w, (ph - 2 * m) / h);
    final iw = w * k, ih = h * k;
    pages.add(PdfFromJpeg(jpg, pw, ph, ui.Rect.fromLTWH((pw - iw) / 2, (ph - ih) / 2, iw, ih)));
  }
  if (pages.isEmpty) return 'no photos';
  return PdfBuilder.build(out, pages);
}

// ------------------------------------------------------------- Office → PDF

/// Word / Excel / PowerPoint files into PDF, by the Microsoft Office on this
/// PC (as "Save as PDF" there). No Office: [available] is false.
class OfficePdf {
  OfficePdf._();

  static const Set<String> word = {'doc', 'docx', 'rtf', 'odt', 'wps'};
  static const Set<String> excel = {'xls', 'xlsx', 'xlsm', 'csv', 'ods', 'et'};
  static const Set<String> powerpoint = {'ppt', 'pptx', 'pps', 'ppsx', 'odp', 'dps'};

  static bool handles(String path) {
    final e = extensionOf(path);
    return word.contains(e) || excel.contains(e) || powerpoint.contains(e);
  }

  static bool? _have;

  /// Office is installed (its programs answer to other programs).
  static Future<bool> available() async {
    if (_have != null) return _have!;
    if (!Platform.isWindows) return _have = false;
    try {
      final r = await Process.run('reg', ['query', r'HKCR\Word.Application\CLSID']);
      final r2 = await Process.run('reg', ['query', r'HKCR\PowerPoint.Application\CLSID']);
      final r3 = await Process.run('reg', ['query', r'HKCR\Excel.Application\CLSID']);
      return _have = r.exitCode == 0 || r2.exitCode == 0 || r3.exitCode == 0;
    } catch (_) {
      return _have = false;
    }
  }

  /// Null when done, else why not.
  static Future<String?> convert(String src, String out) async {
    final e = extensionOf(src);
    String q(String v) => v.replaceAll("'", "''");
    final script = word.contains(e)
        ? "\$a=New-Object -ComObject Word.Application;\$a.Visible=\$false;\$a.DisplayAlerts=0;"
            "try{\$d=\$a.Documents.Open('${q(src)}',\$false,\$true);\$d.ExportAsFixedFormat('${q(out)}',17);\$d.Close(\$false)}finally{\$a.Quit()}"
        : excel.contains(e)
            ? "\$a=New-Object -ComObject Excel.Application;\$a.Visible=\$false;\$a.DisplayAlerts=\$false;"
                "try{\$d=\$a.Workbooks.Open('${q(src)}',0,\$true);\$d.ExportAsFixedFormat(0,'${q(out)}');\$d.Close(\$false)}finally{\$a.Quit()}"
            : "\$a=New-Object -ComObject PowerPoint.Application;"
                "try{\$d=\$a.Presentations.Open('${q(src)}',\$true,\$false,\$false);\$d.SaveAs('${q(out)}',32);\$d.Close()}finally{\$a.Quit()}";
    // Sent encoded: paths with any characters survive.
    final units = <int>[];
    for (final u in script.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64.encode(units)])
          .timeout(const Duration(minutes: 3));
      if (await File(out).exists() && await File(out).length() > 0) return null;
      final err = '${r.stderr}'.trim();
      DiagLog.log('tools', 'office → pdf failed: ${err.length > 300 ? err.substring(0, 300) : err}');
      return err.isEmpty ? 'no file' : err;
    } on TimeoutException {
      return 'timeout';
    } catch (e) {
      return '$e';
    }
  }
}

// ------------------------------------------------------------- video

/// How a video is saved after cutting / joining.
enum VideoOut {
  /// The same picture and sound, not made again (fast; cut at the nearest
  /// key picture).
  original,

  /// ≤1080p, small enough to send.
  smaller,

  /// ≤720p, smaller still (chats, email).
  smallest,

  /// Only the sound, MP3.
  mp3,

  /// A moving picture (GIF), ≤480 px wide, 12 frames a second.
  gif,
}

class VideoTools {
  VideoTools._();

  /// [src] from [fromMs] to [toMs] (null: to the end) into [out]. True: done.
  static Future<bool> cut(AppServices s, String src, String out, VideoOut how, {int fromMs = 0, int? toMs}) async {
    final exe = s.ffmpeg.ffmpeg;
    if (exe == null) return false;
    final range = [
      if (fromMs > 0) ...['-ss', _t(fromMs)],
      if (toMs != null) ...['-to', _t(toMs)],
    ];
    final args = <String>['-hide_banner', '-loglevel', 'error', '-y', ...range, '-i', src];
    switch (how) {
      case VideoOut.original:
        args.addAll(['-map', '0', '-c', 'copy', '-avoid_negative_ts', 'make_zero', '-map_metadata', '0', '-movflags', '+faststart', out]);
      case VideoOut.mp3:
        args.addAll(['-vn', '-c:a', 'libmp3lame', '-q:a', '2', out]);
      case VideoOut.gif:
        args.addAll([
          '-vf', 'fps=12,scale=480:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4',
          '-loop', '0', out,
        ]);
      case VideoOut.smaller:
      case VideoOut.smallest:
        final enc = await s.converter.encoders.best();
        if (enc == null) return false;
        final side = how == VideoOut.smaller ? 1920 : 1280;
        args.addAll([
          '-map', '0:v:0', '-map', '0:a:0?',
          '-vf', "scale='if(gt(iw,ih),min($side,iw),-2)':'if(gt(iw,ih),-2,min($side,ih))',format=nv12",
          ...H264Encoders.args(enc, high: false),
          '-c:a', 'aac', '-b:a', '128k',
          '-map_metadata', '0', '-movflags', '+faststart',
          out,
        ]);
    }
    final ok = await s.ffmpeg.run(args);
    return ok && File(out).existsSync() && File(out).lengthSync() > 0;
  }

  /// Several videos one after another (made again, at ≤1080p, all the same
  /// size so they fit together).
  static Future<bool> join(AppServices s, List<String> videos, String out) async {
    final exe = s.ffmpeg.ffmpeg;
    final enc = await s.converter.encoders.best();
    if (exe == null || enc == null || videos.length < 2) return false;
    final args = <String>['-hide_banner', '-loglevel', 'error', '-y'];
    for (final v in videos) {
      args.addAll(['-i', v]);
    }
    final parts = StringBuffer();
    for (var i = 0; i < videos.length; i++) {
      parts.write('[$i:v:0]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=nv12[v$i];');
      parts.write('[$i:a:0]aformat=sample_rates=48000:channel_layouts=stereo[a$i];');
    }
    for (var i = 0; i < videos.length; i++) {
      parts.write('[v$i][a$i]');
    }
    parts.write('concat=n=${videos.length}:v=1:a=1[v][a]');
    args.addAll([
      '-filter_complex', parts.toString(),
      '-map', '[v]', '-map', '[a]',
      ...H264Encoders.args(enc, high: true, width: 1920, height: 1080),
      '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart', out,
    ]);
    final ok = await s.ffmpeg.run(args);
    return ok && File(out).existsSync() && File(out).lengthSync() > 0;
  }

  static String _t(int ms) => (ms / 1000).toStringAsFixed(3);
}
