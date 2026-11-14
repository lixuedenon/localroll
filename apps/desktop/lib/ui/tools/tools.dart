// apps/desktop/lib/ui/tools/tools.dart
import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/converter.dart';
import '../../services/file_tools.dart';
import '../../services/tool_outputs.dart';
import '../../services/network.dart' show revealInExplorer;
import '../../services/win_dialogs.dart';
import '../app_nav.dart';
import '../format.dart';
import '../library_picker.dart';
import '../light_dialog.dart';
import '../light_look.dart';
import '../screen/screen_record.dart' show snipBarGo, snipScreen;
import '../send_paths.dart';
import '../send_page.dart' show baseNameOf;
import 'convert_page.dart';
import 'image_tool_page.dart';
import 'pdf_tool_page.dart';
import 'qr_tool.dart';
import 'video_tool_page.dart';
import '../lr_dialog.dart';

/// What a tool takes.
enum ToolInput { photos, videos, pdfs, office, any, none }

/// The everyday tools (Home's grid, the Tools page, right-click menus).
enum Tool {
  convert(Icons.swap_horiz_rounded, Color(0xFFE6F0FF), Color(0xFF2F6BFF), ToolInput.any),
  heicJpg(Icons.image_rounded, Color(0xFFE6F0FF), Color(0xFF2F6BFF), ToolInput.photos),
  compressVideo(Icons.movie_filter_rounded, Color(0xFFFFEEDE), Color(0xFFE8740C), ToolInput.videos),
  photosPdf(Icons.picture_as_pdf_rounded, Color(0xFFE3F7EC), Color(0xFF16A36A), ToolInput.photos),
  pdfTools(Icons.description_rounded, Color(0xFFF2E8FF), Color(0xFF7B4DEB), ToolInput.pdfs),
  cutVideo(Icons.content_cut_rounded, Color(0xFFFFF4D6), Color(0xFFC98A00), ToolInput.videos),
  editImage(Icons.auto_fix_high_rounded, Color(0xFFFFE3E3), Color(0xFFD64545), ToolInput.photos),
  snipText(Icons.document_scanner_rounded, Color(0xFFE6F7F7), Color(0xFF119C9C), ToolInput.none),
  qr(Icons.qr_code_2_rounded, Color(0xFFEEF1F6), Color(0xFF3C4A63), ToolInput.none),
  officePdf(Icons.slideshow_rounded, Color(0xFFFFEEDE), Color(0xFFD9541E), ToolInput.office),
  videoToAudio(Icons.music_note_rounded, Color(0xFFE3F7EC), Color(0xFF0E8F5B), ToolInput.videos),
  compressPhoto(Icons.photo_size_select_small_rounded, Color(0xFFE6F0FF), Color(0xFF1F5FD6), ToolInput.photos);

  const Tool(this.icon, this.bg, this.fg, this.input);

  final IconData icon;
  final Color bg, fg;
  final ToolInput input;

  String get title => tr('tool.$name');
  String get sub => this == snipText && snipKeyLabel.isNotEmpty ? '${tr('tool.${name}_sub')} · $snipKeyLabel' : tr('tool.${name}_sub');

  /// The snip key now in use ("Ctrl+Alt+X"), '' when off.
  static String snipKeyLabel = '';

  /// The file types it takes (without dots), for the file dialog.
  List<String>? get extensions => switch (input) {
        ToolInput.photos => const ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'bmp', 'gif', 'tif', 'tiff', 'avif'],
        ToolInput.videos => const ['mp4', 'mov', 'm4v', 'mkv', 'avi', 'wmv', 'webm', '3gp', 'mts', 'm2ts', 'flv'],
        ToolInput.pdfs => const ['pdf'],
        ToolInput.office => [...OfficePdf.word, ...OfficePdf.excel, ...OfficePdf.powerpoint],
        ToolInput.any || ToolInput.none => null,
      };

  /// Now part of "Format conversion" (kept for right-click menus).
  bool get inConvert => this == heicJpg || this == videoToAudio || this == officePdf;

  bool takes(String path) {
    if (input == ToolInput.any) return true;
    final e = extensionOf(path);
    final x = extensions;
    return x != null && x.contains(e);
  }

  /// Works on several files at once.
  bool get many => this != Tool.editImage;
}

/// The tools as tiles. [all]: every tool (the Tools page), else the Home
/// set with "All tools" last. Files dropped on a tile go to that tool.
class ToolsGrid extends StatefulWidget {
  const ToolsGrid({super.key, required this.services, this.all = false});

  final AppServices services;
  final bool all;

  @override
  State<ToolsGrid> createState() => _ToolsGridState();
}

