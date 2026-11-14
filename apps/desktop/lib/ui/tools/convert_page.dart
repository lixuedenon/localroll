// apps/desktop/lib/ui/tools/convert_page.dart
import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/converter.dart';
import '../../services/file_tools.dart';
import '../../services/format_convert.dart';
import '../../services/win_dialogs.dart';
import '../library_picker.dart';
import '../light_look.dart';
import '../lr_dialog.dart';
import '../send_page.dart' show baseNameOf;
import '../theme.dart' show lrFontFallback;
import 'tools.dart';

/// Format conversion: pick the kind of file, turn the left wheel to what it
/// is and the right wheel to what it should become, add the files, start.
class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key, required this.services, this.files = const []});

  final AppServices services;
  final List<String> files;

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  ConvCat _cat = ConvCat.image;
  int _from = 0, _to = 1;
  final List<String> _files = [];
  bool _small = false;
  bool _over = false;

  AppServices get s => widget.services;
  List<Fmt> get _fmts => FormatTable.of(_cat);
  Fmt get _left => _fmts[_from];
  Fmt get _right => _fmts[_to];
  ConvOp? get _op => FormatTable.op(_cat, _left, _right);

  @override
  void initState() {
    super.initState();
    _fixRight();
    if (widget.files.isNotEmpty) _add(widget.files);
  }

  bool _can(int i) => FormatTable.op(_cat, _left, _fmts[i]) != null;

  /// The right wheel on something that can be done.
  void _fixRight() {
    if (_to < _fmts.length && _can(_to)) return;
    // The usual first choice: JPG / MP4 / MP3 / PDF, else the first possible.
    for (var i = 0; i < _fmts.length; i++) {
      if (_can(i)) {
        _to = i;
        return;
      }
    }
    _to = 0;
  }

  void _setCat(ConvCat c) => setState(() {
        _cat = c;
        _from = 0;
        _files.clear();
        _fixRight();
      });

  void _setFrom(int i) => setState(() {
        if (i != _from) _files.removeWhere((f) => !_fmts[i].takes(f));
        _from = i;
        _fixRight();
      });

  /// Files in: the wheels follow the first one; others of another type are
  /// left out (and said).
  void _add(List<String> paths) {
    if (paths.isEmpty) return;
    final first = paths.firstWhere((p) => !_left.takes(p), orElse: () => '');
    if (_files.isEmpty && first.isNotEmpty && !paths.any(_left.takes)) {
      final found = FormatTable.find(first, _cat);
      if (found != null) {
        final (c, f) = found;
        _cat = c;
        _from = FormatTable.of(c).indexWhere((x) => x.id == f.id);
        _fixRight();
      }
    }
    final ok = [for (final p in paths) if (_left.takes(p) && !_files.contains(p)) p];
    final left = paths.length - ok.length;
    setState(() => _files.addAll(ok));
    if (left > 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('conv.skipped', {'count': left, 'what': _left.label}))));
    }
  }

  Future<void> _pickPc() async {
    final p = await WinDialogs.pickFiles(title: tr('conv.pick_title', {'what': _left.label}), extensions: _left.exts.toList());
    if (mounted) _add(p);
  }

  Future<void> _pickLibrary() async {
    final p = await pickFromLibrary(context, s, files: true);
    if (p != null && mounted) _add(p);
  }

  Future<void> _start() async {
    final op = _op;
    if (op == null || _files.isEmpty) return;
    s.tools.current = 'convert';
    if (op.office && !await OfficePdf.available()) {
      if (!mounted) return;
      await showLrDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('conv.no_office')),
          content: SizedBox(width: 440, child: Text(tr('conv.office_needed'))),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
        ),
      );
      return;
    }
    if (!mounted) return;
    final files = List.of(_files);
    switch (op) {
      case MediaOp(:final format):
        for (final f in files) {
          s.converter.enqueueFile(f, format, preset: _small ? ConvertPreset.share : ConvertPreset.compatible);
        }
        setState(_files.clear);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('conv.queued', {'count': files.length}))));
        return;
      default:
        break;
    }
    final outs = <String>[];
    final failed = <String>[];
    await runBusy(context, tr('conv.working', {'count': files.length}), () async {
      if (op is ImagesToPdf) {
        final out = toolOutPath(s, files.first, files.length > 1 ? '-${files.length}' : '', 'pdf');
        final err = await photosToPdf(s, files, out);
        err == null ? outs.add(out) : failed.add(baseNameOf(files.first));
        return;
      }
      for (final f in files) {
        try {
          switch (op) {
            case PdfToImages(:final ext):
              outs.addAll(await FormatConverter.pdfImages(s, f, ext));
            case PdfToText():
              final out = toolOutPath(s, f, '', 'txt');
              await FormatConverter.pdfText(s, f, out);
              outs.add(out);
            case TextToPdf():
              final out = toolOutPath(s, f, '', 'pdf');
              final err = await FormatConverter.textPdf(f, out, lrFontFallback(translator.language));
              err == null ? outs.add(out) : failed.add(baseNameOf(f));
            case OfficeOp(:final kind, :final ext):
              if (kind == 'pptImages') {
                final made = await FormatConverter.pptImages(s, f, ext);
                made.isEmpty ? failed.add(baseNameOf(f)) : outs.addAll(made);
              } else {
                final out = toolOutPath(s, f, '', ext);
                final err = await FormatConverter.office(kind, f, out);
                err == null ? outs.add(out) : failed.add(baseNameOf(f));
              }
            default:
              break;
          }
        } catch (e) {
          DiagLog.log('tools', 'convert ${_left.id} → ${_right.id}: $e');
          failed.add(baseNameOf(f));
        }
      }
    });
    if (!mounted) return;
    setState(_files.clear);
    if (outs.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('conv.failed', {'names': failed.join('、')}))));
      return;
    }
    await showToolResult(context, s, outs, note: failed.isEmpty ? null : tr('conv.some_failed', {'names': failed.join('、')}));
  }

  String _catLabel(ConvCat c) => tr('conv.cat_${c.name}');

  IconData _catIcon(ConvCat c) => switch (c) {
        ConvCat.image => Icons.image_rounded,
        ConvCat.video => Icons.movie_rounded,
        ConvCat.audio => Icons.music_note_rounded,
        ConvCat.doc => Icons.description_rounded,
      };

  String _catSub(ConvCat c) => FormatTable.of(c).take(3).map((f) => f.label).join('、');

  @override
  Widget build(BuildContext context) {
    final op = _op;
    return Theme(
      data: LightLook.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: LightLook.page,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: LightLook.text,
          title: Text(tr('tool.convert')),
          actions: [ToolSaveChip(services: s), const SizedBox(width: 12)],
        ),
        body: DecoratedBox(
          decoration: LightLook.wash,
          child: ListView(padding: const EdgeInsets.fromLTRB(28, 8, 28, 28), children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final c in ConvCat.values) _tab(c),
            ]),
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, box) {
              final wheels = _wheelsCard(op);
              final files = _filesCard(op);
              if (box.maxWidth < 1000) return Column(children: [wheels, const SizedBox(height: 16), files]);
              return IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 540, child: wheels),
                  const SizedBox(width: 18),
                  Expanded(child: files),
                ]),
              );
            }),
            const SizedBox(height: 18),
            _overview(),
          ]),
        ),
      ),
    );
  }

  Widget _tab(ConvCat c) {
    final on = c == _cat;
    return GestureDetector(
      onTap: () => _setCat(c),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: on ? LightLook.blue : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? LightLook.blue : const Color(0xFFE3E8F2)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_catIcon(c), size: 20, color: on ? Colors.white : LightLook.blue),
            const SizedBox(width: 8),
            Text(_catLabel(c), style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on ? Colors.white : LightLook.text)),
            const SizedBox(width: 8),
            Text('${_catSub(c)}…', style: TextStyle(fontSize: 12, color: on ? const Color(0xFFDCE6FF) : LightLook.muted)),
          ]),
        ),
      ),
    );
  }

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(20),
        decoration: LightLook.card(),
        child: child,
      );

  Widget _wheelsCard(ConvOp? op) => _card(Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _Wheel(caption: tr('conv.from'), items: _fmts, at: _from, onChanged: _setFrom)),
          SizedBox(
            width: 120,
            child: Padding(
              padding: const EdgeInsets.only(top: 130),
              child: Column(children: [
                const Icon(Icons.arrow_forward_rounded, size: 40, color: LightLook.blue),
                const SizedBox(height: 6),
                Text('${_left.label} → ${_right.label}',
                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, color: LightLook.text)),
                if (op?.office ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _tag(tr('conv.needs_office'), const Color(0xFFFFF0E3), const Color(0xFFC0560A)),
                  ),
              ]),
            ),
          ),
          Expanded(
            child: _Wheel(
              caption: tr('conv.to'),
              items: _fmts,
              at: _to,
              enabled: _can,
              onChanged: (i) => setState(() => _to = i),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Text(tr('conv.wheel_hint'), textAlign: TextAlign.center, style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
        if (_left.id == 'pdf' && _right.id == 'word')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tr('conv.pdf_word_note'), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFC0560A), fontSize: 12.5)),
          ),
      ]));

  Widget _filesCard(ConvOp? op) => _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropTarget(
          onDragEntered: (_) => setState(() => _over = true),
          onDragExited: (_) => setState(() => _over = false),
          onDragDone: (d) {
            setState(() => _over = false);
            _add([for (final f in d.files) f.path]);
          },
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              color: _over ? const Color(0xFFE8EFFF) : const Color(0xFFF8FAFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _over ? LightLook.blue : const Color(0xFFB9C8EA), width: _over ? 2 : 1.5),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(tr('conv.drop', {'what': _left.label}),
                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: LightLook.text)),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                OutlinedButton(onPressed: _pickPc, child: Text(tr('send.files_pc'))),
                const SizedBox(width: 10),
                OutlinedButton(onPressed: _pickLibrary, child: Text(tr('send.files_library'))),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        if (_files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(tr('conv.no_files'), textAlign: TextAlign.center, style: const TextStyle(color: LightLook.muted)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(shrinkWrap: true, children: [
              for (final f in _files)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.insert_drive_file_outlined, color: LightLook.muted),
                  title: Text(baseNameOf(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: tr('conv.remove'),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() => _files.remove(f)),
                  ),
                ),
            ]),
          ),
        if (op is MediaOp && op.format.kind != FormatKind.audio) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text(tr('conv.quality'), style: const TextStyle(color: LightLook.text)),
            const SizedBox(width: 12),
            ChoiceChip(label: Text(tr('conv.q_high')), selected: !_small, onSelected: (_) => setState(() => _small = false)),
            const SizedBox(width: 8),
            ChoiceChip(label: Text(tr('conv.q_small')), selected: _small, onSelected: (_) => setState(() => _small = true)),
          ]),
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: Text(op is MediaOp ? tr('conv.queue_note') : '', style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: LightLook.blue, shape: const StadiumBorder()),
            onPressed: op == null || _files.isEmpty ? null : _start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(tr('conv.start', {'count': _files.length})),
          ),
        ]),
      ]));

  Widget _tag(String t, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(t, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
      );

  /// Everything that can be done, by kind: "HEIC → JPG、PNG…".
  Widget _overview() {
    Widget cat(ConvCat c) {
      final fmts = FormatTable.of(c);
      final rows = <Widget>[];
      for (final a in fmts) {
        final to = [for (final b in fmts) if (FormatTable.op(c, a, b) != null) b];
        if (to.isEmpty) continue;
        final office = to.every((b) => FormatTable.op(c, a, b)!.office);
        final some = to.any((b) => FormatTable.op(c, a, b)!.office);
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '${a.label} → ', style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: to.map((b) => b.label + (!office && FormatTable.op(c, a, b)!.office ? '*' : '')).join('、')),
            if (office || some)
              WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(padding: const EdgeInsets.only(left: 6), child: _tag(tr('conv.needs_office'), const Color(0xFFFFF0E3), const Color(0xFFC0560A)))),
          ])),
        ));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_catIcon(c), size: 18, color: LightLook.blue),
          const SizedBox(width: 6),
          Text(_catLabel(c), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: LightLook.text)),
        ]),
        const SizedBox(height: 8),
        DefaultTextStyle.merge(style: const TextStyle(fontSize: 12.5, color: Color(0xFF38445A), height: 1.4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows)),
      ]);
    }

    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('conv.all_title'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: LightLook.text)),
      const SizedBox(height: 4),
      Text(tr('conv.all_hint'), style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
      const SizedBox(height: 14),
      LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth > 1000 ? 4 : 2;
        final w = (box.maxWidth - 20 * (cols - 1)) / cols;
        return Wrap(spacing: 20, runSpacing: 18, children: [
          for (final c in ConvCat.values) SizedBox(width: w, child: cat(c)),
        ]);
      }),
    ]));
  }
}

