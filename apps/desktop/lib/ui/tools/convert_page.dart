// apps/desktop/lib/ui/tools/convert_page.dart
import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/converter.dart';
import '../../services/elevation.dart';
import '../../services/office_engines.dart';
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

/// Files of one format, and what they become.
class _Group {
  _Group(this.cat, this.from, this.to);

  ConvCat cat;
  Fmt from;
  Fmt to;
  final List<String> files = [];

  ConvOp? get op => FormatTable.op(cat, from, to);
}

class _ConvertPageState extends State<ConvertPage> {
  ConvCat _cat = ConvCat.image;
  int _from = 0, _to = 1;

  /// Files in, by format; each group has its own target.
  final List<_Group> _groups = [];

  /// The group the wheels show (null: the wheels are free).
  _Group? _sel;
  bool _small = false;
  bool _over = false;

  /// Office programs here (Office / WPS / LibreOffice), looked up once.
  Set<OfficeApp> _apps = const {};

  AppServices get s => widget.services;
  List<Fmt> get _fmts => FormatTable.of(_cat);
  Fmt get _left => _fmts[_from];
  Fmt get _right => _fmts[_to];
  ConvOp? get _op => FormatTable.op(_cat, _left, _right);
  int get _count => _groups.fold(0, (n, g) => n + g.files.length);

  @override
  void initState() {
    super.initState();
    _fixRight();
    if (widget.files.isNotEmpty) _add(widget.files);
    unawaited(OfficeEngines.installed().then((a) {
      if (mounted) setState(() => _apps = a);
    }));
  }

  bool _can(int i) => FormatTable.op(_cat, _left, _fmts[i]) != null;

  /// The right wheel on something that can be done.
  void _fixRight() {
    if (_to < _fmts.length && _can(_to)) return;
    for (var i = 0; i < _fmts.length; i++) {
      if (_can(i)) {
        _to = i;
        return;
      }
    }
    _to = 0;
  }

  /// The wheels show [g] (and turning "to" changes its target).
  void _show(_Group g) {
    final list = FormatTable.of(g.cat);
    _sel = g;
    _cat = g.cat;
    _from = list.indexWhere((x) => x.id == g.from.id);
    _to = list.indexWhere((x) => x.id == g.to.id);
  }

  void _setCat(ConvCat c) => setState(() {
        _sel = null;
        _cat = c;
        _from = 0;
        _fixRight();
      });

  void _setFrom(int i) => setState(() {
        _sel = null;
        _from = i;
        _fixRight();
      });

  void _setTo(int i) => setState(() {
        _to = i;
        final g = _sel;
        if (g != null) g.to = _fmts[i];
      });