class _ToolsGridState extends State<ToolsGrid> {
  Tool? _over;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth > 1100 ? 6 : (c.maxWidth > 820 ? 4 : (c.maxWidth > 560 ? 3 : 2));
        final w = (c.maxWidth - (cols - 1) * 12) / cols;
        final shown = [for (final t in Tool.values) if (!t.inConvert) t];
        final tools = widget.all ? shown : shown.take(11).toList();
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final t in tools) SizedBox(width: w, child: _tile(t)),
          if (!widget.all)
            SizedBox(
              width: w,
              child: _card(
                icon: Icons.apps_rounded,
                bg: const Color(0xFFEEF1F6),
                fg: const Color(0xFF3C4A63),
                title: tr('tool.all'),
                sub: tr('tool.all_sub'),
                onTap: () => AppNav.instance.selectTab(AppNav.convert),
              ),
            ),
        ]);
      });

  Widget _tile(Tool t) => DropTarget(
        enable: t.input != ToolInput.none,
        onDragEntered: (_) => setState(() => _over = t),
        onDragExited: (_) => setState(() => _over = null),
        onDragDone: (d) {
          setState(() => _over = null);
          final paths = [for (final f in d.files) f.path];
          if (paths.isNotEmpty) unawaited(openTool(context, widget.services, t, paths: paths));
        },
        child: _card(
          icon: t.icon,
          bg: t.bg,
          fg: t.fg,
          title: t.title,
          sub: t.sub,
          over: _over == t,
          onTap: () => unawaited(openTool(context, widget.services, t)),
        ),
      );

  Widget _card({
    required IconData icon,
    required Color bg,
    required Color fg,
    required String title,
    required String sub,
    required VoidCallback onTap,
    bool over = false,
  }) =>
      Material(
        color: over ? bg : Colors.white,
        borderRadius: BorderRadius.circular(16),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: over ? fg : const Color(0xFFE6EBF3), width: over ? 2 : 1),
              boxShadow: const [BoxShadow(color: Color(0x0F1E3C78), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: fg, size: 22),
              ),
              const SizedBox(height: 10),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: LightLook.text)),
              const SizedBox(height: 2),
              Text(over ? tr('tool.drop') : sub,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: over ? fg : LightLook.muted)),
            ]),
          ),
        ),
      );
}

/// Opens [tool] on [paths] (none: asks where the files are — the library or
/// a folder on this PC).
Future<void> openTool(BuildContext context, AppServices s, Tool tool, {List<String>? paths}) async {
  s.tools.current = tool.name;
  var files = paths;
  if (tool == Tool.convert) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConvertPage(services: s, files: paths ?? const [])));
    return;
  }
  if (tool.input != ToolInput.none) {
    files ??= await _pickInputs(context, s, tool);
    if (files == null || files.isEmpty || !context.mounted) return;
    final ok = [for (final f in files) if (tool.takes(f)) f];
    if (ok.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.wrong_files', {'tool': tool.title}))));
      return;
    }
    files = ok;
  }
  if (!context.mounted) return;
  DiagLog.log('tools', '${tool.name}: ${files?.length ?? 0} files');
  switch (tool) {
    case Tool.heicJpg:
      _queue(context, s, files!, format: ConvertFormat.jpg);
    case Tool.compressPhoto:
      _queue(context, s, files!, preset: ConvertPreset.share);
    case Tool.compressVideo:
      _queue(context, s, files!, preset: ConvertPreset.share);
    case Tool.videoToAudio:
      final f = await showLrDialog<ConvertFormat>(
        context: context,
        builder: (c) => SimpleDialog(title: Text(tool.title), children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ConvertFormat.mp3), child: Text(tr('tool.as_mp3'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ConvertFormat.gif), child: Text(tr('tool.as_gif'))),
        ]),
      );
      if (f != null && context.mounted) _queue(context, s, files!, format: f);
    case Tool.photosPdf:
      await _photosPdf(context, s, files!);
    case Tool.officePdf:
      await _officePdf(context, s, files!);
    case Tool.pdfTools:
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfToolPage(services: s, files: files!)));
    case Tool.cutVideo:
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoToolPage(services: s, files: files!)));
    case Tool.editImage:
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageToolPage(services: s, path: files!.first)));
    case Tool.snipText:
      final shot = await snipScreen(context, s, live: true);
      if (shot != null && context.mounted) await showSnipResult(context, s, shot);
    case Tool.qr:
      await showQrTool(context, s);
    case Tool.convert:
      break;
  }
}

/// Where the files are: the library, or a folder on this PC.
Future<List<String>?> _pickInputs(BuildContext context, AppServices s, Tool tool) async {
  final media = tool.input == ToolInput.photos || tool.input == ToolInput.videos;
  var where = 'folder';
  if (media) {
    final w = await showLrDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: Text(tool.title), children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, 'library'),
          child: ListTile(leading: const Icon(Icons.photo_library_rounded), title: Text(tr('tool.from_library'))),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, 'folder'),
          child: ListTile(leading: const Icon(Icons.folder_open_rounded), title: Text(tr('tool.from_folder'))),
        ),
      ]),
    );
    if (w == null) return null;
    where = w;
  }
  if (where == 'library') {
    if (!context.mounted) return null;
    return pickFromLibrary(context, s, multiple: tool.many);
  }
  return WinDialogs.pickFiles(title: tool.title, multiple: tool.many, extensions: tool.extensions);
}

