// apps/desktop/lib/ui/text_window.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/network.dart';
import '../services/receive_hub.dart';
import '../services/settings.dart';
import '../services/win_dialogs.dart';
import 'send_page.dart' show peerErrorText;
import 'theme.dart';

/// A small text editor: paste or type, then send to [peer]. The other PC
/// shows it in the same kind of window.
Future<void> showTextComposer(BuildContext context, AppServices s, PeerPc peer) => showDialog<void>(
      context: context,
      builder: (_) => _TextWindow(services: s, peer: peer),
    );

/// Text that arrived from another device: read, edit, copy or keep as a file.
Future<void> showReceivedText(BuildContext context, AppServices s, ReceivedText t) => showDialog<void>(
      context: context,
      builder: (_) => _TextWindow(services: s, received: t),
    );

/// Text files LocalRoll shows itself instead of handing them to Notepad.
bool isPlainTextPath(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.txt') || p.endsWith('.md') || p.endsWith('.log');
}

/// A text file from the library, shown in the same window: read, copy,
/// "Save as…", show in its folder.
Future<void> showTextFile(BuildContext context, AppServices s, String path) async {
  String text;
  try {
    text = decodeText(await File(path).readAsBytes());
  } catch (e) {
    DiagLog.error('text', e);
    await Process.run('explorer.exe', [path]);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _TextWindow(services: s, file: path, fileText: text),
  );
}

/// UTF-8 (with or without BOM), UTF-16 with BOM, else the PC's own code page
/// (GBK on a Chinese Windows, …).
String decodeText(List<int> b) {
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return utf8.decode(b.sublist(3), allowMalformed: true);
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
    final le = b[0] == 0xFF;
    final units = <int>[
      for (var i = 2; i + 1 < b.length; i += 2) le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1],
    ];
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(b);
  } on FormatException {
    try {
      return systemEncoding.decode(b);
    } catch (_) {
      return utf8.decode(b, allowMalformed: true);
    }
  }
}

class _TextWindow extends StatefulWidget {
  const _TextWindow({required this.services, this.peer, this.received, this.file, this.fileText});

  final AppServices services;
  final PeerPc? peer;
  final ReceivedText? received;

  /// A text file being shown (read only).
  final String? file;
  final String? fileText;

  @override
  State<_TextWindow> createState() => _TextWindowState();
}

class _TextWindowState extends State<_TextWindow> {
  late final TextEditingController _c = TextEditingController(text: widget.fileText ?? widget.received?.text ?? '');
  bool _busy = false;
  String? _note;

  bool get _sending => widget.peer != null;
  bool get _viewing => widget.file != null;

  /// "Save as…": the usual Windows save dialog, UTF-8 with BOM.
  Future<void> _saveAs() async {
    final suggested = _viewing ? widget.file!.split(Platform.pathSeparator).last : '${_defaultName()}.txt';
    final path = await WinDialogs.saveFile(suggestedName: suggested, typeLabel: tr('text.type_label'), extensions: const ['txt']);
    if (path == null) return;
    try {
      final base = path.split(Platform.pathSeparator).last;
      final target = base.contains('.') ? path : '$path.txt';
      await File(target).writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_c.text)], flush: true);
      if (!mounted) return;
      setState(() => _note = tr('text.saved_at', {'path': target}));
      unawaited(revealInExplorer(target));
    } catch (e) {
      DiagLog.error('text', e);
      if (mounted) setState(() => _note = tr('settings.folder_error', {'error': e}));
    }
  }

  String _defaultName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${tr('text.file_prefix')} ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text;
    if (t == null || t.isEmpty) return;
    final sel = _c.selection;
    final text = _c.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _c.value = TextEditingValue(
      text: text.replaceRange(start, end, t),
      selection: TextSelection.collapsed(offset: start + t.length),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _c.text));
    setState(() => _note = tr('text.copied'));
  }

  /// Keep it as a .txt in the library's Documents folder.
  Future<void> _save() async {
    final dir = await widget.services.server.folderPath(document: true);
    final name = '${_defaultName()}.txt';
    final f = File('$dir${Platform.pathSeparator}$name');
    // UTF-8 with BOM so Notepad and Word pick the right encoding.
    await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_c.text)]);
    if (!mounted) return;
    setState(() => _note = tr('text.saved', {'name': name}));
    revealInExplorer(f.path);
  }

  Future<void> _send() async {
    final text = _c.text;
    if (text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    final err = await widget.services.sender.sendText(widget.peer!, text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('text.sent', {'name': widget.peer!.name}))));
    } else {
      setState(() => _note = peerErrorText(err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.received;
    final title = _viewing
        ? widget.file!.split(Platform.pathSeparator).last
        : _sending
            ? tr('text.to', {'name': widget.peer!.name})
            : tr('text.from', {'name': r!.from, 'time': TimeOfDay.fromDateTime(r.time).format(context)});
    return AlertDialog(
      title: Row(children: [
        Icon(_viewing ? Icons.notes_rounded : (_sending ? Icons.edit_note_rounded : Icons.mark_chat_read_outlined), color: LrColors.safelight),
        const SizedBox(width: 10),
        Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
      ]),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _c,
            autofocus: !_viewing,
            readOnly: _viewing,
            minLines: 12,
            maxLines: 20,
            style: const TextStyle(fontSize: 15, height: 1.4),
            decoration: InputDecoration(
              hintText: _sending ? tr('text.hint') : null,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            if (_sending)
              TextButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste_rounded), label: Text(tr('text.paste'))),
            TextButton.icon(
              onPressed: _c.text.isEmpty ? null : _copy,
              icon: const Icon(Icons.copy_rounded),
              label: Text(tr('text.copy')),
            ),
            if (!_sending && !_viewing)
              TextButton.icon(
                onPressed: _c.text.isEmpty ? null : _save,
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(tr('text.save')),
              ),
            if (!_sending)
              TextButton.icon(
                onPressed: _c.text.isEmpty ? null : _saveAs,
                icon: const Icon(Icons.save_as_rounded),
                label: Text(tr('text.save_as')),
              ),
            if (_viewing)
              TextButton.icon(
                onPressed: () => revealInExplorer(widget.file!),
                icon: const Icon(Icons.folder_open_rounded),
                label: Text(tr('common.show_in_folder')),
              ),
            if (_sending)
              TextButton.icon(
                onPressed: _c.text.isEmpty ? null : _c.clear,
                icon: const Icon(Icons.clear_all_rounded),
                label: Text(tr('text.clear')),
              ),
            const Spacer(),
            Text(tr('text.count', {'count': _c.text.characters.length}), style: theme.textTheme.bodySmall),
          ]),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_note!, style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr(_sending ? 'common.cancel' : 'text.close'))),
        if (_sending)
          FilledButton.icon(
            onPressed: _busy || _c.text.trim().isEmpty ? null : _send,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            label: Text(tr('text.send')),
          ),
      ],
    );
  }
}
