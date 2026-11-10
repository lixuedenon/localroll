// apps/desktop/lib/ui/transfer_records.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/network.dart' show revealInExplorer;
import '../services/peers.dart';
import '../services/receive_hub.dart';
import '../services/transfer_log.dart';
import 'app_nav.dart';
import 'format.dart';
import 'send_page.dart' show jobStatus;
import 'send_paths.dart';

enum _Tab { all, now, waiting, received, sent }

/// The top of the Transfers page: what is moving now (pause / cancel), what
/// waits for a device, and the history (open, send again, open a link).
class TransferRecords extends StatefulWidget {
  const TransferRecords({super.key, required this.services});

  final AppServices services;

  @override
  State<TransferRecords> createState() => _TransferRecordsState();
}

class _TransferRecordsState extends State<TransferRecords> {
  _Tab _tab = _Tab.all;
  bool _more = false;
  String _query = '';
  bool _searching = false;

  static const Color _soft = Color(0xFF8EA4BA);
  static const Color _green = Color(0xFF3EE08A);

  AppServices get s => widget.services;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([s.sender, s.hub, s.transferLog]),
        builder: (context, _) {
          final jobs = s.sender.jobs.where((j) => !j.over || j.paused).toList();
          final moving = jobs.where((j) => j.state != SendJobState.held && !j.paused).toList();
          final held = jobs.where((j) => j.state == SendJobState.held || j.paused).toList();
          final incoming = <String, List<TransferProgress>>{};
          for (final t in s.hub.transfers) {
            if (t.state == TransferState.receiving || t.state == TransferState.verifying) (incoming[t.deviceName] ??= []).add(t);
          }
          final q = _query.trim().toLowerCase();
          final records = [
            for (final r in s.transferLog.records)
              if ((_tab == _Tab.all || (_tab == _Tab.received && !r.out) || (_tab == _Tab.sent && r.out)) &&
                  (q.isEmpty ||
                      r.deviceName.toLowerCase().contains(q) ||
                      r.title.toLowerCase().contains(q) ||
                      (r.text ?? '').toLowerCase().contains(q) ||
                      r.paths.any((p) => p.toLowerCase().contains(q))))
                r,
          ];
          final showJobs = _tab == _Tab.all || _tab == _Tab.now || _tab == _Tab.waiting;
          final shownRecords = (_tab == _Tab.now || _tab == _Tab.waiting) ? const <TransferRecord>[] : records.take(_more ? 40 : 5).toList();
          final rows = <Widget>[
            if (showJobs && _tab != _Tab.waiting) ...[
              for (final e in incoming.entries) _incomingRow(e.key, e.value),
              for (final j in moving) _jobRow(j),
            ],
            if (showJobs && _tab != _Tab.now) for (final j in held) _jobRow(j),
            for (final r in shownRecords) _recordRow(r),
          ];
          return Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            decoration: BoxDecoration(
              color: const Color(0x0BFFFFFF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x17FFFFFF)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text(tr('xfer.records'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      _tabChip(_Tab.all, tr('xfer.tab_all')),
                      _tabChip(_Tab.now, tr('xfer.tab_now', {'count': moving.length + incoming.length})),
                      _tabChip(_Tab.waiting, tr('xfer.tab_waiting', {'count': held.length})),
                      _tabChip(_Tab.received, tr('xfer.tab_in')),
                      _tabChip(_Tab.sent, tr('xfer.tab_out')),
                    ]),
                  ),
                ),
                if (_searching)
                  SizedBox(
                    width: 180,
                    height: 34,
                    child: TextField(
                      autofocus: true,
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: tr('xfer.search'),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        suffixIcon: IconButton(
                          iconSize: 16,
                          onPressed: () => setState(() {
                            _searching = false;
                            _query = '';
                          }),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  )
                else
                  IconButton(
                    tooltip: tr('xfer.search'),
                    onPressed: () => setState(() => _searching = true),
                    icon: const Icon(Icons.search_rounded, color: _soft, size: 20),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz_rounded, color: _soft),
                  onSelected: (v) {
                    if (v == 'clear') s.transferLog.clear();
                  },
                  itemBuilder: (_) => [PopupMenuItem(value: 'clear', child: Text(tr('xfer.clear_history')))],
                ),
              ]),
              const SizedBox(height: 4),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(tr(q.isNotEmpty ? 'xfer.none_found' : 'xfer.none_yet'), style: const TextStyle(color: _soft, fontSize: 13)),
                ),
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: Color(0x10FFFFFF)),
                rows[i],
              ],
              if (records.length > 5 && _tab != _Tab.now && _tab != _Tab.waiting)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _more = !_more),
                    child: Text(_more ? tr('xfer.less') : tr('xfer.more', {'count': records.length})),
                  ),
                ),
            ]),
          );
        },
      );

  Widget _tabChip(_Tab t, String label) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => setState(() => _tab = t),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: _tab == t ? const Color(0x262FD3C2) : Colors.transparent,
            ),
            child: Text(label,
                style: TextStyle(
                  fontSize: 13,
                  color: _tab == t ? const Color(0xFF2FD3C2) : _soft,
                  fontWeight: _tab == t ? FontWeight.w700 : FontWeight.w400,
                )),
          ),
        ),
      );

  Widget _line({
    required bool out,
    required String title,
    required String sub,
    Widget? middle,
    List<Widget> actions = const [],
    bool dim = false,
    VoidCallback? onRemove,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (out ? const Color(0xFF2B8CFF) : _green).withValues(alpha: dim ? 0.1 : 0.18),
            ),
            child: Icon(out ? Icons.north_rounded : Icons.south_rounded, size: 16, color: out ? const Color(0xFF5AA8FF) : _green),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 260,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _soft, fontSize: 12.5)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(child: middle ?? const SizedBox.shrink()),
          for (final a in actions) Padding(padding: const EdgeInsets.only(left: 6), child: a),
          if (onRemove != null)
            IconButton(
              tooltip: tr('xfer.remove'),
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, color: _soft),
            ),
        ]),
      );

  Widget _small(String label, VoidCallback onTap, {IconData? icon, bool strong = false}) => Material(
        color: strong ? const Color(0xFF1F6FD8) : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 4)],
              Text(label, style: const TextStyle(fontSize: 12.5, color: Colors.white)),
            ]),
          ),
        ),
      );

  Widget _bar(double f) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          width: 180,
          height: 6,
          child: LinearProgressIndicator(
            value: f,
            backgroundColor: Colors.white.withValues(alpha: 0.1),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF2FD3C2)),
          ),
        ),
      );

  Widget _incomingRow(String name, List<TransferProgress> list) {
    final total = list.fold<int>(0, (n, t) => n + t.total);
    final got = list.fold<int>(0, (n, t) => n + t.received);
    final f = total > 0 ? (got / total).clamp(0.0, 1.0) : null;
    return _line(
      out: false,
      title: tr('xfer.from', {'name': name}),
      sub: tr('xfer.receiving_n', {'count': list.length}),
      middle: Row(children: [
        if (f != null) _bar(f),
        const SizedBox(width: 10),
        Flexible(child: Text(f == null ? '…' : '${(f * 100).round()}%', style: const TextStyle(color: _soft, fontSize: 13))),
      ]),
    );
  }

  Widget _jobRow(SendJob j) {
    final paused = j.paused && j.over;
    final waiting = j.state == SendJobState.held;
    final left = j.speed > 0 && j.totalBytes > 0 ? (j.totalBytes - j.sentBytes) / j.speed : null;
    return _line(
      out: true,
      dim: waiting || paused,
      title: tr('xfer.to', {'name': j.peer.name}),
      sub: '${j.title} · ${formatBytes(j.totalBytes)}',
      middle: paused
          ? Text(tr('xfer.paused', {'pct': (j.fraction * 100).round()}), style: const TextStyle(color: _soft, fontSize: 13))
          : waiting
              ? Text(tr('send.held', {'name': j.peer.name}), style: const TextStyle(color: _soft, fontSize: 13))
              : Row(children: [
                  _bar(j.fraction),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      j.state == SendJobState.sending
                          ? [
                              '${(j.fraction * 100).round()}%',
                              if (j.speed > 0) '${formatBytes(j.speed.round())}/s',
                              if (left != null) tr('xfer.left', {'time': _dur(left)}),
                            ].join(' · ')
                          : jobStatus(j).$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _soft, fontSize: 13),
                    ),
                  ),
                ]),
      actions: [
        if (paused) _small(tr('xfer.resume'), () => s.sender.resume(j), icon: Icons.play_arrow_rounded, strong: true),
        if (!paused && !waiting && j.active) _small(tr('xfer.pause'), () => s.sender.pause(j), icon: Icons.pause_rounded),
        _small(tr('common.cancel'), () {
          if (paused) {
            s.sender.drop(j);
          } else {
            s.sender.cancel(j);
          }
        }, icon: Icons.close_rounded),
      ],
    );
  }

  String _dur(double secs) {
    final s = secs.round();
    if (s < 60) return tr('xfer.secs', {'n': math.max(1, s)});
    if (s < 3600) return tr('xfer.mins', {'n': (s / 60).ceil()});
    return tr('xfer.hours', {'n': (s / 3600).toStringAsFixed(1)});
  }

  Widget _recordRow(TransferRecord r) {
    final when = formatWhen(DateTime.fromMillisecondsSinceEpoch(r.lastMs));
    final ok = r.result == 'ok';
    final text = r.text;
    String sub;
    if (text != null) {
      sub = tr('xfer.text', {'text': text.replaceAll('\n', ' ')});
    } else if (r.out) {
      sub = '${r.title} · ${tr('send.n_files', {'count': r.files})} · ${formatBytes(r.bytes)}';
    } else {
      final media = r.media, other = r.done - r.media;
      sub = [
        if (media > 0) tr('xfer.n_media', {'count': media}),
        if (other > 0) tr('xfer.n_other', {'count': other}),
        if (r.already > 0) tr('xfer.n_already', {'count': r.already}),
        if (r.bytes > 0) formatBytes(r.bytes),
      ].join(' · ');
      if (sub.isEmpty) sub = tr('xfer.nothing_new');
    }
    final link = text == null ? null : linkIn(text);
    final code = text == null || link != null ? null : codeIn(text);
    final status = switch (r.result) {
      'ok' => '✓ ${tr('xfer.done')} · $when',
      'cancelled' => '${tr('xfer.cancelled')} · $when',
      'partial' => '${tr('xfer.partial', {'done': r.done, 'count': r.files})} · $when',
      _ => '${tr('xfer.failed')} · $when',
    };
    return _line(
      out: r.out,
      dim: !ok,
      title: tr(r.out ? 'xfer.to' : 'xfer.from', {'name': r.deviceName.isEmpty ? '—' : r.deviceName}),
      sub: sub,
      middle: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ok ? _green : _soft, fontSize: 13)),
      actions: [
        if (link != null) _small(tr('xfer.open_link'), () => _openLink(link), icon: Icons.link_rounded, strong: true),
        if (code != null) _small(tr('xfer.copy_code', {'code': code}), () => _copy(code), icon: Icons.pin_rounded, strong: true),
        if (text != null) _small(tr('xfer.copy'), () => _copy(text)),
        if (!r.out && text == null && r.media > 0) _small(tr('xfer.see_library'), AppNav.instance.openLibraryRecent),
        if (text == null && r.paths.isNotEmpty && (r.out || r.media < r.done))
          _small(tr('xfer.show_folder'), () => unawaited(revealInExplorer(r.paths.firstWhere((p) => File(p).existsSync(), orElse: () => r.paths.first)))),
        if (r.out && text == null && r.paths.isNotEmpty) _small(tr('xfer.again'), () => _again(r), icon: Icons.refresh_rounded),
      ],
      onRemove: () => s.transferLog.remove(r),
    );
  }

  Future<void> _again(TransferRecord r) async {
    final there = [for (final p in r.paths) if (File(p).existsSync()) p];
    if (there.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('xfer.files_gone'))));
      return;
    }
    await sendPathsTo(context, s, [r.deviceId], there);
  }

  void _copy(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('xfer.copied')), duration: const Duration(seconds: 2)));
  }

  void _openLink(String url) {
    if (!Platform.isWindows) return;
    unawaited(Process.run('rundll32', ['url.dll,FileProtocolHandler', url]));
  }
}
