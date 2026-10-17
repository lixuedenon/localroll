// apps/mobile/lib/ui/send_files_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/file_sender.dart';
import '../services/mobile_settings.dart';
import 'cleanup_page.dart' show formatSize;
import 'send_target.dart';
import 'theme.dart';

/// Where to send [files]: the chooser when phones are nearby (or no PC is
/// set), else the current PC. Null when cancelled.
Future<FileSender?> pickFileTarget(
  BuildContext context,
  MobileSettings settings,
  DesktopDiscovery discovery,
  List<File> files,
) async {
  PairedDesktop? desktop = settings.current;
  NearbyPhone? phone;
  // Only one place it can go: straight there. More than one (two PCs, or a
  // phone nearby): ask every time.
  if (discovery.phones.isNotEmpty || desktop == null || settings.desktops.length > 1) {
    final t = await chooseSendTarget(context, settings, discovery);
    if (t is NearbyPhone) {
      phone = t;
      desktop = null;
    } else if (t is PairedDesktop) {
      desktop = t;
    } else {
      return null;
    }
  }
  return FileSender(settings: settings, discovery: discovery, files: files, desktop: desktop, phone: phone);
}

/// Sending ordinary files, with progress and a clear end.
class SendFilesPage extends StatefulWidget {
  const SendFilesPage({super.key, required this.sender});

  final FileSender sender;

  @override
  State<SendFilesPage> createState() => _SendFilesPageState();
}

class _SendFilesPageState extends State<SendFilesPage> {
  FileSender get s => widget.sender;

  @override
  void initState() {
    super.initState();
    unawaited(s.run());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final theme = Theme.of(context);
        final busy = s.state == FileSendState.connecting || s.state == FileSendState.sending;
        final ok = s.state == FileSendState.done;
        return PopScope(
          canPop: !busy,
          child: Scaffold(
            appBar: AppBar(title: Text(tr('files.sending_to', {'name': s.targetName})), automaticallyImplyLeading: !busy),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(
                    busy ? Icons.upload_rounded : (ok ? Icons.check_circle_rounded : Icons.error_outline_rounded),
                    size: 40,
                    color: busy ? LrColors.safelight : (ok ? LrColors.verified : LrColors.danger),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      busy
                          ? tr(s.state == FileSendState.connecting ? 'files.connecting' : 'files.sending')
                          : ok
                              ? tr('files.done', {'count': s.done, 'name': s.targetName})
                              : tr('files.failed'),
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ]),
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: s.totalBytes == 0 ? null : (s.sentBytes / s.totalBytes).clamp(0.0, 1.0),
                  minHeight: 6,
                ),
                const SizedBox(height: 8),
                Text('${formatSize(s.sentBytes)} / ${formatSize(s.totalBytes)}', style: const TextStyle(color: LrColors.muted)),
                if (s.current != null) Text(s.current!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted)),
                if (s.skipped > 0) Text(tr('files.already', {'count': s.skipped}), style: const TextStyle(color: LrColors.muted)),
                if (s.error != null) ...[
                  const SizedBox(height: 16),
                  Text(s.error!, style: const TextStyle(color: LrColors.danger)),
                  if (s.reason != null) Text(tr('transfer.their_reason', {'reason': s.reason!})),
                ],
                const SizedBox(height: 12),
                for (final f in s.files)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(FileSender.nameOf(f), overflow: TextOverflow.ellipsis),
                  ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: busy
                      ? OutlinedButton(onPressed: s.cancel, child: Text(tr('common.cancel')))
                      : FilledButton(onPressed: () => Navigator.of(context).pop(ok), child: Text(tr('common.ok'))),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
