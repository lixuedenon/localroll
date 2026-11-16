// apps/desktop/lib/services/pdf_fonts.dart
import 'dart:io';
import 'dart:typed_data';

/// A Windows font chosen to write new words into a PDF.
class FontChoice {
  const FontChoice(this.path, {required this.family, required this.hasBold, required this.hasItalic});

  /// A .ttf file (a face taken out of a .ttc collection when needed).
  final String path;

  /// The family's name, also for showing it on screen.
  final String family;

  /// The file is the bold / italic face itself (else they are drawn).
  final bool hasBold;
  final bool hasItalic;
}

class _Family {
  const _Family(this.family, this.keys, this.r, {this.b, this.i, this.bi, this.cjk = false, this.hangul = false});

  final String family;
  final List<String> keys;
  final String r;
  final String? b, i, bi;

  /// Holds Chinese / Japanese characters (and Latin), or Korean.
  final bool cjk;
  final bool hangul;
}

/// The Windows font closest to a PDF's font (by its name), able to write
/// the new words, in the face (bold / italic) asked for.
class PdfFonts {
  PdfFonts._();

  // More specific names first ("yahei" before "hei").
  static const _families = [
    _Family('Microsoft YaHei', ['yahei', '雅黑'], 'msyh.ttc#0', b: 'msyhbd.ttc#0', cjk: true),
    _Family('Microsoft JhengHei', ['jhenghei', '正黑'], 'msjh.ttc#0', b: 'msjhbd.ttc#0', cjk: true),
    _Family('DengXian', ['dengxian', '等线', 'deng'], 'Deng.ttf', b: 'Dengb.ttf', cjk: true),
    _Family('KaiTi', ['kaiti', 'stkaiti', '楷'], 'simkai.ttf', cjk: true),
    _Family('FangSong', ['fangsong', 'stfangsong', '仿宋'], 'simfang.ttf', cjk: true),
    _Family('SimHei', ['simhei', 'stheiti', 'heiti', '黑体', 'hei'], 'simhei.ttf', cjk: true),
    _Family('SimSun', ['simsun', 'nsimsun', 'stsong', 'songti', '宋体', 'song'], 'simsun.ttc#0', cjk: true),
    _Family('MingLiU', ['pmingliu', 'mingliu', '細明', '新細明'], 'mingliu.ttc#0', cjk: true),
    _Family('Yu Gothic', ['yugoth', 'yu gothic'], 'YuGothR.ttc#0', b: 'YuGothB.ttc#0', cjk: true),
    _Family('Meiryo', ['meiryo'], 'meiryo.ttc#0', b: 'meiryob.ttc#0', cjk: true),
    _Family('MS Mincho', ['msmincho', 'ms mincho', 'mincho', '明朝'], 'msmincho.ttc#0', cjk: true),
    _Family('MS Gothic', ['msgothic', 'ms gothic', 'gothic', 'ゴシック'], 'msgothic.ttc#0', cjk: true),
    _Family('Malgun Gothic', ['malgun'], 'malgun.ttf', b: 'malgunbd.ttf', hangul: true),
    _Family('Batang', ['batang'], 'batang.ttc#0', hangul: true),
    _Family('Gulim', ['gulim', 'dotum'], 'gulim.ttc#0', hangul: true),
    _Family('Times New Roman', ['times', 'roman'], 'times.ttf', b: 'timesbd.ttf', i: 'timesi.ttf', bi: 'timesbi.ttf'),
    _Family('Arial', ['arial', 'helvetica', 'helv'], 'arial.ttf', b: 'arialbd.ttf', i: 'ariali.ttf', bi: 'arialbi.ttf'),
    _Family('Calibri', ['calibri'], 'calibri.ttf', b: 'calibrib.ttf', i: 'calibrii.ttf', bi: 'calibriz.ttf'),
    _Family('Cambria', ['cambria'], 'cambria.ttc#0', b: 'cambriab.ttf', i: 'cambriai.ttf', bi: 'cambriaz.ttf'),
    _Family('Courier New', ['courier'], 'cour.ttf', b: 'courbd.ttf', i: 'couri.ttf', bi: 'courbi.ttf'),
    _Family('Consolas', ['consolas'], 'consola.ttf', b: 'consolab.ttf', i: 'consolai.ttf', bi: 'consolaz.ttf'),
    _Family('Verdana', ['verdana'], 'verdana.ttf', b: 'verdanab.ttf', i: 'verdanai.ttf', bi: 'verdanaz.ttf'),
    _Family('Georgia', ['georgia'], 'georgia.ttf', b: 'georgiab.ttf', i: 'georgiai.ttf', bi: 'georgiaz.ttf'),
    _Family('Tahoma', ['tahoma'], 'tahoma.ttf', b: 'tahomabd.ttf'),
    _Family('Segoe UI', ['segoe'], 'segoeui.ttf', b: 'segoeuib.ttf', i: 'segoeuii.ttf', bi: 'segoeuiz.ttf'),
    _Family('Garamond', ['garamond'], 'GARA.TTF', b: 'GARABD.TTF', i: 'GARAIT.TTF'),
    _Family('Book Antiqua', ['bookantiqua', 'book antiqua', 'palatino'], 'BKANT.TTF', b: 'ANTQUAB.TTF', i: 'ANTQUAI.TTF', bi: 'ANTQUABI.TTF'),
  ];

