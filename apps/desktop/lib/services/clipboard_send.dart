// apps/desktop/lib/services/clipboard_send.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

/// What the Windows clipboard holds, ready to send: files copied in File
/// Explorer (Ctrl+C), a picture (a screenshot, "Copy image"), or text.
class ClipboardContent {
  const ClipboardContent._({this.files = const [], this.image, this.text});

  /// Files / folders copied in File Explorer.
  final List<String> files;

  /// A picture, saved as a PNG file.
  final String? image;

  /// Plain text.
  final String? text;

  bool get isEmpty => files.isEmpty && image == null && (text == null || text!.isEmpty);

  /// Reads it. Files first (a copied file also puts its name as text), then
  /// a picture, then text. Programs' own formats (Excel cells, a PowerPoint
  /// shape) come as their text or picture form.
  static Future<ClipboardContent> read(String tempDir) async {
    final png = '$tempDir${Platform.pathSeparator}clipboard_${DateTime.now().millisecondsSinceEpoch}.png';
    final script = '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$f = [System.Windows.Forms.Clipboard]::GetFileDropList()
if (\$f -and \$f.Count -gt 0) { foreach (\$p in \$f) { "F|" + \$p }; exit 0 }
if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
  \$img = [System.Windows.Forms.Clipboard]::GetImage()
  if (\$img) { \$img.Save('${png.replaceAll("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png); "I|ok"; exit 0 }
}
"N|"
''';
    final units = <int>[];
    for (final u in script.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    try {
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', base64.encode(units)],
        stdoutEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      final lines = '${r.stdout}'.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      final files = [for (final l in lines) if (l.startsWith('F|')) l.substring(2)];
      if (files.isNotEmpty) return ClipboardContent._(files: files);
      if (lines.contains('I|ok') && await File(png).exists()) return ClipboardContent._(image: png);
      if ('${r.stderr}'.trim().isNotEmpty) DiagLog.log('clipboard', 'read: ${'${r.stderr}'.trim()}');
    } catch (e) {
      DiagLog.log('clipboard', 'files / picture not read: $e');
    }
    final t = await Clipboard.getData(Clipboard.kTextPlain);
    return ClipboardContent._(text: t?.text);
  }
}
