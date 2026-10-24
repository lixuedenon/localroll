// apps/desktop/test/player_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/open_with.dart';
import 'package:localroll_desktop/services/player_memory.dart';
import 'package:localroll_desktop/ui/player/player_entry.dart';

void main() {
  RecentEntry r(String path) => RecentEntry(path: path, name: path.split('/').last, video: true, openedMs: 1);

  test('player opens photos, videos and camera RAW, not documents', () {
    expect(PlayerEntry.playable('a.HEIC'), isTrue);
    expect(PlayerEntry.playable('clip.mkv'), isTrue);
    expect(PlayerEntry.playable('old.wmv'), isTrue);
    expect(PlayerEntry.playable('raw.CR3'), isTrue);
    expect(PlayerEntry.playable('notes.pdf'), isFalse);
    expect(PlayerEntry.isVideoName('x.MOV'), isTrue);
    expect(PlayerEntry.isVideoName('x.avif'), isFalse);
  });

  test('folder order is like Explorer (2 before 10)', () {
    final names = ['img_10.jpg', 'img_2.jpg', 'img_1.jpg']..sort(PlayerEntry.naturalCompare);
    expect(names, ['img_1.jpg', 'img_2.jpg', 'img_10.jpg']);
  });

  test('a folder lists only its photos and videos', () async {
    final dir = await Directory.systemTemp.createTemp('lr_player');
    addTearDown(() => dir.delete(recursive: true));
    for (final n in ['b.mp4', 'a.jpg', 'c.txt', 'd10.png', 'd9.png']) {
      await File('${dir.path}${Platform.pathSeparator}$n').writeAsString('x');
    }
    final got = PlayerEntry.inFolder(dir.path).map((p) => p.split(Platform.pathSeparator).last).toList();
    expect(got, ['a.jpg', 'b.mp4', 'd9.png', 'd10.png']);
    final e = PlayerEntry.fromPath('${dir.path}${Platform.pathSeparator}b.mp4');
    expect(e?.video, isTrue);
    expect(e?.size, 1);
    expect(PlayerEntry.fromPath('${dir.path}${Platform.pathSeparator}c.txt'), isNull);
    expect(PlayerEntry.fromPath('${dir.path}${Platform.pathSeparator}gone.jpg'), isNull);
  });

  test('where a video was left: kept in the middle, not near the start or end', () async {
    final dir = await Directory.systemTemp.createTemp('lr_player');
    addTearDown(() => dir.delete(recursive: true));
    final m = PlayerMemory(File('${dir.path}/player.json'));
    const len = Duration(minutes: 10);
    m.setPosition('k', const Duration(seconds: 3), len, entry: r('/v.mp4'));
    expect(m.positionOf('k'), isNull);
    m.setPosition('k', const Duration(minutes: 4), len, entry: r('/v.mp4'));
    expect(m.positionOf('k'), const Duration(minutes: 4));
    expect(m.lastKey, 'k');
    m.setPosition('k', const Duration(minutes: 9, seconds: 58), len, entry: r('/v.mp4'));
    expect(m.positionOf('k'), isNull);
    expect(m.last, isNull);

    m.setPosition('k2', const Duration(minutes: 2), len, entry: r('/w.mp4'));
    m.opened(r('/w.mp4'));
    m.setEndMode(EndMode.next);
    await m.flush();
    final again = PlayerMemory(File('${dir.path}/player.json'));
    await again.load();
    expect(again.positionOf('k2'), const Duration(minutes: 2));
    expect(again.recent.single.path, '/w.mp4');
    expect(again.endMode, EndMode.next);
    expect(again.last?.path, '/w.mp4');
  });

  test('recent list: newest first, no doubles, capped', () {
    final m = PlayerMemory(File('${Directory.systemTemp.path}/lr_unused_player.json'));
    for (var i = 0; i < PlayerMemory.maxRecent + 5; i++) {
      m.opened(r('/f$i.mp4'));
    }
    m.opened(r('/F3.mp4'));
    expect(m.recent.length, PlayerMemory.maxRecent);
    expect(m.recent.first.path, '/F3.mp4');
    expect(m.recent.where((e) => e.path.toLowerCase() == '/f3.mp4').length, 1);
    m.forget('/f3.mp4');
    expect(m.recent.any((e) => e.path.toLowerCase() == '/f3.mp4'), isFalse);
  });

  test('"Open with" entries never take over the default program', () {
    final reg = OpenWith.regFile(exe: r'C:\Apps\LocalRoll\LocalRoll.exe', exeName: 'LocalRoll.exe', verb: 'Play with LocalRoll', extensions: ['mp4', 'heic']);
    expect(reg, contains(r'SystemFileAssociations\.mp4\shell\LocalRoll.Play'));
    expect(reg, contains('"MUIVerb"="Play with LocalRoll"'));
    expect(reg, startsWith('Windows Registry Editor Version 5.00'));
    expect(reg, contains(r'@="\"C:\\Apps\\LocalRoll\\LocalRoll.exe\" \"%1\""'));
    expect(reg, contains('[HKEY_CURRENT_USER\\Software\\Classes\\.mp4\\OpenWithProgids]'));
    expect(reg, contains('".heic"=""'));
    // The extension's own default value (which program opens it) is not written.
    expect(RegExp(r'\[HKEY_CURRENT_USER\\Software\\Classes\\\.mp4\]').hasMatch(reg), isFalse);
    expect(reg, isNot(contains('HKEY_LOCAL_MACHINE')));
  });
}
