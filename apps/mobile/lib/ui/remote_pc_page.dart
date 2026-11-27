// apps/mobile/lib/ui/remote_pc_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/media_saver.dart';
import '../services/mobile_settings.dart';
import '../services/remote_pc.dart';
import 'open_file.dart';
import 'theme.dart';

/// The PC's own pages on this phone ("Other files on this PC"): the PC
/// makes them and does the work, this phone shows them. First this
/// phone's owner is checked (face / fingerprint / passcode, once a day),
/// then the PC is asked once (on the PC).
class RemotePcPage extends StatefulWidget {
  const RemotePcPage({super.key, required this.settings, required this.discovery, required this.desktop});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;

  @override
  State<RemotePcPage> createState() => _RemotePcPageState();
}

enum _Phase { checking, connecting, asking, ready, refused, stopped, plain, offline, locked }

class _RemotePcPageState extends State<RemotePcPage> {
  late final RemotePc pc = RemotePc(settings: widget.settings, discovery: widget.discovery, desktop: widget.desktop);
  _Phase _phase = _Phase.checking;
  WebViewController? _web;
  Timer? _poll;
  String? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    pc.close();
    super.dispose();
  }

  /// Face / fingerprint / passcode, at most once a day.
  Future<bool> _owner() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (prefs.getString('remoteAuthDay') == today) return true;
    final auth = LocalAuthentication();
    try {
      if (!await auth.isDeviceSupported()) return true; // no lock set up on this phone
      final ok = await auth.authenticate(localizedReason: tr('rpc.auth_reason'), options: const AuthenticationOptions(stickyAuth: true));
      if (ok) await prefs.setString('remoteAuthDay', today);
      return ok;
    } catch (e) {
      DiagLog.log('remote', 'owner check failed: $e');
      return false;
    }
  }

  Future<void> _start() async {
    setState(() => _phase = _Phase.checking);
    if (!await _owner()) {
      if (mounted) setState(() => _phase = _Phase.locked);
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.connecting);
    await _knock();
  }

  Future<void> _knock() async {
    final s = await pc.hello();
    if (!mounted) return;
    switch (s) {
      case RemoteState.ok:
        _poll?.cancel();
        await _show();
      case RemoteState.asking:
        setState(() => _phase = _Phase.asking);
        _poll?.cancel();
        _poll = Timer(const Duration(seconds: 2), () => unawaited(_knock()));
      case RemoteState.refused:
        setState(() => _phase = _Phase.refused);
      case RemoteState.stopped:
        setState(() => _phase = _Phase.stopped);
      case RemoteState.plain:
        setState(() => _phase = _Phase.plain);
      case RemoteState.offline:
        setState(() => _phase = _Phase.offline);
    }
  }

  Future<void> _show() async {
    final page = await pc.page();
    final base = page.toString().substring(0, page.toString().lastIndexOf('/') + 1);
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF3F6FC))
      ..addJavaScriptChannel('Keepnear', onMessageReceived: (m) => unawaited(_onMessage(m.message)))
      ..setNavigationDelegate(NavigationDelegate(
        // Only the PC's pages (through the relay).
        onNavigationRequest: (r) => r.url.startsWith(base) ? NavigationDecision.navigate : NavigationDecision.prevent,
      ));
    await c.loadRequest(page);
    if (!mounted) return;
    setState(() {
      _web = c;
      _phase = _Phase.ready;
    });
  }

  Future<void> _onMessage(String text) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final path = m['path'] as String? ?? '';
    final name = m['name'] as String? ?? path.split(r'\').last;
    final kind = m['kind'] as String?;
    if (path.isEmpty || _busy != null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (m['cmd'] == 'open' && kind == 'video') {
      // Played straight from the PC (no copy first).
      final uri = await pc.fileUri(path);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _VideoPage(uri: uri, title: name)));
      return;
    }
    setState(() => _busy = name);
    try {
      final f = await pc.fetch(path, name);
      if (!mounted) return;
      if (m['cmd'] == 'save') {
        final k = MediaKind.fromName(name);
        final now = DateTime.now().millisecondsSinceEpoch;
        final to = await MediaSaver().save(
          f,
          FileOffer(id: '$now', assetId: '', name: name, kind: k, createdMs: now, modifiedMs: now, size: await f.length()),
          from: Sender(widget.desktop.id, widget.desktop.name),
        );
        messenger.showSnackBar(SnackBar(content: Text(tr(to == SavedTo.album ? 'rpc.saved_album' : 'rpc.saved_files', {'name': name}))));
      } else if (kind == 'photo') {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PhotoPage(file: f, title: name)));
      } else {
        await openDocument(context, f.path, name: name);
      }
    } catch (e) {
      DiagLog.log('remote', 'open/save failed: $e');
      messenger.showSnackBar(SnackBar(content: Text(tr('rpc.failed', {'name': name}))));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _note(IconData icon, String text, {Widget? action}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: LrColors.muted),
            const SizedBox(height: 14),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action],
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final again = FilledButton(onPressed: () => unawaited(_start()), child: Text(tr('rpc.again')));
    final body = switch (_phase) {
      _Phase.checking || _Phase.connecting => const Center(child: CircularProgressIndicator()),
      _Phase.asking => _note(Icons.computer_rounded, tr('rpc.asking', {'pc': widget.desktop.name})),
      _Phase.refused => _note(Icons.block_rounded, tr('rpc.refused', {'pc': widget.desktop.name}), action: again),
      _Phase.stopped => _note(Icons.link_off_rounded, tr('rpc.stopped', {'pc': widget.desktop.name}), action: again),
      _Phase.plain => _note(Icons.lock_open_rounded, tr('rpc.plain')),
      _Phase.offline => _note(Icons.wifi_off_rounded, tr('rpc.offline', {'pc': widget.desktop.name}), action: again),
      _Phase.locked => _note(Icons.fingerprint_rounded, tr('rpc.locked'), action: again),
      _Phase.ready => WebViewWidget(controller: _web!),
    };
    return Scaffold(
      appBar: AppBar(title: Text(tr('rpc.title', {'pc': widget.desktop.name}), overflow: TextOverflow.ellipsis)),
      body: Stack(children: [
        Positioned.fill(child: body),
        if (_busy != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: const Color(0xFF16213E),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Row(children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(tr('rpc.fetching', {'name': _busy!}), style: const TextStyle(color: Colors.white), overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _PhotoPage extends StatelessWidget {
  const _PhotoPage({required this.file, required this.title});

  final File file;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: InteractiveViewer(
            maxScale: 8,
            child: Image.file(file, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64)),
          ),
        ),
      );
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.uri, required this.title});

  final Uri uri;
  final String title;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(widget.uri);
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_c.play());
    }, onError: (Object e) {
      DiagLog.log('remote', 'video failed: $e');
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    unawaited(_c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: _failed
              ? Text(tr('rpc.video_failed'), style: const TextStyle(color: Colors.white70))
              : !_c.value.isInitialized
                  ? const CircularProgressIndicator()
                  : GestureDetector(
                      onTap: () {
                        unawaited(_c.value.isPlaying ? _c.pause() : _c.play());
                        setState(() {});
                      },
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c)),
                        VideoProgressIndicator(_c, allowScrubbing: true, padding: const EdgeInsets.all(12)),
                      ]),
                    ),
        ),
      );
}
