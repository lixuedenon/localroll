// packages/ink/lib/src/packs/art.dart
part of '../stamp_packs.dart';

// Music, drawing / painting, photo & video, dance & stage. Drawn here or
// from Material Symbols (Apache 2.0). Names: the app's text 'stamp.<id>'.

/// A note head at (x, y), tilted like printed music.
List<Offset> _head(double x, double y, double rx, double ry) {
  const t = -0.35;
  return [
    for (var k = 0; k <= 32; k++)
      Offset(x + rx * math.cos(_tau * k / 32) * math.cos(t) - ry * math.sin(_tau * k / 32) * math.sin(t),
          y + rx * math.cos(_tau * k / 32) * math.sin(t) + ry * math.sin(_tau * k / 32) * math.cos(t)),
  ];
}

/// A note: 0 whole, 1 half, 2 quarter, 3 eighth, 4 sixteenth.
StampShape _note(int kind) {
  const x = 0.38, y = 0.8, rx = 0.2, ry = 0.13;
  return _sh(0.7, [
    if (kind <= 1) _ln([_head(x, y, rx, ry)], w: 0.045) else _fl([_head(x, y, rx, ry)]),
    if (kind >= 1)
      _ln([
        [_o(x + rx * 0.92, y - 0.04), _o(x + rx * 0.92, 0.08)]
      ], w: 0.04),
    for (var f = 0; f < kind - 2; f++)
      _ln([
        [_o(x + rx * 0.92, 0.08 + f * 0.15), _o(0.9, 0.3 + f * 0.15), _o(0.85, 0.45 + f * 0.15)]
      ], w: 0.05),
  ]);
}

/// A chord grid: [strings] × 5 frets, [dots]: (string, fret) pressed.
StampShape _chordGrid(int strings, List<(int, int)> dots) {
  final l = 0.15, r = 0.85, t = 0.12, b = 0.92;
  final dx = (r - l) / (strings - 1), dy = (b - t) / 5;
  return _sh(0.8, [
    _ln([
      for (var s = 0; s < strings; s++) [_o(l + s * dx, t), _o(l + s * dx, b)],
      for (var f = 1; f <= 5; f++) [_o(l, t + f * dy), _o(r, t + f * dy)],
    ], w: 0.02),
    _ln([
      [_o(l, t), _o(r, t)]
    ], w: 0.06),
    _fl([for (final (s, f) in dots) _ci(l + s * dx, t + (f - 0.5) * dy, 0.06, aspect: 0.8)]),
  ]);
}

/// A frame of [w]:[h] with its label, for picture shapes.
StampShape _frame(double w, double h, String label) {
  final aspect = w / h;
  return _sh(aspect, [
    _ln([_rc(0.02, 0.02, 0.98, 0.98)], w: 0.03),
    _tx(label, size: math.min(0.3, 0.3 * aspect)),
  ]);
}

/// Corner brackets (focus / safe frame).
List<List<Offset>> _corners(double l, double t, double r, double b, double len, {double aspect = 1}) {
  final lx = len / aspect;
  return [
    [_o(l, t + len), _o(l, t), _o(l + lx, t)],
    [_o(r - lx, t), _o(r, t), _o(r, t + len)],
    [_o(r, b - len), _o(r, b), _o(r - lx, b)],
    [_o(l + lx, b), _o(l, b), _o(l, b - len)],
  ];
}

