// apps/desktop/lib/ui/tools/image_tool_page.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../send_paths.dart';
import 'tools.dart';

/// A photo's editor (crop, turn, colour, squares over private parts,
/// smaller): saved as a new JPEG beside it; the original stays.
class ImageToolPage extends StatefulWidget {
  const ImageToolPage({super.key, required this.services, required this.path});

  final AppServices services;
  final String path;

  @override
  State<ImageToolPage> createState() => _ImageToolPageState();
}

class _ImageToolPageState extends State<ImageToolPage> {
  Uint8List? _bytes;
  String? _error;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final e = extensionOf(widget.path);
      Uint8List? b;
      if (const {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'}.contains(e)) {
        b = await File(widget.path).readAsBytes();
      } else {
        // HEIC and others: an upright full-size JPEG first.
        final j = await uprightJpeg(s, widget.path, max: 8192);
        if (j != null) b = await File(j.$1).readAsBytes();
      }
      if (!mounted) return;
      setState(() => b == null ? _error = tr('image.cannot_open') : _bytes = b);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<String> _write(Uint8List jpeg) async {
    final out = toolOutPath(s, widget.path, tr('image.suffix'), 'jpg');
    await File(out).writeAsBytes(jpeg);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    return Scaffold(
      backgroundColor: const Color(0xFF141B26),
      appBar: AppBar(backgroundColor: const Color(0xFF1D2633), title: Text(baseNameOf(widget.path), overflow: TextOverflow.ellipsis)),
      body: b == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: const TextStyle(color: Colors.white)))
          : PhotoEditor(
              bytes: b,
              texts: (k) => tr('pe.$k'),
              onSave: (jpeg, _) async {
                final out = await _write(jpeg);
                if (mounted) await showToolResult(context, s, [out]);
              },
              extraActions: [
                (
                  tr('tool.send'),
                  Icons.send_rounded,
                  (jpeg) async {
                    final out = await _write(jpeg);
                    if (!mounted) return;
                    final ids = await pickDevices(context, s, count: 1, first: baseNameOf(out));
                    if (ids != null && ids.isNotEmpty && mounted) await sendPathsTo(context, s, ids, [out]);
                  },
                ),
              ],
            ),
    );
  }
}
