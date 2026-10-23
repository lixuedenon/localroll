// apps/desktop/lib/ui/people_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/people.dart';
import '../services/text_index.dart';
import '../services/text_indexer.dart';
import 'theme.dart';

/// How far finding faces is (Settings and the People page).
String peopleState(IndexProgress p) => switch (p.state) {
      IndexState.working => tr('people.working', {'done': p.done, 'total': p.total}),
      IndexState.paused => tr('search.state_paused', {'done': p.done, 'total': p.total}),
      IndexState.done => tr('people.done', {'count': p.total}),
      IndexState.failed => tr('search.state_failed'),
      _ => tr('search.state_starting'),
    };

/// Takes every face and name off this library, and switches People off.
Future<void> clearPeople(BuildContext context, AppServices s) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('people.clear')),
      content: SizedBox(width: 420, child: Text(tr('people.clear_confirm'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
          onPressed: () => Navigator.pop(c, true),
          child: Text(tr('people.clear')),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await s.settings.update((x) => x.faces = false);
  s.faceIndexer.wake();
  await s.server.people.clear();
}

/// A person's name, or "no name yet".
String personLabel(Person p) => p.name ?? tr('people.unnamed');

/// Give [id] a name (empty: no name).
Future<void> namePerson(BuildContext context, AppServices s, int id) async {
  final p = s.server.people.person(id);
  if (p == null) return;
  final ctrl = TextEditingController(text: p.name ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('people.name_title')),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(hintText: tr('people.name_hint')),
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
          const SizedBox(height: 8),
          Text(tr('people.name_note'), style: Theme.of(c).textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(tr('common.save'))),
      ],
    ),
  );
  ctrl.dispose();
  if (name == null) return;
  s.server.people.rename(id, name);
}

/// Where each photo of the library is on disk (by its search key).
Future<Map<String, String>> photoPaths(AppServices s) async {
  final out = <String, String>{
    for (final i in s.library.items) TextIndex.mediaKey(i): s.library.absPath(i),
  };
  for (final f in await s.server.files.list()) {
    final rel = s.server.files.relOf(f.path);
    if (rel != null) out[TextIndex.fileKey(rel, f.size)] = f.path;
  }
  return out;
}

/// A face, cut out of its photo, in a circle.
class FaceAvatar extends StatefulWidget {
  const FaceAvatar({super.key, required this.services, required this.face, required this.path, this.size = 112});

  final AppServices services;
  final Face face;
  final String? path;
  final double size;

  @override
  State<FaceAvatar> createState() => _FaceAvatarState();
}

class _FaceAvatarState extends State<FaceAvatar> {
  Future<File?>? _crop;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FaceAvatar old) {
    super.didUpdateWidget(old);
    if (old.face.id != widget.face.id || old.path != widget.path) _load();
  }

  void _load() {
    final f = widget.face;
    final p = widget.path;
    _crop = p == null ? null : widget.services.ffmpeg.faceCrop(p, f.item, f.x, f.y, f.w, f.h);
  }

  @override
  Widget build(BuildContext context) {
    final blank = Container(
      color: LrColors.raised,
      alignment: Alignment.center,
      child: Icon(Icons.face_rounded, size: widget.size * 0.5, color: LrColors.muted),
    );
    return ClipOval(
      child: SizedBox.square(
        dimension: widget.size,
        child: FutureBuilder<File?>(
          future: _crop,
          builder: (context, snap) {
            final file = snap.data;
            if (file == null) return blank;
            return Image.file(file, fit: BoxFit.cover, errorBuilder: (_, _, _) => blank);
          },
        ),
      ),
    );
  }
}

