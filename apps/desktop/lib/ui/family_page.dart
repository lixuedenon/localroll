// apps/desktop/lib/ui/family_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/settings.dart';
import 'breathing.dart';
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
            ..._otherSection(theme, family: true),
            ..._otherSection(theme, family: false),
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
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 36, top: 4, bottom: 4),
                // Glows while LocalRoll is open on that phone.
                child: Breathing(
                  online: widget.services.isOnline(d.id),
                  radius: 10,
                  color: LrColors.raised,
                  child: ListTile(
                dense: true,
                leading: Icon(st.trusted[d.id]?.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android),
                title: Text('${family.labelOf(d.id)} · ${d.deviceName}'),
                subtitle: Text([
                  widget.services.isOnline(d.id) ? tr('family.online') : tr('family.offline'),
                  tr('settings.paired_on', {'date': formatDate(DateTime.fromMillisecondsSinceEpoch(d.pairedMs))}),
                ].join(' · ')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (st.trusted[d.id] case final t?) _accessChip(t),
                  PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v.startsWith('access_')) {
                      await _setAccess(d.id, v);
                    } else if (v == 'move') {
                      final name = await _askMember(member, family.members);
                      if (name != null) await st.update((x) => x.trusted[d.id]?.memberName = name);
                    } else if (v == 'guest') {
                      await widget.services.server.setFamily(d.id, false);
                    } else if (v == 'unpair') {
                      await st.update((x) => x.trusted.remove(d.id));
                      _toast(tr('settings.unpaired', {'name': d.deviceName}));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'move', child: Text(tr('family.move'))),
                    PopupMenuItem(value: 'guest', child: Text(tr('family.make_guest'))),
                    PopupMenuItem(value: 'unpair', child: Text(tr('settings.unpair'))),
                    if (st.trusted[d.id] case final t?) ..._accessItems(t),
                  ],
                ),
                ]),
              ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// "Family PCs" (family: true) or "Guests" (phones and PCs, family: false).
  List<Widget> _otherSection(ThemeData theme, {required bool family}) {
    final s = widget.services;
    final list = [
      for (final t in s.settings.trusted.values)
        if (t.familyMember == family && (!family || isDesktopPlatform(t.platform))) t,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (list.isEmpty) return const [];
    return [
      const SizedBox(height: 18),
      Text(tr(family ? 'family.pcs' : 'family.guests'), style: theme.textTheme.titleMedium),
      const SizedBox(height: 2),
      Text(tr(family ? 'family.pcs_hint' : 'family.guests_hint'), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
      const SizedBox(height: 8),
      for (final t in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Breathing(
            online: s.isOnline(t.id),
            radius: 12,
            child: ListTile(
              leading: Icon(isDesktopPlatform(t.platform)
                  ? Icons.computer_rounded
                  : (t.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android)),
              title: Text(t.name),
              subtitle: Text([
                s.isOnline(t.id) ? tr('family.online') : tr('family.offline'),
                tr('settings.paired_on', {'date': formatDate(DateTime.fromMillisecondsSinceEpoch(t.pairedMs))}),
              ].join(' · ')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (!isDesktopPlatform(t.platform)) _accessChip(t),
                PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v.startsWith('access_')) await _setAccess(t.id, v);
                  if (v == 'family') await s.server.setFamily(t.id, true);
                  if (v == 'guest') await s.server.setFamily(t.id, false);
                  if (v == 'unpair') {
                    await s.settings.update((x) => x.trusted.remove(t.id));
                    _toast(tr('settings.unpaired', {'name': t.name}));
                  }
                },
                itemBuilder: (_) => [
                  if (family)
                    PopupMenuItem(value: 'guest', child: Text(tr('family.make_guest')))
                  else
                    PopupMenuItem(value: 'family', child: Text(tr('family.make_family'))),
                  // Other PCs are disconnected on the Send page (both sides).
                  if (!isDesktopPlatform(t.platform)) PopupMenuItem(value: 'unpair', child: Text(tr('settings.unpair'))),
                  if (!isDesktopPlatform(t.platform)) ..._accessItems(t),
                ],
              ),
              ]),
            ),
          ),
        ),
    ];
  }

  /// The phone's library access, shown where it is seen and changed in one
  /// click (it was easy to miss inside the ⋮ menu).
  Widget _accessChip(TrustedDevice t) => PopupMenuButton<LibraryAccess>(
        tooltip: tr('family.access_title'),
        onSelected: (a) => widget.services.server.setAccess(t.id, a),
        itemBuilder: (_) => [
          for (final a in LibraryAccess.values)
            CheckedPopupMenuItem(value: a, checked: t.libraryAccess == a, child: Text(tr('family.access_${a.name}'))),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.libraryAccess == LibraryAccess.none ? LrColors.line : LrColors.verified),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(
              t.libraryAccess == LibraryAccess.manage ? Icons.delete_sweep_outlined : Icons.photo_library_outlined,
              size: 16,
              color: t.libraryAccess == LibraryAccess.none ? LrColors.muted : LrColors.verified,
            ),
            const SizedBox(width: 6),
            Text(tr('family.access_${t.libraryAccess.name}'), style: const TextStyle(fontSize: 12.5)),
            const Icon(Icons.arrow_drop_down_rounded, size: 18),
          ]),
        ),
      );

  /// What a phone may do with this library from afar (browse / manage).
  List<PopupMenuEntry<String>> _accessItems(TrustedDevice t) => [
        const PopupMenuDivider(),
        for (final a in LibraryAccess.values)
          CheckedPopupMenuItem(
            value: 'access_${a.name}',
            checked: t.libraryAccess == a,
            child: Text(tr('family.access_${a.name}')),
          ),
      ];

  Future<void> _setAccess(String id, String value) =>
      widget.services.server.setAccess(id, LibraryAccess.parse(value.substring('access_'.length)));

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