void _queue(BuildContext context, AppServices s, List<String> files, {ConvertFormat? format, ConvertPreset preset = ConvertPreset.compatible}) {
  for (final f in files) {
    s.converter.enqueueFile(f, format, preset: preset);
  }
  AppNav.instance.selectTab(AppNav.convert);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.queued', {'count': files.length}))));
}

/// Something that takes a moment, with a turning circle; then the result.
Future<T?> runBusy<T>(BuildContext context, String what, Future<T> Function() job) async {
  final nav = Navigator.of(context);
  unawaited(showLrDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 18),
          Flexible(child: Text(what)),
        ]),
      ),
    ),
  ));
  try {
    return await job();
  } finally {
    nav.pop();
  }
}

Future<void> _photosPdf(BuildContext context, AppServices s, List<String> photos) async {
  final out = toolOutPath(s, photos.first, photos.length > 1 ? '-${photos.length}' : '', 'pdf');
  final err = await runBusy(context, tr('tool.making_pdf', {'count': photos.length}), () => photosToPdf(s, photos, out));
  if (!context.mounted) return;
  if (err != null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': err}))));
    return;
  }
  await showToolResult(context, s, [out]);
}

Future<void> _officePdf(BuildContext context, AppServices s, List<String> docs) async {
  if (!await OfficePdf.available()) {
    if (!context.mounted) return;
    await showLrDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded, size: 30),
        title: Text(tr('tool.office_missing')),
        content: SizedBox(width: 440, child: Text(tr('tool.office_missing_body'))),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
      ),
    );
    return;
  }
  if (!context.mounted) return;
  final outs = <String>[];
  final failed = <String>[];
  await runBusy(context, tr('tool.office_working', {'count': docs.length}), () async {
    for (final d in docs) {
      final out = toolOutPath(s, d, '', 'pdf');
      final err = await OfficePdf.convert(d, out);
      if (err == null) {
        outs.add(out);
      } else {
        failed.add(baseNameOf(d));
      }
    }
  });
  if (!context.mounted) return;
  if (failed.isNotEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.office_failed', {'names': failed.join('、')}))));
  }
  if (outs.isNotEmpty) await showToolResult(context, s, outs);
}

/// Done: the new files, and what to do with them — open, show in the
/// folder, send to devices, give to a guest.
Future<void> showToolResult(BuildContext context, AppServices s, List<String> outs, {String? note}) async {
  // Into the library / files list, a copy beside the original if wanted,
  // and into the tools' record.
  await s.tools.saved(outs);
  if (!context.mounted) return;
  final where = savedWhere(s, outs.first);
  return showLrDialog<void>(
      context: context,
      builder: (c) => LightDialog(
        icon: Icons.check_circle_rounded,
        title: tr('tool.done_title'),
        subtitle: '${note ?? tr('tool.done_sub', {'count': outs.length})}\n$where',
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(c);
              s.guest.share(outs);
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.guest_added'))));
            },
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: Text(tr('tool.to_guest')),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(c);
              final ids = await pickDevices(context, s, count: outs.length, first: baseNameOf(outs.first));
              if (ids != null && ids.isNotEmpty && context.mounted) await sendPathsTo(context, s, ids, outs);
            },
            icon: const Icon(Icons.send_rounded, size: 18),
            label: Text(tr('tool.send')),
          ),
          FilledButton.tonal(onPressed: () => Navigator.pop(c), child: Text(tr('common.done'))),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final o in outs.take(8))
            LightRow(
              icon: Icons.insert_drive_file_rounded,
              iconBg: const Color(0xFFE6F0FF),
              title: baseNameOf(o),
              sub: File(o).existsSync() ? formatBytes(File(o).lengthSync()) : null,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: tr('common.open'),
                  onPressed: () => unawaited(Process.run('rundll32', ['url.dll,FileProtocolHandler', o])),
                  icon: const Icon(Icons.open_in_new_rounded, size: 20),
                ),
                IconButton(
                  tooltip: tr('common.show_in_folder'),
                  onPressed: () => unawaited(revealInExplorer(o)),
                  icon: const Icon(Icons.folder_open_rounded, size: 20),
                ),
              ]),
            ),
          if (outs.length > 8) Text('… +${outs.length - 8}', style: const TextStyle(color: LightLook.muted)),
          const SizedBox(height: 6),
          Align(alignment: Alignment.centerLeft, child: ToolSaveChip(services: s)),
        ]),
      ),
    );
}