  /// Files in, any formats: each goes to the group of its format (a new
  /// group starts on its recommended target, or what the wheels show).
  void _add(List<String> paths) {
    if (paths.isEmpty) return;
    final have = {for (final g in _groups) ...g.files};
    _Group? first;
    var skipped = 0;
    for (final p in paths) {
      if (have.contains(p)) continue;
      final found = FormatTable.find(p, _cat);
      if (found == null) {
        skipped++;
        continue;
      }
      final (c, f) = found;
      var g = _groups.where((x) => x.from.id == f.id).firstOrNull;
      if (g == null) {
        final choices = FormatTable.choicesFor(p, c);
        if (choices.isEmpty) {
          skipped++;
          continue;
        }
        final op = _op;
        g = (_sel == null && _cat == c && _left.id == f.id && op != null)
            ? _Group(c, f, _right)
            : _Group(choices.first.cat, choices.first.from, choices.first.to);
        _groups.add(g);
      }
      g.files.add(p);
      have.add(p);
      first ??= g;
    }
    final show = first;
    setState(() {
      if (show != null) _show(show);
    });
    if (skipped > 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('conv.skipped_any', {'count': skipped}))));
    }
  }

  /// Every format the page can take (pick several kinds at once).
  List<String> get _allExts => {
        for (final c in ConvCat.values)
          for (final f in FormatTable.of(c)) ...f.exts,
      }.toList();

  Future<void> _pickPc() async {
    final p = await WinDialogs.pickFiles(title: tr('conv.pick_any'), extensions: _allExts);
    if (mounted) _add(p);
  }

  Future<void> _pickLibrary() async {
    final p = await pickFromLibrary(context, s, files: true);
    if (p != null && mounted) _add(p);
  }

  /// Which office program would do [op] for [src] (null: none here).
  OfficeApp? _engine(ConvOp op, String src) {
    if (!op.office) return null;
    final kind = op is OfficeOp ? (op.kind == 'pptImages' ? 'pdf' : op.kind) : 'pdf';
    return OfficeEngines.pickFrom(_apps, kind, src);
  }

  /// The tag after an Office pair: "with WPS" / "needs Office…".
  Widget? _engineTag(ConvOp? op, String src) {
    if (op == null || !op.office) return null;
    final a = _engine(op, src);
    return a == null
        ? _tag(tr('conv.engine_none'), const Color(0xFFFDECEC), const Color(0xFFB42318))
        : _tag(tr('conv.engine_use', {'app': a.label}), const Color(0xFFFFF0E3), const Color(0xFFC0560A));
  }

  Future<void> _start() async {
    if (_groups.isEmpty) return;
    s.tools.current = 'convert';
    var groups = [for (final g in _groups) if (g.op != null) g];
    // Office pairs with no program here: say which, go on with the rest.
    final blocked = [for (final g in groups) if (g.op!.office && _engine(g.op!, g.files.first) == null) g];
    if (blocked.isNotEmpty) {
      final go = await showLrDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('conv.no_engine_title')),
          content: SizedBox(
            width: 460,
            child: Text(tr('conv.no_engine_body', {'what': blocked.map((g) => '${g.from.label} → ${g.to.label}').join('、')})),
          ),
          actions: [
            TextButton(
              onPressed: () => unawaited(Process.start('cmd', ['/c', 'start', '', 'https://www.libreoffice.org/download/download/'])),
              child: Text(tr('conv.get_libre')),
            ),
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
            if (blocked.length < groups.length) FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('conv.go_on'))),
          ],
        ),
      );
      if (go != true) return;
      groups = [for (final g in groups) if (!blocked.contains(g)) g];
    }
    if (!mounted || groups.isEmpty) return;
    // Pictures, video, sound: the conversion queue.
    var queued = 0;
    for (final g in groups) {
      final op = g.op;
      if (op is MediaOp) {
        for (final f in g.files) {
          s.converter.enqueueFile(f, op.format, preset: _small ? ConvertPreset.share : ConvertPreset.compatible);
          queued++;
        }
      }
    }
    final rest = [for (final g in groups) if (g.op is! MediaOp) g];
    final count = rest.fold(0, (n, g) => n + g.files.length);
    setState(() {
      _groups.clear();
      _sel = null;
    });
    if (queued > 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('conv.queued', {'count': queued}))));
    }
    if (rest.isEmpty) return;
    final outs = <String>[];
    final failed = <String>[];
    await runBusy(context, tr('conv.working', {'count': count}), () async {
      for (final g in rest) {
        await _convert(g.op!, g.files, outs, failed);
      }
    });
    if (!mounted) return;
    if (outs.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('conv.failed', {'names': failed.join('、')}))));
      return;
    }
    await showToolResult(context, s, outs, note: failed.isEmpty ? null : tr('conv.some_failed', {'names': failed.join('、')}));
  }

  /// One group's documents (PDF, text, Office work).
  Future<void> _convert(ConvOp op, List<String> files, List<String> outs, List<String> failed) async {
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
        DiagLog.log('tools', 'convert $f: $e');
        failed.add(baseNameOf(f));
      }
    }
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
          actions: [
            // Several office programs here: which does the Office work.
            if (_apps.length > 1) _engineMenu(),
            const SizedBox(width: 8),
            ToolSaveChip(services: s),
            const SizedBox(width: 12),
          ],
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

  Widget _engineMenu() => PopupMenuButton<String>(
        tooltip: '',
        onSelected: (v) {
          setState(() => s.settings.officeEngine = OfficeEngines.preferred = v);
          unawaited(s.settings.save());
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'auto', child: Text(tr('conv.engine_auto'))),
          for (final a in OfficeApp.values)
            if (_apps.contains(a)) PopupMenuItem(value: a.name, child: Text(a.label)),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFB9C8EA))),
          child: Text(
            '${tr('conv.engine_pick')}：${OfficeApp.values.where((a) => a.name == OfficeEngines.preferred).firstOrNull?.label ?? tr('conv.engine_auto')} ▾',
            style: const TextStyle(fontSize: 13, color: LightLook.text),
          ),
        ),
      );

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
                    child: _engineTag(op, _sel?.files.first ?? 'x.${_left.exts.first}')!,
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
              onChanged: _setTo,
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

  Widget _filesCard(ConvOp? op) {
    final video = _groups.any((g) {
      final o = g.op;
      return o is MediaOp && o.format.kind != FormatKind.audio;
    });
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropTarget(
        onDragEntered: (_) => setState(() => _over = true),
        onDragExited: (_) => setState(() => _over = false),
        onDragDone: (d) {
          setState(() => _over = false);
          _add([for (final f in d.files) f.path]);
        },
        child: Container(
          height: 110,
          decoration: BoxDecoration(
            color: _over ? const Color(0xFFE8EFFF) : const Color(0xFFF8FAFF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _over ? LightLook.blue : const Color(0xFFB9C8EA), width: _over ? 2 : 1.5),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(Elevation.isAdmin ? tr('conv.drop_admin') : tr('conv.drop_any'),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: LightLook.text)),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton(onPressed: _pickPc, child: Text(tr('send.files_pc'))),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: _pickLibrary, child: Text(tr('send.files_library'))),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (_groups.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(tr('conv.no_files'), textAlign: TextAlign.center, style: const TextStyle(color: LightLook.muted)),
        )
      else ...[
        Row(children: [
          Expanded(
            child: Text(tr('conv.groups', {'groups': _groups.length, 'count': _count}),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LightLook.text)),
          ),
          Text(tr('conv.groups_hint'), style: const TextStyle(color: LightLook.muted, fontSize: 12)),
        ]),
        const SizedBox(height: 4),
        for (final g in _groups) _groupRow(g),
      ],
      if (video) ...[
        const SizedBox(height: 10),
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
        Expanded(child: Text(_groups.isEmpty ? '' : tr('conv.groups_note'), style: const TextStyle(color: LightLook.muted, fontSize: 12.5))),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: LightLook.blue, shape: const StadiumBorder()),
          onPressed: _groups.isEmpty ? null : _start,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(tr('conv.start', {'count': _count})),
        ),
      ]),
    ]));
  }

  /// One format's files: how many, → its target (a list of everything it
  /// can become, with what each is for), ×.
  Widget _groupRow(_Group g) {
    final on = identical(g, _sel);
    final choices = FormatTable.choicesFor(g.files.first, g.cat);
    final now = choices.where((c) => c.to.id == g.to.id).firstOrNull;
    final names = g.files.take(2).map(baseNameOf).join('、') + (g.files.length > 2 ? ' …' : '');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _show(g)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFE8EFFF) : const Color(0xFFF8FAFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? LightLook.blue : const Color(0xFFE3E8F2), width: on ? 2 : 1),
          ),
          child: Row(children: [
            SizedBox(
              width: 150,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g.from.label}  ×${g.files.length}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: LightLook.text)),
                Text(names, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: LightLook.muted)),
              ]),
            ),
            const Icon(Icons.arrow_forward_rounded, color: LightLook.blue),
            const SizedBox(width: 10),
            PopupMenuButton<ConvChoice>(
              tooltip: '',
              onSelected: (c) => setState(() {
                g
                  ..cat = c.cat
                  ..from = c.from
                  ..to = c.to;
                _show(g);
              }),
              itemBuilder: (_) => [
                for (final c in choices)
                  PopupMenuItem(
                    value: c,
                    child: SizedBox(
                      width: 460,
                      child: Row(children: [
                        SizedBox(width: 64, child: Text(c.to.label, style: const TextStyle(fontWeight: FontWeight.w800))),
                        if (c.recommended) ...[_tag(tr('conv.recommended'), const Color(0xFFE3F5E9), const Color(0xFF15803D)), const SizedBox(width: 8)],
                        Expanded(child: Text(tr(c.useKey), style: const TextStyle(fontSize: 12.5))),
                        if (_engineTag(c.op, g.files.first) case final t?) ...[const SizedBox(width: 6), t],
                      ]),
                    ),
                  ),
              ],
              child: Container(
                width: 110,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFB9C8EA))),
                child: Row(children: [
                  Expanded(child: Text(g.to.label, style: const TextStyle(fontWeight: FontWeight.w800, color: LightLook.text))),
                  const Icon(Icons.arrow_drop_down_rounded, color: LightLook.muted),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            if (now?.recommended ?? false) ...[_tag(tr('conv.recommended'), const Color(0xFFE3F5E9), const Color(0xFF15803D)), const SizedBox(width: 8)],
            if (_engineTag(g.op, g.files.first) case final t?) ...[t, const SizedBox(width: 8)],
            Expanded(
              child: Text(now == null ? '' : tr(now.useKey),
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Color(0xFF38445A))),
            ),
            IconButton(
              tooltip: tr('conv.remove'),
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() {
                _groups.remove(g);
                if (identical(_sel, g)) _sel = null;
              }),
            ),
          ]),
        ),
      ),
    );
  }

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
          // The wheel's own: the page around does not scroll with it (it
          // used to, going down, so the wheel slid away under the mouse).
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
              GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
                if (ev is PointerScrollEvent) _step(ev.scrollDelta.dy > 0 ? 1 : -1);
              });
            }
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
