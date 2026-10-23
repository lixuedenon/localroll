// apps/mobile/lib/services/file_sender.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import 'desktop_client.dart';
import 'discovery.dart';
import 'mobile_settings.dart';

enum FileSendState { connecting, sending, done, failed }

/// Sends ordinary files (a scan, a PDF, anything picked in Files) to a PC
/// or a nearby phone: the same protocol as photos — resumable chunks and a
/// SHA-256 check. A PC sorts them by kind (documents into "Documents",
/// photos/videos into the library, the rest into "Other files"); a phone
/// asks its owner first, then keeps them in Files / Download.
class FileSender extends ChangeNotifier {
  FileSender({
    required this.settings,
    required this.discovery,
    required this.files,
    this.desktop,
    this.phone,
  }) : assert(desktop != null || phone != null);

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final List<File> files;
  final PairedDesktop? desktop;
  final NearbyPhone? phone;

  String get targetName => phone?.name ?? desktop!.name;

  FileSendState state = FileSendState.connecting;
  int done = 0;
  int skipped = 0;
  int sentBytes = 0;
  int totalBytes = 0;
  String? current;

  /// Why it stopped (readable), and the other side's own words if it
  /// declined with a reason.
  String? error;
  String? reason;
  bool _cancel = false;

  void cancel() {
    _cancel = true;
    notifyListeners();
  }

  static String nameOf(File f) => nameOfPath(f.path);
  static String nameOfPath(String path) => path.split(Platform.pathSeparator).last.split('/').last;

  Future<void> run() async {
    DesktopClient? c;
    try {
      final offers = <FileOffer>[];
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final st = await f.stat();
        final name = nameOf(f);
        totalBytes += st.size;
        final mtime = st.modified.millisecondsSinceEpoch;
        offers.add(FileOffer(
          id: 'f$i',
          assetId: 'file:${shortKey('${f.path}|${st.size}|$mtime')}',
          name: name,
          kind: MediaKind.fromName(name),
          createdMs: mtime,
          modifiedMs: mtime,
          size: st.size,
          // Family group: like photos, "only me" unless shared.
          private: !settings.shareWithFamily,
          target: LrProtocol.targetFiles,
          relPath: name,
        ));
      }
      notifyListeners();
      final p = phone;
      c = p != null
          ? await connectToPhone(settings, p)
          : await connectToDesktop(settings, desktop!, discovered: discovery.found);
      if (c == null) throw Exception(tr('send.phone_gone', {'name': targetName}));
      state = FileSendState.sending;
      notifyListeners();
      final session = await c.createSession(SessionRequest(
        files: offers,
        owner: p == null ? settings.ownerName : null,
        from: p == null ? null : settings.deviceInfo,
        batch: p == null ? null : offers.length,
        transfer: p == null ? null : randomTransferId(),
      ));
      for (var i = 0; i < files.length; i++) {
        if (_cancel) break;
        final offer = offers[i];
        final r = session.results[offer.id];
        if (r == null || r.status == OfferStatus.duplicate) {
          skipped++;
          sentBytes += offer.size ?? 0;
          notifyListeners();
          continue;
        }
        current = offer.name;
        notifyListeners();
        await _sendOne(c, session.sessionId, offer, files[i], r.offset);
        done++;
        notifyListeners();
      }
      state = FileSendState.done;
      DiagLog.log('send', 'files to $targetName: $done sent, $skipped already there');
    } catch (e) {
      state = FileSendState.failed;
      if (e is LrHttpException) {
        error = e.message;
        final r = (e.body['reason'] as String?)?.trim();
        reason = (r == null || r.isEmpty) ? null : r;
      } else {
        final s = e.toString();
        error = s.startsWith('Exception: ') ? s.substring(11) : s;
      }
      DiagLog.log('send', 'files to $targetName failed: $error');
    } finally {
      c?.close();
      current = null;
      notifyListeners();
    }
  }

  Future<void> _sendOne(DesktopClient c, String sid, FileOffer offer, File f, int offset) async {
    final size = offer.size ?? await f.length();
    final before = sentBytes;
    var pos = offset;
    sentBytes = before + pos;
    final raf = await f.open();
    try {
      while (pos < size) {
        if (_cancel) throw Exception(tr('transfer.stopped_user'));
        final n = min(LrProtocol.chunkSize, size - pos);
        await raf.setPosition(pos);
        final chunk = await raf.read(n);
        try {
          pos = await c.putChunk(sid, offer.id, pos, size, chunk);
        } on LrHttpException catch (e) {
          if (e.status != 409) rethrow;
          pos = (e.body['offset'] as num?)?.toInt() ?? await c.status(sid, offer.id);
        }
        sentBytes = before + pos;
        notifyListeners();
      }
    } finally {
      await raf.close();
    }
    final res = await c.complete(sid, offer.id, CompleteRequest(size: size, sha256: await sha256OfFile(f)));
    if (!res.saved) throw Exception(serverErrorText(res.error ?? 'not_saved'));
    sentBytes = before + size;
  }
}