/// "Saved in the library (Keepnear Tools)" / "Saved next to the original".
String savedWhere(AppServices s, String out) {
  final tools = toolsFolderOf(s);
  final inTools = tools != null && out.toLowerCase().startsWith('${tools.toLowerCase()}${Platform.pathSeparator}');
  final r = s.tools.of(out);
  if (inTools) {
    return tr(r?.copy != null ? 'tool.saved_both' : 'tool.saved_library', {'folder': tools.split(Platform.pathSeparator).last});
  }
  return tr('tool.saved_beside');
}

/// Where the tools' results go: the library (default), next to the
/// original, or both. Kept for next time.
class ToolSaveChip extends StatelessWidget {
  const ToolSaveChip({super.key, required this.services, this.dark = false});

  final AppServices services;

  /// On the tools' dark pages.
  final bool dark;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final now = ToolSaveTo.of(services.settings.toolSaveTo);
          final fg = dark ? Colors.white70 : LightLook.muted;
          return PopupMenuButton<ToolSaveTo>(
            tooltip: tr('tool.save_to_tip'),
            initialValue: now,
            onSelected: (v) => unawaited(services.settings.update((x) => x.toolSaveTo = v.name)),
            itemBuilder: (_) => [
              for (final v in ToolSaveTo.values)
                CheckedPopupMenuItem(value: v, checked: v == now, child: Text(tr('tool.save_${v.name}'))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.save_alt_rounded, size: 16, color: fg),
                const SizedBox(width: 6),
                Text('${tr('tool.save_to')}${tr('tool.save_${now.name}')}', style: TextStyle(fontSize: 13, color: fg)),
                Icon(Icons.arrow_drop_down_rounded, size: 20, color: fg),
              ]),
            ),
          );
        },
      );
}

/// A snip: the picture, the words read in it (Windows' own reader), copy /
/// save / send.
Future<void> showSnipResult(BuildContext context, AppServices s, File shot) async {
  final text = await runBusy(context, tr('tool.reading'), () async => s.textIndexer.ocr.read(shot.path));
  if (!context.mounted) return;
  final ctl = TextEditingController(text: text ?? '');
  await showLrDialog<void>(
    context: context,
    builder: (c) => LightDialog(
      icon: Icons.document_scanner_rounded,
      title: Tool.snipText.title,
      subtitle: (text ?? '').trim().isEmpty ? tr('tool.no_text') : tr('tool.text_found'),
      width: 760,
      actions: [
        OutlinedButton.icon(
          onPressed: () async {
            final out = await WinDialogs.saveFile(suggestedName: 'Snip ${DateTime.now().millisecondsSinceEpoch}.png', extensions: const ['png']);
            if (out != null) await shot.copy(out);
          },
          icon: const Icon(Icons.save_alt_rounded, size: 18),
          label: Text(tr('tool.save_picture')),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final ids = await pickDevices(c, s, count: 1, first: 'Snip.png');
            if (ids != null && ids.isNotEmpty && c.mounted) await sendPathsTo(c, s, ids, [shot.path]);
          },
          icon: const Icon(Icons.send_rounded, size: 18),
          label: Text(tr('tool.send_picture')),
        ),
        FilledButton.icon(
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: ctl.text)));
            Navigator.pop(c);
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('xfer.copied'))));
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(tr('tool.copy_text')),
        ),
      ],
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300, maxHeight: 320),
          child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(shot, fit: BoxFit.contain)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: TextField(
            controller: ctl,
            maxLines: 14,
            minLines: 8,
            decoration: const InputDecoration(border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
          ),
        ),
      ]),
    ),
  );
}

bool _snipping = false;

/// The snip key was pressed anywhere in Windows: box part of the screen,
/// read its words; then Keepnear goes back to how it was (hidden,
/// minimized or open).
Future<void> snipFromKey(AppServices s) async {
  // The snip bar is up: the key means "snip now".
  if (snipBarGo()) return;
  if (_snipping) return;
  _snipping = true;
  try {
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (ctx == null) return;
    final wasVisible = await windowManager.isVisible();
    final wasMinimized = await windowManager.isMinimized();
    s.tools.current = Tool.snipText.name;
    DiagLog.log('tools', 'snip from the global key');
    if (!ctx.mounted) return;
    final shot = await snipScreen(ctx, s);
    if (shot != null && ctx.mounted) {
      await windowManager.focus();
      if (!ctx.mounted) return;
      await showSnipResult(ctx, s, shot);
    }
    if (!wasVisible) {
      await windowManager.hide();
    } else if (wasMinimized) {
      await windowManager.minimize();
    }
  } catch (e) {
    DiagLog.log('tools', 'snip from the key failed: $e');
  } finally {
    _snipping = false;
  }
}
