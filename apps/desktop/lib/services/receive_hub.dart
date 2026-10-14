// apps/desktop/lib/services/receive_hub.dart
import 'package:flutter/foundation.dart';

enum TransferState {
  receiving,
  verifying,
  saved,
  failed,

  /// Offered again but already here: not saved twice.
  alreadyHad,
}

class TransferProgress {
  TransferProgress({
    required this.key,
    required this.deviceName,
    required this.fileName,
    required this.total,
  });

  final String key;
  final String deviceName;
  final String fileName;

  /// Total size, or 0 while unknown.
  int total;
  int received = 0;
  TransferState state = TransferState.receiving;
  String? error;
  DateTime updated = DateTime.now();

  /// Where the file was saved (for "Show in folder").
  String? savedPath;

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// Live view of incoming transfers for the "接收" page.
class ReceiveHub extends ChangeNotifier {
  final Map<String, TransferProgress> _byKey = {};
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  List<TransferProgress> get transfers {
    final list = _byKey.values.toList()..sort((a, b) => b.updated.compareTo(a.updated));
    return list;
  }

  int get savedCount => _byKey.values.where((t) => t.state == TransferState.saved).length;

  TransferProgress track(String key, String deviceName, String fileName, int total) {
    final t = _byKey.putIfAbsent(
      key,
      () => TransferProgress(key: key, deviceName: deviceName, fileName: fileName, total: total),
    );
    if (total > 0) t.total = total;
    t.state = TransferState.receiving;
    t.error = null;
    t.updated = DateTime.now();
    _notify(force: true);
    return t;
  }

  /// Offered, but this PC already has it (nothing is transferred).
  void alreadyHad(String key, String deviceName, String fileName, int total) {
    final t = _byKey.putIfAbsent(
      key,
      () => TransferProgress(key: key, deviceName: deviceName, fileName: fileName, total: total),
    );
    t
      ..state = TransferState.alreadyHad
      ..received = t.total
      ..updated = DateTime.now();
    _notify(force: true);
  }

  void progress(TransferProgress t, int received) {
    t.received = received;
    t.updated = DateTime.now();
    _notify();
  }

  void setState(TransferProgress t, TransferState state, {String? error}) {
    t.state = state;
    t.error = error;
    t.updated = DateTime.now();
    _notify(force: true);
  }

  /// Texts sent from other devices, newest last (shown in a text window).
  final List<ReceivedText> texts = [];

  void textReceived(String from, String text) {
    texts.add(ReceivedText(from, text, DateTime.now()));
    if (texts.length > 500) texts.removeAt(0);
    _notify(force: true);
  }

  /// Ordinary files from other PCs saved this run (newest last).
  final List<String> savedFiles = [];

  void fileSaved(String path) {
    savedFiles.add(path);
    if (savedFiles.length > 200) savedFiles.removeAt(0);
    _notify(force: true);
  }

  void clearFinished() {
    _byKey.removeWhere((_, t) =>
        t.state == TransferState.saved || t.state == TransferState.failed || t.state == TransferState.alreadyHad);
    _notify(force: true);
  }

  /// Progress updates arrive per network packet; repaint at most ~10x/s.
  void _notify({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds > 100) {
      _lastNotify = now;
      notifyListeners();
    }
  }
}

class ReceivedText {
  ReceivedText(this.from, this.text, this.time);

  final String from;
  final String text;
  final DateTime time;
}
