// apps/desktop/lib/ui/transfer_float.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/receive_hub.dart';
import 'app_nav.dart';
import 'format.dart';
import 'light_look.dart';
import 'transfers_panel.dart';

/// While something is sent or received: a card at the bottom right with how
/// far it is (collapsible to a small bar), on top of whatever page is open;
/// the taskbar button shows the progress too. "Done" for a few seconds, then
/// it goes.
class TransferFloat extends StatefulWidget {
  const TransferFloat({super.key, required this.services});

  final AppServices services;

  @override
  State<TransferFloat> createState() => _TransferFloatState();
}

/// One line of the card: a send job, or what one device is sending here.
class _Row {
  _Row({required this.title, required this.done, required this.total, required this.fraction, this.job, this.speed = 0, this.outgoing = true});

  final String title;
  final int done;
  final int total;
  final double fraction;
  final SendJob? job;
  final double speed;
  final bool outgoing;
}

class _TransferFloatState extends State<TransferFloat> {
  bool _small = false;
  bool _wasActive = false;
  DateTime? _doneAt;
  Timer? _hide;
  double _lastBar = -2;

  AppServices get s => widget.services;

  @override
  void dispose() {
    _hide?.cancel();
    unawaited(_taskbar(-1));
    super.dispose();
  }

  Future<void> _taskbar(double v) async {
    // Only when it changes by a percent or more (the taskbar is a system call).
    if ((v - _lastBar).abs() < 0.01) return;
    _lastBar = v;
    try {
      await windowManager.setProgressBar(v);
    } catch (_) {}
  }

