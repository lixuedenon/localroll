// apps/mobile/lib/services/auto_sender.dart
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'desktop_client.dart';
import 'discovery.dart';
import 'mobile_settings.dart';
import 'uploader.dart';

enum AutoState {
  /// Nothing new (or auto-send is off).
  idle,

  /// New photos are waiting, but the PC can't be reached right now.
  waiting,

  /// Sending in the background of the home screen.
  sending,

  /// Just finished a batch.
  done,
}

/// Auto-send: photos/videos taken after auto-send was switched on go to the
/// current PC by themselves — as soon as the app is open and the PC is
/// reachable. Nothing is lost while the PC is off: they simply wait.
class AutoSender extends ChangeNotifier {
  AutoSender(this.settings, this.discovery);

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  AutoState state = AutoState.idle;

  /// New items not yet on the PC.
  int pending = 0;

  /// Items sent in the last batch.
  int lastSent = 0;
  Uploader? uploader;
  bool _busy = false;

  Future<void> check() async {
    if (_busy) return;
    final d = settings.current;
    if (!settings.autoSend || d == null) {
      _set(AutoState.idle, 0);
      return;
    }
    _busy = true;
    try {
      final fresh = await _newAssets(d);
      if (fresh.isEmpty) {
        if (state != AutoState.done) _set(AutoState.idle, 0);
        return;
      }
      DesktopClient client;
      try {
        client = await connectToDesktop(settings, d, discovered: discovery.found);
      } catch (_) {
        _set(AutoState.waiting, fresh.length);
        return;
      }
      final up = Uploader(client: client, settings: settings, desktop: d, assets: fresh);
      uploader = up;
      _set(AutoState.sending, fresh.length);
      try {
        await up.run();
      } finally {
        client.close();
        uploader = null;
      }
      lastSent = up.doneCount + up.skippedCount;
      if (up.failedCount > 0) {
        _set(AutoState.waiting, up.failedCount);
      } else {
        _set(AutoState.done, 0);
      }
    } catch (_) {
      // Photo library not readable right now; try again next time.
    } finally {
      _busy = false;
    }
  }

  /// Hide the "sent" note.
  void dismiss() {
    if (state == AutoState.done) _set(AutoState.idle, 0);
  }

  void _set(AutoState s, int n) {
    state = s;
    pending = n;
    notifyListeners();
  }

  Future<List<AssetEntity>> _newAssets(PairedDesktop d) async {
    final since = DateTime.fromMillisecondsSinceEpoch(settings.autoSendSinceMs);
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
        createTimeCond: DateTimeCond(min: since, max: DateTime.now().add(const Duration(days: 1))),
      ),
    );
    if (paths.isEmpty) return const [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    if (count == 0) return const [];
    final list = await all.getAssetListRange(start: 0, end: min(count, 2000));
    final sent = settings.sentTo(d.id);
    // Oldest first, so the PC receives them in shooting order.
    return list.where((a) => !sent.contains(a.id)).toList().reversed.toList();
  }
}
