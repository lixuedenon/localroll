// apps/desktop/lib/ui/send_paths.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/settings.dart';
import 'app_nav.dart';
import 'send_page.dart';
import 'theme.dart';
import 'lr_dialog.dart';

/// Where to send to device [id]: a PC, a phone with Keepnear open, or — a
/// phone not open now — its pairing (the send waits until it is online).
PeerPc? sendTargetFor(AppServices s, String id) {
  final pc = s.settings.peers[id];
  if (pc != null) return pc;
  final live = s.phoneTarget(id);
  if (live != null) return live;
  final t = s.settings.trusted[id];
  if (t == null) return null;
  return PeerPc(id: id, name: t.name, hosts: const [], port: 0, token: '', pairedMs: t.pairedMs);
}

/// Files and folders (their files, keeping the folder) as things to send.
Future<List<SendFile>> sendFilesOf(List<String> paths) async {
  final out = <SendFile>[];
  for (final p in paths) {
    final type = FileSystemEntity.typeSync(p);
    if (type == FileSystemEntityType.directory) {
      out.addAll(await filesInFolder(p));
    } else if (type == FileSystemEntityType.file) {
      final name = baseNameOf(p);
      final f = SendFile.plain(File(p), name, toLibrary: MediaKind.fromName(name) != MediaKind.other);
      if (f != null) out.add(f);
    }
  }
  return out;
}

/// Sends [paths] to the devices [ids] (offline ones: when they are back).
/// Returns to how many it went.
Future<int> sendPathsTo(BuildContext context, AppServices s, List<String> ids, List<String> paths) async {
  final files = await sendFilesOf(paths);
  if (!context.mounted) return 0;
  if (files.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('send.nothing'))));
    return 0;
  }
  final title = paths.length == 1 ? baseNameOf(paths.first.replaceAll(RegExp(r'[\\/]+$'), '')) : tr('send.n_files', {'count': files.length});
  var n = 0;
  for (final id in ids) {
    final p = sendTargetFor(s, id);
    if (p == null) continue;
    if (s.settings.peers.containsKey(id)) {
      s.sender.add(p, files, title);
      n++;
    } else {
      if (!context.mounted) break;
      if (await queueForPhone(context, s, p, files, title)) n++;
    }
  }
  if (n > 0 && context.mounted) {
    final waiting = ids.where((id) => !(s.sender.isOnline?.call(id) ?? true)).length;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(tr(waiting > 0 ? 'send.sent_to_some_wait' : 'send.sent_to', {'count': n, 'wait': waiting})),
    ));
  }
  return n;
}

/// Explorer's "Send to → Keepnear": choose the devices, then send.
void sendFromExplorer(AppServices s, List<String> paths) {
  AppNav.instance.selectTab(AppNav.devices);
  if (paths.isEmpty) return;
  unawaited(() async {
    // The window comes to the front first.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final ids = await pickDevices(ctx, s, count: paths.length, first: baseNameOf(paths.first));
    if (ids == null || ids.isEmpty || !ctx.mounted) return;
    await sendPathsTo(ctx, s, ids, paths);
  }());
}

/// Which devices to send to (several may be ticked).
Future<List<String>?> pickDevices(BuildContext context, AppServices s, {required int count, required String first}) {
  final ids = {...s.settings.peers.keys, ...s.settings.trusted.keys}.toList()
    ..sort((a, b) {
      final on = (s.isOnline(b) ? 1 : 0) - (s.isOnline(a) ? 1 : 0);
      return on != 0 ? on : s.deviceName(a).toLowerCase().compareTo(s.deviceName(b).toLowerCase());
    });
  final picked = <String>{};
  return showLrDialog<List<String>>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        icon: const Icon(Icons.send_rounded, size: 30),
        title: Text(tr('send.pick_title', {'count': count, 'name': first})),
        content: SizedBox(
          width: 440,
          child: ids.isEmpty
              ? Text(tr('send.no_devices'))
              : ListView(shrinkWrap: true, children: [
                  for (final id in ids)
                    CheckboxListTile(
                      value: picked.contains(id),
                      onChanged: (v) => set(() => v == true ? picked.add(id) : picked.remove(id)),
                      secondary: Icon(
                        s.settings.peers.containsKey(id) ? Icons.computer_rounded : Icons.smartphone_rounded,
                        color: s.isOnline(id) || s.phoneTarget(id) != null ? LrColors.verified : LrColors.muted,
                      ),
                      title: Text(s.deviceName(id)),
                      subtitle: Text(tr(s.isOnline(id) || s.phoneTarget(id) != null ? 'dev.online' : 'send.when_back'),
                          style: const TextStyle(fontSize: 12, color: LrColors.muted)),
                    ),
                ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
          FilledButton(
            onPressed: picked.isEmpty ? null : () => Navigator.pop(c, picked.toList()),
            child: Text(tr('send.to_n', {'count': picked.length})),
          ),
        ],
      ),
    ),
  );
}