  List<_Row> _rows() {
    final rows = <_Row>[
      for (final j in s.sender.jobs)
        if (j.active || j.state == SendJobState.waiting)
          _Row(
            title: tr('float.to', {'name': j.peer.name, 'what': j.title}),
            done: j.processed,
            total: j.files.length,
            fraction: j.fraction.toDouble(),
            job: j,
            speed: j.speed,
          ),
    ];
    // Incoming: one line per device.
    final byDevice = <String, List<TransferProgress>>{};
    for (final t in s.hub.transfers) {
      if (t.state == TransferState.receiving || t.state == TransferState.verifying) {
        (byDevice[t.deviceName] ??= []).add(t);
      }
    }
    byDevice.forEach((name, list) {
      final total = list.fold<int>(0, (a, t) => a + t.total);
      final got = list.fold<int>(0, (a, t) => a + t.received);
      rows.add(_Row(
        title: tr('float.from', {'name': name, 'count': list.length}),
        done: got,
        total: total,
        fraction: total > 0 ? (got / total).clamp(0.0, 1.0) : 0,
        outgoing: false,
      ));
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([s.hub, s.sender, AppNav.instance.fullscreen]),
        builder: (context, _) {
          final rows = _rows();
          final active = rows.isNotEmpty;
          if (active) {
            _wasActive = true;
            _doneAt = null;
            _hide?.cancel();
            final all = rows.fold<double>(0, (a, r) => a + r.fraction) / rows.length;
            unawaited(_taskbar(all));
          } else if (_wasActive) {
            // Just finished: "Done" for 5 seconds.
            _wasActive = false;
            _doneAt = DateTime.now();
            unawaited(_taskbar(-1));
            _hide = Timer(const Duration(seconds: 5), () {
              if (mounted) setState(() => _doneAt = null);
            });
          }
          if (AppNav.instance.fullscreen.value || (!active && _doneAt == null)) return const SizedBox.shrink();
          return Positioned(
            right: 18,
            bottom: 18,
            child: Material(
              type: MaterialType.transparency,
              child: Theme(
                data: LightLook.theme(Theme.of(context)),
                child: !active ? _done() : (_small ? _pill(rows) : _card(rows)),
              ),
            ),
          );
        },
      );

  Widget _done() => _box(
        width: 260,
        child: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('float.done'), style: const TextStyle(fontWeight: FontWeight.w700, color: LightLook.text))),
        ]),
      );

  Widget _pill(List<_Row> rows) {
    final all = rows.fold<double>(0, (a, r) => a + r.fraction) / rows.length;
    return GestureDetector(
      onTap: () => setState(() => _small = false),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2433),
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x401F3B70), blurRadius: 18, offset: Offset(0, 6))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.swap_vert_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(rows.length == 1 ? rows.first.title : tr('float.n_going', {'count': rows.length}),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 64,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: all, minHeight: 6, backgroundColor: const Color(0xFF3A475D), color: const Color(0xFF4F9BFF)),
              ),
            ),
            const SizedBox(width: 8),
            Text('${(all * 100).round()}%', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      ),
    );
  }

  Widget _card(List<_Row> rows) => _box(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.swap_vert_rounded, color: LightLook.blue, size: 20),
            const SizedBox(width: 6),
            Text(tr('float.title', {'count': rows.length}), style: const TextStyle(fontWeight: FontWeight.w700, color: LightLook.text)),
            const Spacer(),
            TextButton(onPressed: () => setState(() => _small = true), child: Text(tr('float.collapse'))),
            TextButton(
              onPressed: () {
                final ctx = AppNav.instance.navigatorKey.currentContext;
                if (ctx != null) unawaited(showTransfers(ctx, s));
              },
              child: Text(tr('float.all')),
            ),
          ]),
          for (final r in rows.take(4)) _line(r),
          if (rows.length > 4)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('float.more', {'count': rows.length - 4}), style: const TextStyle(color: LightLook.muted, fontSize: 12)),
            ),
        ]),
      );

  Widget _line(_Row r) {
    final j = r.job;
    final left = r.outgoing
        ? '${r.done} / ${r.total} · ${formatBytes(j?.sentBytes ?? 0)} / ${formatBytes(j?.totalBytes ?? 0)}'
        : '${formatBytes(r.done)} / ${formatBytes(r.total)}';
    String right = '';
    if (j != null && r.speed > 0) {
      final rest = (j.totalBytes - j.sentBytes) / r.speed;
      right = '${formatBytes(r.speed.round())}/s · ${tr('float.left', {'time': _time(rest)})}';
    } else if (j != null && j.state == SendJobState.waiting) {
      right = tr('float.waiting');
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(r.outgoing ? Icons.north_east_rounded : Icons.south_west_rounded, size: 15, color: LightLook.muted),
          const SizedBox(width: 6),
          Expanded(child: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: LightLook.text))),
          if (j != null) ...[
            InkWell(
              onTap: () => s.sender.pause(j),
              child: Padding(padding: const EdgeInsets.all(3), child: Text(tr('float.pause'), style: const TextStyle(fontSize: 12, color: LightLook.blue))),
            ),
            InkWell(
              onTap: () => s.sender.cancel(j),
              child: Padding(padding: const EdgeInsets.all(3), child: Text(tr('common.cancel'), style: const TextStyle(fontSize: 12, color: LightLook.muted))),
            ),
          ],
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(value: r.fraction, minHeight: 7, backgroundColor: const Color(0xFFE8EEF8), color: LightLook.blue),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text(left, style: const TextStyle(fontSize: 11.5, color: LightLook.muted))),
          Text(right, style: const TextStyle(fontSize: 11.5, color: LightLook.muted)),
        ]),
      ]),
    );
  }

  static String _time(double secs) {
    if (secs.isNaN || secs.isInfinite) return '—';
    final s = secs.round();
    if (s < 60) return tr('float.secs', {'n': s});
    if (s < 3600) return tr('float.mins', {'n': (s / 60).ceil()});
    return tr('float.hours', {'n': (s / 3600).toStringAsFixed(1)});
  }

  Widget _box({required double width, required Widget child}) => Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE3E8F2)),
          boxShadow: const [BoxShadow(color: Color(0x401F3B70), blurRadius: 30, offset: Offset(0, 10))],
        ),
        child: child,
      );
}