/// "People": everyone found in the photos, most photos first. Click a
/// person to see their photos in the library (returns the person's id).
class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key, required this.services});

  final AppServices services;

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  Map<String, String> _paths = const {};
  bool _showOnce = false;
  bool _showHidden = false;

  PeopleIndex get _people => widget.services.server.people;

  @override
  void initState() {
    super.initState();
    unawaited(_people.load());
    unawaited(photoPaths(widget.services).then((p) {
      if (mounted) setState(() => _paths = p);
    }));
  }

  Future<void> _enable() async {
    await widget.services.settings.update((x) => x.faces = true);
    widget.services.faceIndexer.wake();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, _people, s.faceIndexer.progress]),
      builder: (context, _) {
        final on = s.settings.faces;
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              Text(tr('people.title')),
              if (on) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                      '${peopleState(s.faceIndexer.progress.value)}  ·  '
                      '${tr('people.stats', {'photos': _people.photosRead, 'faces': _people.facesFound})}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: LrColors.muted, fontSize: 13, fontWeight: FontWeight.w400)),
                ),
              ],
            ]),
          ),
          body: on ? _list(context) : _offer(context),
        );
      },
    );
  }

  /// Off: what it does, that it stays here, that nothing else depends on it.
  Widget _offer(BuildContext context) {
    final theme = Theme.of(context);
    final engine = widget.services.faceIndexer.engine;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.face_retouching_natural_rounded, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(tr('people.offer_title'), style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(tr('people.offer'), style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            if (engine.available)
              FilledButton.icon(
                onPressed: _enable,
                icon: const Icon(Icons.check_rounded),
                label: Text(tr('people.enable')),
              )
            else
              Text(tr('people.no_models'), style: const TextStyle(color: LrColors.muted), textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final all = _people.people();
    final shown = [for (final p in all) if (!p.person.hidden && (p.items.length > 1 || p.person.name != null)) p];
    final once = [for (final p in all) if (!p.person.hidden && p.items.length == 1 && p.person.name == null) p];
    final hidden = [for (final p in all) if (p.person.hidden) p];
    if (all.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.face_rounded, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(tr('people.none_yet'), textAlign: TextAlign.center),
        ]),
      );
    }
    final theme = Theme.of(context);
    Widget section(String title, bool open, VoidCallback toggle) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 4),
          child: TextButton.icon(
            onPressed: toggle,
            icon: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            label: Text(title, style: theme.textTheme.titleSmall),
          ),
        );
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(tr('people.hint'), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
        ),
      ),
      _grid(shown),
      if (once.isNotEmpty) ...[
        SliverToBoxAdapter(child: section(tr('people.once', {'count': once.length}), _showOnce, () => setState(() => _showOnce = !_showOnce))),
        if (_showOnce) _grid(once),
      ],
      if (hidden.isNotEmpty) ...[
        SliverToBoxAdapter(
            child: section(tr('people.hidden', {'count': hidden.length}), _showHidden, () => setState(() => _showHidden = !_showHidden))),
        if (_showHidden) _grid(hidden),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }

  Widget _grid(List<PersonView> list) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisExtent: 196,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) => _card(context, list[i]),
        ),
      );

  Widget _card(BuildContext context, PersonView v) {
    final p = v.person;
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).pop(p.id),
      onSecondaryTapUp: (d) => _menu(context, v, d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          FaceAvatar(key: ValueKey(v.cover.id), services: widget.services, face: v.cover, path: _paths[v.cover.item]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(
                personLabel(p),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(color: p.name == null ? LrColors.muted : null),
              ),
            ),
          ]),
          Text(tr('people.n_photos', {'count': v.items.length}), style: theme.textTheme.bodySmall),
          Builder(
            builder: (b) => IconButton(
              tooltip: tr('people.more'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () {
                final box = b.findRenderObject() as RenderBox;
                _menu(context, v, box.localToGlobal(box.size.center(Offset.zero)));
              },
              icon: const Icon(Icons.more_horiz_rounded),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _menu(BuildContext context, PersonView v, Offset at) async {
    final p = v.person;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    Widget row(IconData icon, String text) => Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(text)]);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'open', child: row(Icons.photo_library_outlined, tr('people.see_photos'))),
        PopupMenuItem(value: 'name', child: row(Icons.edit_rounded, tr(p.name == null ? 'people.name' : 'people.rename'))),
        PopupMenuItem(value: 'merge', child: row(Icons.merge_rounded, tr('people.merge'))),
        PopupMenuItem(
          value: 'hide',
          child: row(p.hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded, tr(p.hidden ? 'people.unhide' : 'people.hide')),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open':
        Navigator.of(this.context).pop(p.id);
      case 'name':
        await namePerson(this.context, widget.services, p.id);
      case 'merge':
        await _merge(v);
      case 'hide':
        _people.setHidden(p.id, !p.hidden);
    }
  }

  /// "Same person as…": pick who [v] is.
  Future<void> _merge(PersonView v) async {
    final others = [for (final o in _people.people()) if (o.person.id != v.person.id) o];
    final into = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('people.merge_title')),
        content: SizedBox(
          width: 460,
          height: 420,
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 104, mainAxisExtent: 124),
            itemCount: others.length,
            itemBuilder: (c, i) {
              final o = others[i];
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.pop(c, o.person.id),
                child: Column(children: [
                  const SizedBox(height: 6),
                  FaceAvatar(key: ValueKey(o.cover.id), services: widget.services, face: o.cover, path: _paths[o.cover.item], size: 72),
                  const SizedBox(height: 6),
                  Text(personLabel(o.person), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                  Text(tr('people.n_photos', {'count': o.items.length}), style: const TextStyle(fontSize: 11, color: LrColors.muted)),
                ]),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel')))],
      ),
    );
    if (into == null) return;
    _people.merge(v.person.id, into);
  }
}
