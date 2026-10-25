// apps/desktop/test/narration_test.dart
//
// Recorded explanations: what the player did turns into the right pieces;
// microphones are found in ffmpeg's list; a recording is kept and read back.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/mic.dart';
import 'package:localroll_desktop/ui/player/narration.dart';

void main() {
  const all = Rect.fromLTWH(0, 0, 1, 1);
  NarrationSample at(int t, int file, int pos, {bool playing = true, double rate = 1, Rect zoom = all}) =>
      NarrationSample(t: t, file: file, pos: pos, playing: playing, rate: rate, zoom: zoom);

  NarrationSession session(List<NarrationSample> samples, {int? length, int files = 1}) => NarrationSession(
        id: 'x',
        createdMs: 0,
        files: [
          for (var i = 0; i < files; i++) NarrationFile(path: 'C:/v$i.mp4', name: 'v$i.mp4', video: true, width: 1920, height: 1080),
        ],
        samples: samples,
        lengthMs: length ?? (samples.isEmpty ? 0 : samples.last.t + 50),
      );

  test('play, pause (stands still), play on: three pieces, the same length as the recording', () {
    final s = <NarrationSample>[
      for (var t = 0; t <= 2000; t += 50) at(t, 0, 10000 + t),
      for (var t = 2050; t <= 5000; t += 50) at(t, 0, 12000, playing: false),
      for (var t = 5050; t <= 6000; t += 50) at(t, 0, 12000 + (t - 5050)),
    ];
    final p = narrationPieces(session(s, length: 6050));
    expect(p.length, 3);
    expect(p[0].still, isFalse);
    expect(p[0].fromMs, 10000);
    expect(p[1].still, isTrue);
    expect(p[1].fromMs, 12000);
    expect(p[2].still, isFalse);
    expect(p.fold<int>(0, (a, x) => a + x.lengthMs), 6050);
    expect(p[0].normalSpeed, isTrue);
  });

  test('a jump in the video, slow motion, another file, zooming in: new pieces', () {
    final s = <NarrationSample>[
      for (var t = 0; t <= 1000; t += 50) at(t, 0, t),
      // Jumped to 30 s.
      for (var t = 1050; t <= 2000; t += 50) at(t, 0, 30000 + (t - 1050)),
      // A quarter speed.
      for (var t = 2050; t <= 4000; t += 50) at(t, 0, 31000 + ((t - 2050) * 0.25).round(), rate: 0.25),
      // The next file.
      for (var t = 4050; t <= 5000; t += 50) at(t, 1, t - 4050),
      // Zoomed in.
      for (var t = 5050; t <= 6000; t += 50) at(t, 1, t - 4050, zoom: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5)),
    ];
    final p = narrationPieces(session(s, files: 2));
    expect(p.length, 5);
    expect(p[1].fromMs, 30000);
    expect(p[2].normalSpeed, isFalse);
    expect(p[3].file, 1);
    expect(p[4].zoom.width, 0.5);
  });

  test('a recording is kept and read back', () {
    final n = session([at(0, 0, 0), at(50, 0, 50)])
      ..noteIds.add('note-1')
      ..inks.add(NarrationInk.fromJson({'f': 0, 'ink': {'id': 'i', 't': 'pen', 'p': [0.1, 0.1, 0.2, 0.2]}, 's': 30, 'pt': [0, 80]}));
    final back = NarrationSession.fromJson(n.toJson());
    expect(back.samples.length, 2);
    expect(back.noteIds, {'note-1'});
    expect(back.inks.single.startT, 30);
    expect(back.inks.single.times, [0, 80]);
    expect(back.files.single.name, 'v0.mp4');
  });

  test('microphones from ffmpeg\'s DirectShow list', () {
    const text = '''
[dshow @ 000001] "Integrated Camera" (video)
[dshow @ 000001]   Alternative name "@device_pnp_\\\\?\\usb#vid"
[dshow @ 000001] "Microphone Array (Realtek(R) Audio)" (audio)
[dshow @ 000001]   Alternative name "@device_cm_{33D9A762}\\wave_{1}"
[dshow @ 000001] "耳机 (AirPods)" (audio)
''';
    expect(MicRecorder.parseDevices(text), ['Microphone Array (Realtek(R) Audio)', '耳机 (AirPods)']);
  });
}