List<Stamp> _artStamps() {
  Stamp s(String id, String pack, StampShape shape) => Stamp(id: id, pack: pack, shape: shape);
  StampShape ic(String name, {int? color}) => StampPacks._ic(name, color: color);
  const wheel = [0xFFE53935, 0xFFFB8C00, 0xFFFDD835, 0xFF7CB342, 0xFF43A047, 0xFF00897B, 0xFF039BE5, 0xFF1E88E5, 0xFF3949AB, 0xFF8E24AA, 0xFFD81B60, 0xFFF4511E];
  // Three-way grid over a frame.
  StampShape thirds(double aspect) => _sh(aspect, [
        _ln([_rc(0.02, 0.02, 0.98, 0.98)], w: 0.03),
        _ln([
          [_o(1 / 3, 0.02), _o(1 / 3, 0.98)],
          [_o(2 / 3, 0.02), _o(2 / 3, 0.98)],
          [_o(0.02, 1 / 3), _o(0.98, 1 / 3)],
          [_o(0.02, 2 / 3), _o(0.98, 2 / 3)],
        ], w: 0.015),
      ]);
  return [
    // --------------------------------------------------------------- music
    s(
      'mus_staff',
      'music',
      _sh(4, [
        _ln([for (var k = 0; k < 5; k++) [_o(0.01, 0.15 + k * 0.175), _o(0.99, 0.15 + k * 0.175)]], w: 0.03),
        _ln([
          [_o(0.01, 0.15), _o(0.01, 0.85)],
          [_o(0.99, 0.15), _o(0.99, 0.85)],
        ], w: 0.04),
      ]),
    ),
    s('mus_treble', 'music', _sh(0.5, [_tx('𝄞', size: 0.9)])),
    s('mus_bass', 'music', _sh(0.7, [_tx('𝄢', size: 0.8)])),
    s('mus_whole', 'music', _note(0)),
    s('mus_half', 'music', _note(1)),
    s('mus_quarter', 'music', _note(2)),
    s('mus_eighth', 'music', _note(3)),
    s('mus_sixteenth', 'music', _note(4)),
    s(
      'mus_rest',
      'music',
      _sh(0.5, [
        _ln([
          [_o(0.35, 0.08), _o(0.7, 0.38), _o(0.38, 0.6), _o(0.68, 0.82), _o(0.42, 0.78), _o(0.55, 0.95)]
        ], w: 0.09),
      ]),
    ),
    s('mus_sharp', 'music', _sh(0.7, [_tx('♯', size: 0.9)])),
    s('mus_flat', 'music', _sh(0.7, [_tx('♭', size: 0.9)])),
    s('mus_natural', 'music', _sh(0.7, [_tx('♮', size: 0.9)])),
    s('mus_time', 'music', _sh(0.6, [_tx('4', y: 0.28, size: 0.48), _tx('4', y: 0.74, size: 0.48)])),
    s(
      'mus_repeat',
      'music',
      _sh(0.7, [
        _ln([
          [_o(0.88, 0.08), _o(0.88, 0.92)]
        ], w: 0.12),
        _ln([
          [_o(0.68, 0.08), _o(0.68, 0.92)]
        ], w: 0.04),
        _fl([_ci(0.42, 0.38, 0.06, aspect: 0.7), _ci(0.42, 0.62, 0.06, aspect: 0.7)]),
      ]),
    ),
    s('mus_piano_p', 'music', _sh(1, [_tx('p', size: 0.8)])),
    s('mus_forte', 'music', _sh(1, [_tx('f', size: 0.8)])),
    s(
      'mus_cresc',
      'music',
      _sh(3, [
        _ln([
          [_o(0.96, 0.15), _o(0.04, 0.5), _o(0.96, 0.85)]
        ], w: 0.05),
      ]),
    ),
    s(
      'mus_decresc',
      'music',
      _sh(3, [
        _ln([
          [_o(0.04, 0.15), _o(0.96, 0.5), _o(0.04, 0.85)]
        ], w: 0.05),
      ]),
    ),
    s('mus_tie', 'music', _sh(3, [_ln([_el(0.5, 0.3, 0.45, 0.45, a0: math.pi * 0.85, a1: math.pi * 0.15, n: 30)], w: 0.06)])),
    s('mus_jianpu', 'music', _sh(3, [_tx('1 2 3 4', size: 0.6)])),
    s(
      'mus_piano',
      'music',
      _sh(2.4, [
        _ln([_rc(0.01, 0.04, 0.99, 0.96), for (var k = 1; k < 7; k++) [_o(0.01 + k * 0.14, 0.04), _o(0.01 + k * 0.14, 0.96)]], w: 0.025),
        _fl([
          for (final k in [1, 2, 4, 5, 6]) _rc(0.01 + k * 0.14 - 0.045, 0.04, 0.01 + k * 0.14 + 0.045, 0.6),
        ]),
      ]),
    ),
    s('mus_guitar', 'music', _chordGrid(6, const [(1, 3), (2, 2), (4, 1)])),
    s('mus_ukulele', 'music', _chordGrid(4, const [(0, 2)])),
    s(
      'mus_metronome',
      'music',
      _sh(0.8, [
        _ln([
          [_o(0.3, 0.06), _o(0.7, 0.06), _o(0.9, 0.94), _o(0.1, 0.94), _o(0.3, 0.06)],
          [_o(0.5, 0.8), _o(0.72, 0.2)],
        ], w: 0.04),
        _fl([_ci(0.66, 0.36, 0.06, aspect: 0.8)]),
      ]),
    ),
    s('mus_breath', 'music', _sh(0.6, [_tx(',', size: 0.9)])),
    s('mus_note_icon', 'music', ic('music_note')),

    // ---------------------------------------------------- drawing / painting
    s('art_thirds', 'art', thirds(1.5)),
    s(
      'art_golden',
      'art',
      _sh(1.618, [
        _ln([_rc(0.01, 0.02, 0.99, 0.98)], w: 0.03),
        _ln([
          [_o(0.618, 0.02), _o(0.618, 0.98)],
          [_o(0.618, 0.618), _o(0.99, 0.618)],
          [_o(0.854, 0.618), _o(0.854, 0.98)],
        ], w: 0.015),
        _ln([
          [
            ..._el(0.618, 0.98, 0.607, 0.96, a0: math.pi, a1: math.pi * 1.5, n: 20),
            ..._el(0.618, 0.618, 0.372, 0.596, a0: math.pi * 1.5, a1: _tau, n: 16),
            ..._el(0.854, 0.618, 0.136, 0.362, a0: 0, a1: math.pi * 0.5, n: 12),
          ],
        ], w: 0.025),
      ]),
    ),
    s(
      'art_diagonals',
      'art',
      _sh(1.5, [
        _ln([_rc(0.02, 0.02, 0.98, 0.98)], w: 0.03),
        _ln([
          [_o(0.02, 0.02), _o(0.98, 0.98)],
          [_o(0.98, 0.02), _o(0.02, 0.98)],
          [_o(0.5, 0.02), _o(0.5, 0.98)],
          [_o(0.02, 0.5), _o(0.98, 0.5)],
        ], w: 0.012),
      ]),
    ),
    s(
      'art_one_point',
      'art',
      _sh(1.5, [
        _ln([
          [_o(0.0, 0.45), _o(1.0, 0.45)]
        ], w: 0.025),
        _ln([
          for (final e in [_o(0.0, 0.0), _o(1.0, 0.0), _o(0.0, 1.0), _o(1.0, 1.0), _o(0.25, 1.0), _o(0.75, 1.0)]) [_o(0.5, 0.45), e],
        ], w: 0.012),
        _fl([_ci(0.5, 0.45, 0.03, aspect: 1.5)]),
      ]),
    ),
    s(
      'art_two_point',
      'art',
      _sh(2, [
        _ln([
          [_o(0.0, 0.35), _o(1.0, 0.35)]
        ], w: 0.025),
        _ln([
          [_o(0.03, 0.35), _o(0.5, 0.1)],
          [_o(0.03, 0.35), _o(0.5, 0.95)],
          [_o(0.97, 0.35), _o(0.5, 0.1)],
          [_o(0.97, 0.35), _o(0.5, 0.95)],
        ], w: 0.012),
        _ln([
          [_o(0.5, 0.1), _o(0.5, 0.95)]
        ], w: 0.03),
      ]),
    ),
    s(
      'art_proportion',
      'art',
      _sh(0.45, [
        _ln([for (var k = 0; k <= 8; k++) [_o(0.05, 0.02 + k * 0.12), _o(0.95, 0.02 + k * 0.12)]], w: 0.008),
        _ln([
          _ci(0.5, 0.08, 0.055, aspect: 0.45),
          [_o(0.5, 0.14), _o(0.5, 0.5)],
          [_o(0.18, 0.4), _o(0.5, 0.2), _o(0.82, 0.4)],
          [_o(0.3, 0.98), _o(0.5, 0.5), _o(0.7, 0.98)],
        ], w: 0.02),
      ]),
    ),
    s(
      'art_wheel',
      'art',
      _sh(1, [
        for (var k = 0; k < 12; k++)
          _fl([
            [_o(0.5, 0.5), ..._ci(0.5, 0.5, 0.46, a0: _tau * k / 12 - math.pi / 2, a1: _tau * (k + 1) / 12 - math.pi / 2, n: 6), _o(0.5, 0.5)],
          ], color: wheel[k]),
      ]),
    ),
    s(
      'art_shading',
      'art',
      _sh(1, [
        _ln([_ci(0.5, 0.5, 0.42)], w: 0.03),
        _ln([
          _el(0.5, 0.5, 0.42, 0.42, a0: -0.2, a1: math.pi * 0.8, n: 20),
          _el(0.52, 0.52, 0.3, 0.3, a0: -0.1, a1: math.pi * 0.7, n: 16),
        ], w: 0.015),
        _fl([_ci(0.36, 0.34, 0.06)], color: 0xFFFFFFFF),
        _fl([_el(0.6, 0.94, 0.3, 0.04)]),
      ]),
    ),
    s('art_palette', 'art', ic('palette')),
    s('art_brush', 'art', ic('brush')),
    s('art_picker', 'art', ic('colorize')),

    // ----------------------------------------------------------- photo / video
    s('photo_thirds', 'photo', thirds(16 / 9)),
    s(
      'photo_safe',
      'photo',
      _sh(16 / 9, [
        _ln([_rc(0.02, 0.02, 0.98, 0.98)], w: 0.03),
        _ln([_rc(0.07, 0.08, 0.93, 0.92)], w: 0.015),
        _ln([_rc(0.12, 0.14, 0.88, 0.86)], w: 0.015),
        _ln([
          [_o(0.47, 0.5), _o(0.53, 0.5)],
          [_o(0.5, 0.45), _o(0.5, 0.55)],
        ], w: 0.015),
      ]),
    ),
    s('photo_16_9', 'photo', _frame(16, 9, '16:9')),
    s('photo_9_16', 'photo', _frame(9, 16, '9:16')),
    s('photo_1_1', 'photo', _frame(1, 1, '1:1')),
    s('photo_4_3', 'photo', _frame(4, 3, '4:3')),
    s('photo_239', 'photo', _frame(2.39, 1, '2.39:1')),
    s('photo_focus', 'photo', _sh(1, [_ln(_corners(0.08, 0.08, 0.92, 0.92, 0.22), w: 0.05), _fl([_ci(0.5, 0.5, 0.04)])])),
    s(
      'photo_light',
      'photo',
      _sh(1.6, [
        _fl([_ci(0.15, 0.25, 0.12, aspect: 1.6)], color: _gold),
        ..._arrow(_o(0.28, 0.38), _o(0.92, 0.85), w: 0.05, head: 0.2, aspect: 1.6),
      ]),
    ),
    for (final (id, t) in const [('photo_els', 'ELS'), ('photo_ls', 'LS'), ('photo_ms', 'MS'), ('photo_cu', 'CU'), ('photo_ecu', 'ECU')])
      s(id, 'photo', _sh(2, [_ln([_rr(0.03, 0.1, 0.97, 0.9, 0.2, aspect: 2)], w: 0.05), _tx(t, size: 0.5)])),
    s(
      'photo_push',
      'photo',
      _sh(1.5, [
        _ln([_rc(0.02, 0.02, 0.98, 0.98)], w: 0.025),
        for (final (a, b) in const [((0.06, 0.08), (0.32, 0.36)), ((0.94, 0.08), (0.68, 0.36)), ((0.06, 0.92), (0.32, 0.64)), ((0.94, 0.92), (0.68, 0.64))])
          ..._arrow(_o(a.$1, a.$2), _o(b.$1, b.$2), w: 0.03, head: 0.12, aspect: 1.5),
      ]),
    ),
    s(
      'photo_pull',
      'photo',
      _sh(1.5, [
        _ln([_rc(0.02, 0.02, 0.98, 0.98)], w: 0.025),
        for (final (a, b) in const [((0.32, 0.36), (0.06, 0.08)), ((0.68, 0.36), (0.94, 0.08)), ((0.32, 0.64), (0.06, 0.92)), ((0.68, 0.64), (0.94, 0.92))])
          ..._arrow(_o(a.$1, a.$2), _o(b.$1, b.$2), w: 0.03, head: 0.12, aspect: 1.5),
      ]),
    ),
    s('photo_pan', 'photo', _sh(2.5, [..._curveArrow([for (var k = 0; k <= 20; k++) Offset(0.06 + 0.88 * k / 20, 0.75 - 0.4 * math.sin(math.pi * k / 20))], w: 0.06, head: 0.3, aspect: 2.5)])),
    s('photo_tilt', 'photo', _sh(0.5, [..._curveArrow([for (var k = 0; k <= 20; k++) Offset(0.3 + 0.4 * math.sin(math.pi * k / 20), 0.94 - 0.88 * k / 20)], w: 0.06, head: 0.18, aspect: 0.5)])),
    s('photo_track', 'photo', _sh(2.5, [..._arrow(_o(0.04, 0.5), _o(0.96, 0.5), w: 0.07, head: 0.32, aspect: 2.5), _ln(_dash(_o(0.04, 0.8), _o(0.96, 0.8), dashes: 10), w: 0.04)])),
    s('photo_camera', 'photo', ic('photo_camera')),
    s('photo_video', 'photo', ic('videocam')),

    // ---------------------------------------------------------- dance / stage
    s('dance_spot', 'dance', _sh(1, [_fl([_ci(0.5, 0.5, 0.44)]), _tx('1', size: 0.55, color: 0xFFFFFFFF)])),
    s(
      'dance_facing',
      'dance',
      _sh(1, [
        _ln([_ci(0.5, 0.56, 0.36)], w: 0.06),
        _fl([
          [_o(0.5, 0.04), _o(0.64, 0.24), _o(0.36, 0.24), _o(0.5, 0.04)]
        ]),
      ]),
    ),
    s('dance_path', 'dance', _sh(2.2, [_ln(_dash(_o(0.04, 0.8), _o(0.6, 0.3), dashes: 6), w: 0.05), ..._arrow(_o(0.6, 0.3), _o(0.96, 0.25), w: 0.05, head: 0.25, aspect: 2.2)])),
    s('dance_count', 'dance', _sh(4, [_tx('1 2 3 4 5 6 7 8', size: 0.5)])),
    s(
      'dance_stage',
      'dance',
      _sh(1.6, [
        _ln([
          [_o(0.02, 0.06), _o(0.98, 0.06), _o(0.98, 0.82), ..._el(0.5, 0.82, 0.48, 0.14, a0: 0, a1: math.pi, n: 24), _o(0.02, 0.06)],
        ], w: 0.03),
        _ln([
          [_o(0.46, 0.44), _o(0.54, 0.54)],
          [_o(0.54, 0.44), _o(0.46, 0.54)],
        ], w: 0.025),
        _ln([
          [_o(0.34, 0.06), _o(0.34, 0.82)],
          [_o(0.66, 0.06), _o(0.66, 0.82)],
          [_o(0.02, 0.33), _o(0.98, 0.33)],
          [_o(0.02, 0.6), _o(0.98, 0.6)],
        ], w: 0.008),
      ]),
    ),
    s('dance_center', 'dance', _sh(1, [_ln([[_o(0.15, 0.15), _o(0.85, 0.85)], [_o(0.85, 0.15), _o(0.15, 0.85)]], w: 0.1)])),
    s('dance_enter', 'dance', _sh(2, [_ln([[_o(0.06, 0.1), _o(0.06, 0.9)]], w: 0.06), ..._arrow(_o(0.12, 0.5), _o(0.94, 0.5), w: 0.07, head: 0.32, aspect: 2)])),
    s('dance_exit', 'dance', _sh(2, [_ln([[_o(0.94, 0.1), _o(0.94, 0.9)]], w: 0.06), ..._arrow(_o(0.06, 0.5), _o(0.88, 0.5), w: 0.07, head: 0.32, aspect: 2)])),
    s(
      'dance_spotlight',
      'dance',
      _sh(1, [
        _fl([
          [_o(0.42, 0.04), _o(0.58, 0.04), _o(0.94, 0.86), _o(0.06, 0.86), _o(0.42, 0.04)]
        ], color: 0x66FFEB3B),
        _ln([_el(0.5, 0.86, 0.44, 0.1)], w: 0.025),
      ]),
    ),
    s('dance_light', 'dance', ic('lightbulb', color: _gold)),
  ];
}
