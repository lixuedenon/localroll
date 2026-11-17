// apps/desktop/lib/ui/screen/screen_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/win_dialogs.dart';
import '../library_picker.dart';
import '../player/player_entry.dart';
import '../player/player_page.dart';
import '../format.dart';
import '../light_dialog.dart';
import '../light_look.dart';
import '../../services/network.dart';
import '../theme.dart';
import 'pen_bar.dart';
import 'recordings_view.dart';
import 'screen_record.dart';
import '../lr_dialog.dart';

/// "Record screen" on the left: what to record (the whole screen, a
/// window, an area, or explaining a video in the player at its own
/// quality), and the recordings made so far.
class ScreenPage extends StatefulWidget {
  const ScreenPage({super.key, required this.services});

  final AppServices services;

  @override
  State<ScreenPage> createState() => _ScreenPageState();
}

class _ScreenPageState extends State<ScreenPage> {
  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    PenSession.instance.services = s;
    ScreenRecorder.instance.addListener(_onRecorder);
  }

  @override
  void dispose() {
    ScreenRecorder.instance.removeListener(_onRecorder);
    super.dispose();
  }

  void _onRecorder() {
    if (mounted) setState(() {});
  }

  Future<void> _record(ScreenMode mode) async {
    final su = await showScreenSetup(context, s, initial: mode);
    if (su != null) await ScreenRecorder.instance.begin(su);
  }

  /// Explain a video / photo: choose it, the player opens and records.
  Future<void> _explain() async {
    final recent = [for (final r in s.player.recent) if (File(r.path).existsSync()) r].take(8).toList();
    final path = await showLrDialog<Object>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('screen.explain_pick')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('screen.explain_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 12),
            if (recent.isNotEmpty) ...[
              Text(tr('player.recent'), style: const TextStyle(color: LrColors.muted)),
              const SizedBox(height: 4),
              for (final r in recent)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(r.video ? Icons.movie_rounded : Icons.image_rounded),
                  title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, r.path),
                ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await pickFromLibrary(ctx, s);
              if (picked != null && picked.isNotEmpty && ctx.mounted) Navigator.pop(ctx, picked);
            },
            icon: const Icon(Icons.photo_library_rounded, size: 18),
            label: Text(tr('pick.from_library')),
          ),
          FilledButton.icon(
            onPressed: () async {
              final picked = await WinDialogs.pickFiles(
                title: tr('player.open_files'),
                typeLabel: tr('player.file_types'),
                extensions: [...playerImageExtensions, ...playerVideoExtensions],
              );
              if (picked.isNotEmpty && ctx.mounted) Navigator.pop(ctx, picked.first);
            },
            icon: const Icon(Icons.file_open_rounded, size: 18),
            label: Text(tr('player.open_files')),
          ),
        ],
      ),
    );
    if (path == null || !mounted) return;
    await openInPlayer(context, s, path is List<String> ? path : [path as String], record: true);
  }

  /// One card: a striped coloured head, a badge, the name and a line.
  /// All the same size (the full text, when longer, on hover).
  Widget _choice(IconData icon, String title, String tip, VoidCallback onTap, List<Color> colors,
          {String? more, String? tag, String? go, double width = 230}) =>
      SizedBox(
        width: width,
        height: 214,
        child: Tooltip(
          // A few lines, not one long one.
          richMessage: WidgetSpan(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(more ?? tip, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.45)),
            ),
          ),
          waitDuration: const Duration(milliseconds: 500),
          child: LightCard(
            padding: EdgeInsets.zero,
            border: tag != null ? colors.first.withValues(alpha: 0.6) : null,
            onTap: ScreenRecorder.instance.recording ? null : onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(clipBehavior: Clip.none, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color.lerp(colors.first, Colors.white, 0.25)!, colors.last]),
                    ),
                    child: const CustomPaint(painter: _Stripes(Color(0x2EFFFFFF))),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 32, 14, 12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: LightLook.text)),
                        const SizedBox(height: 6),
                        Expanded(
                          child: Text(tip,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: LightLook.muted, fontSize: 12.5, height: 1.45)),
                        ),
                        Text('${go ?? tr('screen.go_start')} →',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: colors.last)),
                      ]),
                    ),
                  ),
                ]),
                Positioned(
                  left: 14,
                  top: 34,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                      boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 5))],
                    ),
                    child: Icon(icon, color: Colors.white, size: 24),
                  ),
                ),
                if (tag != null)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                      child: Text(tag, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: colors.last)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      );

  /// The keys line: "Ctrl+Shift+R" drawn as keys, on a lightly striped strip.
  Widget _keys() {
    final text = tr('screen.keys_tip');
    final spans = <InlineSpan>[];
    var at = 0;
    Widget key(String k) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: const Border(
              top: BorderSide(color: Color(0xFFD8E0EF)),
              left: BorderSide(color: Color(0xFFD8E0EF)),
              right: BorderSide(color: Color(0xFFD8E0EF)),
              bottom: BorderSide(color: Color(0xFFD8E0EF), width: 2),
            ),
          ),
          child: Text(k, style: const TextStyle(fontSize: 12, color: LightLook.text)),
        );
    for (final m in RegExp(r'Ctrl\+Shift\+[A-Z]').allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final parts = m.group(0)!.split('+');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) spans.add(const TextSpan(text: '+'));
        spans.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: key(parts[i])));
      }
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        painter: const _Stripes(Color(0xFFEFF2FA), back: Color(0xFFF6F8FD), gap: 10, width: 10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text.rich(TextSpan(children: spans), style: const TextStyle(color: LightLook.muted, fontSize: 12.5, height: 1.9)),
        ),
      ),
    );
  }

  /// The band at the top (name, what it does) and how many recordings.
  Widget _hero() => SizedBox(
        height: 124,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFFFFE9EC), Color(0xFFFFD6DE), Color(0xFFD9E4FF)], stops: [0, 0.45, 1]),
                ),
                child: Stack(children: [
                  const Positioned.fill(child: CustomPaint(painter: LightBands())),
                  Row(children: [
                    const SizedBox(width: 20),
                    const _HeroArt(),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('nav.screen'),
                            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: LightLook.text, letterSpacing: -0.5)),
                        const SizedBox(height: 6),
                        Text(tr('screen.page_hint'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, color: Color(0xFF7A2E45), fontWeight: FontWeight.w500)),
                      ]),
                    ),
                    const SizedBox(width: 18),
                  ]),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 340,
            child: Container(
              decoration: LightLook.card(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: ListenableBuilder(
                listenable: s.recordings,
                builder: (context, _) {
                  final items = s.recordings.items;
                  var bytes = 0;
                  for (final r in items) {
                    try {
                      bytes += File(r.path).lengthSync();
                    } catch (_) {}
                  }
                  return Row(children: [
                    const LightBadge(icon: Icons.videocam_rounded, colors: [Color(0xFFFF6B7D), Color(0xFFE5484D)], size: 58),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('recs.title'), style: const TextStyle(fontSize: 13, color: LightLook.muted)),
                        const SizedBox(height: 2),
                        Text(tr('home.items_size', {'count': items.length, 'size': formatBytes(bytes)}),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: LightLook.text)),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 30,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12), visualDensity: VisualDensity.compact),
                            onPressed: () => unawaited(revealInExplorer(s.recordings.root)),
                            icon: const Icon(Icons.folder_open_rounded, size: 16),
                            label: Text(tr('common.show_in_folder'), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ]),
                    ),
                  ]);
                },
              ),
            ),
          ),
        ]),
      );

  Widget _section(String title, String? hint, List<Widget> children) => Container(
        decoration: LightLook.card(),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: LightLook.text)),
            if (hint != null) ...[
              const SizedBox(width: 10),
              Flexible(child: Text(hint, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: LightLook.muted))),
            ],
          ]),
          const SizedBox(height: 14),
          ...children,
        ]),
      );

  @override
  Widget build(BuildContext context) => Theme(
        data: LightLook.theme(Theme.of(context)),
        child: Scaffold(
          backgroundColor: LightLook.page,
          body: DecoratedBox(
            decoration: LightLook.wash,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                _hero(),
                const SizedBox(height: 14),
                _section(tr('screen.start_title'), tr('screen.start_hint'), [
                  LayoutBuilder(builder: (context, box) {
                    // Five across when there is room, else as many as fit.
                    final across = ((box.maxWidth + 14) / (200 + 14)).floor().clamp(1, 5);
                    final w = (box.maxWidth - 14 * (across - 1)) / across;
                    return Wrap(spacing: 14, runSpacing: 14, children: [
                      _choice(Icons.desktop_windows_rounded, tr('screen.mode_screen'), tr('screen.choice_screen'), () => _record(ScreenMode.screen),
                          const [Color(0xFFFF6B7D), Color(0xFFD93A48)], width: w),
                      _choice(Icons.web_asset_rounded, tr('screen.mode_window'), tr('screen.choice_window'), () => _record(ScreenMode.window),
                          const [Color(0xFF5B8CFF), Color(0xFF2F5BEA)], width: w),
                      _choice(Icons.crop_rounded, tr('screen.mode_area'), tr('screen.choice_area'), () => _record(ScreenMode.area),
                          const [Color(0xFFFFB547), Color(0xFFD97A00)], width: w),
                      _choice(Icons.record_voice_over_rounded, tr('screen.mode_explain'), tr('screen.choice_explain_short'), _explain,
                          const [Color(0xFF3CC985), Color(0xFF0E8A50)],
                          more: tr('screen.choice_explain'), tag: tr('screen.recommend'), go: tr('screen.go_pick'), width: w),
                      _choice(Icons.draw_rounded, tr('pen.only'), tr('pen.only_tip'), () => unawaited(PenSession.instance.start()),
                          const [Color(0xFFA084FF), Color(0xFF6A47E6)], go: tr('screen.go_pen'), width: w),
                    ]);
                  }),
                  const SizedBox(height: 14),
                  _keys(),
                ]),
                const SizedBox(height: 14),
                _section(tr('recs.title'), null, [RecordingsView(services: s, light: true)]),
              ],
            ),
          ),
        ),
      );
}

