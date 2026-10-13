// apps/desktop/lib/ui/family_page.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import 'breathing_dot.dart';
import 'format.dart';
import 'theme.dart';

/// Family: paired phones grouped by person — rename people, move a phone to
/// another person, unpair, one folder per person.
class FamilyPage extends StatefulWidget {
  const FamilyPage({super.key, required this.services});

  final AppServices services;

  @override
  State<FamilyPage> createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
  // Re-check "online" now and then (it turns off by itself after a while).
  late final Timer _tick = Timer.periodic(const Duration(seconds: 20), (_) {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.server]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('family.title'))),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(tr('family.hint'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (s.settings.family.members.isEmpty) Text(tr('settings.no_phones')),
            for (final m in s.settings.family.members) _memberCard(theme, m),
            if (s.settings.family.members.isNotEmpty) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.settings.folderPerMember,
                onChanged: (v) => s.settings.update((x) => x.folderPerMember = v),
                title: Text(tr('family.folder_per_member')),
                subtitle: Text(tr('family.folder_per_member_hint')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One family member: name (renamable) and their phones.
  Widget _memberCard(ThemeData theme, String member) {
    final st = widget.services.settings;
    final family = st.family;
    final devices = family.devicesOf(member);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(radius: 16, child: Text(member.characters.first.toUpperCase())),
              const SizedBox(width: 12),
              Expanded(child: Text(member, style: theme.textTheme.titleMedium)),
              IconButton(
                tooltip: tr('family.rename'),
                icon: const Icon(Icons.edit_rounded, size: 20),
                onPressed: () async {
                  final name = await _askMember(member, family.members);
                  if (name == null) return;
                  await st.update((x) {
                    for (final d in devices) {
                      x.trusted[d.id]?.memberName = name;
                    }
                  });
                },
              ),
            ]),
            for (final d in devices)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsetsDirectional.only(start: 44),
                leading: Row(mainAxisSize: MainAxisSize.min, children: [
                  // Breathing dot: LocalRoll is open on that phone right now.
                  BreathingDot(online: widget.services.isOnline(d.id), size: 8),
                  Icon(st.trusted[d.id]?.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android),
                ]),
                title: Text('${family.labelOf(d.id)} · ${d.deviceName}'),
                subtitle: Text([
                  widget.services.isOnline(d.id) ? tr('family.online') : tr('family.offline'),
                  tr('settings.paired_on', {'date': formatDate(DateTime.fromMillisecondsSinceEpoch(d.pairedMs))}),
                ].join(' · ')),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'move') {
                      final name = await _askMember(member, family.members);
                      if (name != null) await st.update((x) => x.trusted[d.id]?.memberName = name);
                    } else if (v == 'unpair') {
                      await st.update((x) => x.trusted.remove(d.id));
                      _toast(tr('settings.unpaired', {'name': d.deviceName}));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'move', child: Text(tr('family.move'))),
                    PopupMenuItem(value: 'unpair', child: Text(tr('settings.unpair'))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Asks for a member name; existing members are one tap away.
  Future<String?> _askMember(String current, List<String> members) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('family.member_name')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in members) ActionChip(label: Text(m), onPressed: () => Navigator.pop(ctx, m)),
              ]),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctrl.dispose();
    final t = name?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}
