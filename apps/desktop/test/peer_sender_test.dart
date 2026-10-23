// apps/desktop/test/peer_sender_test.dart
//
// PC → PC sending end to end: the sender of one test PC sends real files to
// the receiver of another, over pinned HTTPS on this machine.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/server/transfer_server.dart';
import 'package:localroll_desktop/services/peers.dart';
import 'package:localroll_desktop/services/settings.dart';

import 'support/harness.dart';

void main() {
  late TestPc a;
  late TestPc b;
  late PeerSender sender;
  late PeerPc bAsSeenByA;
  late Directory src;

  setUp(() async {
    TestPc.free = 100 * 1024 * 1024 * 1024;
    a = await TestPc.start();
    b = await TestPc.start();
    // Paired as "Allow" would do it: B trusts A's token, A pins B's certificate.
    const token = 'token-a-at-b-0123456789abcdefghijklmnop';
    await b.settings.update((s) => s.trusted[a.settings.deviceId] = TrustedDevice(
          id: a.settings.deviceId,
          name: 'PC A',
          platform: 'windows',
          token: token,
          pairedMs: 1,
          secure: true,
        ));
    bAsSeenByA = PeerPc(
      id: b.settings.deviceId,
      name: 'PC B',
      hosts: const ['127.0.0.1'],
      port: b.port,
      token: token,
      pairedMs: 1,
      fingerprint: b.tls.fingerprint,
    );
    await a.settings.update((s) => s.peers[bAsSeenByA.id] = bAsSeenByA);
    sender = PeerSender(settings: a.settings, peers: PeerDirectory(settings: a.settings, server: a.server));
    src = await Directory.systemTemp.createTemp('lr_send_src');
  });

  tearDown(() async {
    sender.dispose();
    await a.close();
    await b.close();
    try {
      await src.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> make(String rel, List<int> data) async {
    final f = File('${src.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data);
    return f;
  }

  Future<SendJob> run(List<SendFile> files) async {
    final j = sender.add(bAsSeenByA, files, 'test');
    await eventually(() => j.over, within: const Duration(seconds: 30));
    return j;
  }

  test('files, a document and a folder arrive where they belong', () async {
    final photo = await make('beach.jpg', bytesOf(200 * 1024, 1));
    final doc = await make('notes.pdf', [...'%PDF-1.4'.codeUnits, ...bytesOf(5000, 2)]);
    final inFolder = await make('Trip/day1/map.zip', bytesOf(3000, 3));
    final j = await run([
      SendFile.plain(photo, 'beach.jpg', toLibrary: true)!,
      SendFile.plain(doc, 'notes.pdf')!,
      SendFile.plain(inFolder, 'Trip/day1/map.zip')!,
    ]);
    expect(j.state, SendJobState.done, reason: j.error);
    expect(j.sentFiles, 3);

    // The photo is in B's library…
    expect(b.library.items.where((i) => i.name == 'beach.jpg'), hasLength(1));
    // …the document and the folder are beside it, not in the library view.
    final all = Directory(b.library.rootPath).listSync(recursive: true).whereType<File>().map((f) => f.path).toList();
    expect(all.where((p) => p.endsWith('notes.pdf')), hasLength(1));
    final map = all.where((p) => p.endsWith('map.zip')).single;
    expect(map.replaceAll('\\', '/'), contains('/Trip/day1/map.zip'));
    expect(await File(map).readAsBytes(), await inFolder.readAsBytes());
  });

  test('sending the same again: skipped, nothing doubled', () async {
    final f = await make('a.jpg', bytesOf(1000));
    final first = await run([SendFile.plain(f, 'a.jpg', toLibrary: true)!]);
    expect(first.state, SendJobState.done);
    final again = await run([SendFile.plain(f, 'a.jpg', toLibrary: true)!]);
    expect(again.state, SendJobState.done);
    expect(again.skippedFiles, 1);
    expect(b.library.items, hasLength(1));
  });

  test('a big file goes in several chunks and arrives intact', () async {
    final data = bytesOf(LrProtocol.chunkSize * 2 + 12345, 5);
    final f = await make('video.mp4', data);
    final j = await run([SendFile.plain(f, 'video.mp4', toLibrary: true)!]);
    expect(j.state, SendJobState.done, reason: j.error);
    final item = b.library.items.single;
    expect(await File(b.library.absPath(item)).readAsBytes(), data);
  });

  test('B is short of space: the job fails with "disk_full", nothing half-sent', () async {
    TestPc.free = 300 * 1024 * 1024;
    final f = await make('big.bin', bytesOf(1000));
    // Pretend it is big: B only looks at the announced size.
    final big = SendFile(
      path: f.path,
      name: 'big.mov',
      assetId: 'file:big',
      kind: MediaKind.video,
      createdMs: 1,
      modifiedMs: 1,
      size: 200 * 1024 * 1024,
    );
    final j = await run([big]);
    expect(j.state, SendJobState.failed);
    expect(j.error, 'disk_full');
    expect(b.library.items, isEmpty);
  });

  test('B declines with a reason: A shows it', () async {
    await b.server.setFamily(a.settings.deviceId, false);
    void listen() {
      for (final x in b.server.incomingAsks.value) {
        b.server.answerIncoming(x, const AskAnswer(accept: false, reason: 'Busy'));
      }
    }

    b.server.incomingAsks.addListener(listen);
    final f = await make('a.jpg', bytesOf(100));
    final j = await run([SendFile.plain(f, 'a.jpg', toLibrary: true)!]);
    b.server.incomingAsks.removeListener(listen);
    expect(j.state, SendJobState.failed);
    expect(j.error, 'declined');
    expect(j.reason, 'Busy');
  });

  test('B shows a different certificate: A refuses to send', () async {
    await a.settings.update((s) => s.peers[bAsSeenByA.id]!.fingerprint = 'ab' * 32);
    final f = await make('a.jpg', bytesOf(100));
    final j = await run([SendFile.plain(f, 'a.jpg', toLibrary: true)!]);
    expect(j.state, SendJobState.failed);
    expect(j.error, 'cert_changed');
    expect(b.library.items, isEmpty);
  });

  test('a file changed after it was chosen: reported, not sent wrong', () async {
    final f = await make('a.jpg', bytesOf(100));
    final sf = SendFile.plain(f, 'a.jpg', toLibrary: true)!;
    await f.writeAsBytes(bytesOf(150));
    final j = await run([sf]);
    expect(j.failedFiles, 1);
    expect(j.error, 'file_changed');
    expect(b.library.items, isEmpty);
  });

  test('B offline: waits (kept across restarts), then goes when B is online', () async {
    var online = false;
    sender.isOnline = (_) => online;
    final f = await make('wait.jpg', bytesOf(300, 4));
    final gone = await make('gone.jpg', bytesOf(300, 5));
    final j = sender.add(bAsSeenByA, [SendFile.plain(f, 'wait.jpg', toLibrary: true)!, SendFile.plain(gone, 'gone.jpg', toLibrary: true)!], 'later');
    expect(j.state, SendJobState.held);
    expect(sender.busy, isFalse); // background reading isn't held up by it
    // LocalRoll closed and opened again: still waiting.
    await eventually(() => File('${a.settings.dataDir.path}${Platform.pathSeparator}send_waiting.json').existsSync());
    final again = PeerSender(settings: a.settings, peers: PeerDirectory(settings: a.settings, server: a.server))
      ..isOnline = (_) => online;
    await again.loadHeld();
    expect(again.jobs.single.state, SendJobState.held);
    expect(again.jobs.single.files, hasLength(2));
    sender.cancel(j);
    // Deleted meanwhile: left out, said so.
    await gone.delete();
    online = true;
    again.online(bAsSeenByA.id);
    final k = again.jobs.single;
    await eventually(() => k.over, within: const Duration(seconds: 30));
    expect(k.state, SendJobState.done, reason: k.error);
    expect(k.sentFiles, 1);
    expect(k.goneFiles, 1);
    expect(b.library.items.single.name, 'wait.jpg');
    again.dispose();
  });
}