/// Thin diagonal stripes ([back] under them, if given).
class _Stripes extends CustomPainter {
  const _Stripes(this.color, {this.back, this.width = 6, this.gap = 10});

  final Color color;
  final Color? back;
  final double width, gap;

  @override
  void paint(Canvas canvas, Size size) {
    if (back != null) canvas.drawRect(Offset.zero & size, Paint()..color = back!);
    final p = Paint()
      ..color = color
      ..strokeWidth = width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final step = width + gap;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Stripes old) => old.color != color || old.back != back;
}

/// A screen with a red record dot and a pen.
class _HeroArt extends StatelessWidget {
  const _HeroArt();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 96,
        height: 92,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 8,
            top: 10,
            child: Container(
              width: 74,
              height: 56,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(colors: [Color(0xFF6F96FF), Color(0xFF2F5BEA)]),
                boxShadow: const [BoxShadow(color: Color(0x592F5BEA), blurRadius: 12, offset: Offset(0, 5))],
              ),
              child: Container(decoration: BoxDecoration(color: const Color(0xFFDCE6FF), borderRadius: BorderRadius.circular(7))),
            ),
          ),
          Positioned(left: 37, top: 66, child: Container(width: 16, height: 8, color: const Color(0xFF2F5BEA))),
          Positioned(
            left: 27,
            top: 73,
            child: Container(width: 36, height: 6, decoration: BoxDecoration(color: const Color(0xFF2F5BEA), borderRadius: BorderRadius.circular(3))),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFF4D63),
                boxShadow: [BoxShadow(color: Color(0x66FF4D63), blurRadius: 10)],
              ),
              child: Center(child: Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
            ),
          ),
          Positioned(
            left: 0,
            top: 50,
            child: Transform.rotate(
              angle: -0.2,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: const LinearGradient(colors: [Color(0xFFFFC56B), Color(0xFFFF8A3D)]),
                ),
                child: const Icon(Icons.edit_rounded, color: Colors.white, size: 16),
              ),
            ),
          ),
        ]),
      );
}
