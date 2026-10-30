// apps/desktop/test/recordings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/recordings.dart';

void main() {
  test('names: base_what_extra_date', () {
    final at = DateTime(2026, 10, 30, 14, 5);
    expect(recName('Trip', 'explanation', at), 'Trip_explanation_20261030-1405');
    expect(recName('', 'recording', at), 'recording_20261030-1405');
    expect(recName('Trip', 'screenshot', at, extra: '00-37'), 'Trip_screenshot_00-37_20261030-1405');
  });

  test('the program from a window title', () {
    expect(programOf('ChatGPT - Google Chrome'), 'Google Chrome');
    expect(programOf('Notepad'), 'Notepad');
    expect(programOf('a - b - Excel'), 'Excel');
  });

  test('a recording survives being written and read', () {
    final r = Recording(id: 'x', kind: RecKind.narration, path: 'C:/a/b.mp4', source: 'Trip', createdMs: 5, narrationId: 'n1', sentTo: ['iPhone']);
    final back = Recording.fromJson(r.toJson())!;
    expect(back.kind, RecKind.narration);
    expect(back.source, 'Trip');
    expect(back.narrationId, 'n1');
    expect(back.sentTo, ['iPhone']);
  });
}