/// A wheel of formats: the mouse wheel or a click turns it; [enabled]
/// false: shown struck out, skipped when turning.
class _Wheel extends StatelessWidget {
  const _Wheel({required this.caption, required this.items, required this.at, required this.onChanged, this.enabled});

  final String caption;
  final List<Fmt> items;
  final int at;
  final ValueChanged<int> onChanged;
  final bool Function(int i)? enabled;

  bool _ok(int i) => enabled?.call(i) ?? true;

  void _step(int d) {
    var i = at;
    for (var n = 0; n < items.length; n++) {
      i = (i + d) % items.length;
      if (i < 0) i += items.length;
      if (_ok(i)) return onChanged(i);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Text(caption, style: const TextStyle(color: LightLook.muted, fontSize: 13)),
        const SizedBox(height: 8),
        Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && e.scrollDelta.dy != 0) _step(e.scrollDelta.dy > 0 ? 1 : -1);
          },
          child: Container(
            height: 300,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE3E8F2)),
            ),
            child: Stack(children: [
              Positioned(
                left: 8,
                right: 8,
                top: 120,
                height: 60,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8EFFF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: LightLook.blue, width: 2),
                  ),
                ),
              ),
              Column(children: [
                for (var k = -2; k <= 2; k++) _slot(k),
              ]),
            ]),
          ),
        ),
      ]);

  Widget _slot(int k) {
    final i = (at + k) % items.length;
    final idx = i < 0 ? i + items.length : i;
    final ok = _ok(idx);
    final center = k == 0;
    final far = k.abs() == 2;
    return SizedBox(
      height: 60,
      child: InkWell(
        onTap: ok ? () => onChanged(idx) : null,
        child: Center(
          child: Text(
            items[idx].label,
            style: TextStyle(
              fontSize: center ? 25 : (far ? 17 : 19.5),
              fontWeight: center ? FontWeight.w800 : FontWeight.w500,
              color: !ok ? const Color(0xFFC8CFDB) : (center ? LightLook.text : (far ? const Color(0xFFA3AEC0) : const Color(0xFF7C889C))),
              decoration: ok ? null : TextDecoration.lineThrough,
            ),
          ),
        ),
      ),
    );
  }
}