  static bool isCjk(int c) =>
      (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFFEF) || (c >= 0x3000 && c <= 0x30FF);
  static bool isHangul(int c) => (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0x1100 && c <= 0x11FF);

  static String get _dir => '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts';

  /// The family a PDF font name stands for (subset prefix "ABCDEF+" off).
  static _Family? _byName(String? name) {
    if (name == null || name.isEmpty) return null;
    var n = name.toLowerCase();
    final plus = n.indexOf('+');
    if (plus == 6) n = n.substring(7);
    n = n.replaceAll('-', '').replaceAll(',', '').replaceAll(' ', '');
    for (final f in _families) {
      for (final k in f.keys) {
        if (n.contains(k.replaceAll(' ', ''))) return f;
      }
    }
    if (n.contains('serif') && !n.contains('sans')) return _families.firstWhere((f) => f.family == 'Times New Roman');
    return null;
  }

  /// The family name to show for [name] (or null).
  static String? familyOf(String? name) => _byName(name)?.family;

  /// The font to write [text] with, like [like] (a PDF font name), [bold]
  /// / [italic] as asked.
  static Future<FontChoice?> pick(String text, {String? like, bool bold = false, bool italic = false}) async {
    final runes = text.runes;
    final hangul = runes.any(isHangul);
    final cjk = runes.any(isCjk);
    var fam = _byName(like);
    // The family must hold the new letters.
    if (fam != null && ((hangul && !fam.hangul) || (cjk && !fam.cjk))) fam = null;
    final order = <_Family>[
      if (fam != null) fam,
      if (hangul) ..._families.where((f) => f.hangul),
      if (cjk) ..._families.where((f) => f.family == 'Microsoft YaHei' || f.family == 'DengXian' || f.family == 'SimHei' || f.family == 'SimSun'),
      if (!cjk && !hangul) ..._families.where((f) => f.family == 'Arial' || f.family == 'Times New Roman'),
    ];
    for (final f in order) {
      final faces = <(String?, bool, bool)>[
        if (bold && italic) (f.bi, true, true),
        if (bold) (f.b, true, false),
        if (italic) (f.i, false, true),
        (f.r, false, false),
      ];
      for (final (file, b, i) in faces) {
        if (file == null) continue;
        final path = await _resolve(file);
        if (path != null) return FontChoice(path, family: f.family, hasBold: b, hasItalic: i);
      }
    }
    return null;
  }

  /// "name.ttf" → its path; "name.ttc#n" → face n taken out as a .ttf.
  static Future<String?> _resolve(String file) async {
    final hash = file.indexOf('#');
    final name = hash < 0 ? file : file.substring(0, hash);
    final f = File('$_dir\\$name');
    if (!await f.exists()) return null;
    if (hash < 0) return f.path;
    return _fromCollection(f, int.tryParse(file.substring(hash + 1)) ?? 0);
  }

  /// One face of a .ttc collection as a .ttf of its own (a PDF can only
  /// take a single font).
  static Future<String?> _fromCollection(File ttc, int index) async {
    final dir = Directory('${Directory.systemTemp.path}\\lr_fonts');
    final base = ttc.uri.pathSegments.last.split('.').first;
    final out = File('${dir.path}\\$base-$index.ttf');
    if (await out.exists() && await out.length() > 0) return out.path;
    try {
      final bytes = await ttc.readAsBytes();
      final d = ByteData.sublistView(bytes);
      if (String.fromCharCodes(bytes.sublist(0, 4)) != 'ttcf') return null;
      final count = d.getUint32(8);
      if (index >= count) return null;
      final off = d.getUint32(12 + 4 * index);
      final tables = d.getUint16(off + 4);
      final head = 12 + 16 * tables;
      var size = head;
      final recs = <(int, int, int, int)>[]; // tag, checksum, offset, length
      for (var t = 0; t < tables; t++) {
        final r = off + 12 + 16 * t;
        final len = d.getUint32(r + 12);
        recs.add((d.getUint32(r), d.getUint32(r + 4), d.getUint32(r + 8), len));
        size += (len + 3) & ~3;
      }
      final o = Uint8List(size);
      final od = ByteData.sublistView(o);
      o.setRange(0, 12, bytes, off);
      var at = head;
      for (var t = 0; t < tables; t++) {
        final (tag, sum, from, len) = recs[t];
        final r = 12 + 16 * t;
        od
          ..setUint32(r, tag)
          ..setUint32(r + 4, sum)
          ..setUint32(r + 8, at)
          ..setUint32(r + 12, len);
        o.setRange(at, at + len, bytes, from);
        at += (len + 3) & ~3;
      }
      await dir.create(recursive: true);
      await out.writeAsBytes(o, flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }
}
