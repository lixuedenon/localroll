// packages/ink/lib/src/packs/sports.dart
part of '../stamp_packs.dart';

// Tactics board, courts and fields (to scale, stretched over the picture
// as a board), fitness, golf & billiards. Drawn here or from Material
// Symbols (Apache 2.0). Names: the app's text 'stamp.<id>'.

const int _white = 0xFFFFFFFF;

/// A court: its fill [color], then white lines ([lines] in its own box).
StampShape _court(double aspect, int color, List<List<Offset>> lines, {double w = 0.012, int line = _white, List<StampPart> more = const []}) =>
    _sh(aspect, [
      _fl([_rc(0, 0, 1, 1)], color: color),
      ...more,
      _ln(lines, w: w, color: line),
    ]);

/// A player's round marker with a number.
StampShape _player(int color, String n) => _sh(1, [_fl([_ci(0.5, 0.5, 0.46)], color: color), _tx(n, size: 0.55, color: _white)]);

List<Stamp> _sportsStamps() {
  Stamp s(String id, String pack, StampShape shape) => Stamp(id: id, pack: pack, shape: shape);
  StampShape ic(String name, {int? color}) => StampPacks._ic(name, color: color);

  // Basketball, 28 × 15 m.
  const bA = 28 / 15;
  final hoopX = 1.575 / 28, arcR = 6.75 / 15, arcA = math.asin(6.6 / 6.75);
  List<List<Offset>> basketHalf(bool right) {
    double x(double v) => right ? 1 - v : v;
    final cx = hoopX, cornerX = cx + 6.75 * math.cos(arcA) / 28;
    return [
      _rc(x(0), 0.5 - 2.45 / 15, x(5.8 / 28), 0.5 + 2.45 / 15),
      [for (final p in _ci(5.8 / 28, 0.5, 1.8 / 15, a0: -math.pi / 2, a1: math.pi / 2, n: 16, aspect: bA)) Offset(x(p.dx), p.dy)],
      [Offset(x(0), 0.06), Offset(x(cornerX), 0.06)],
      [Offset(x(0), 0.94), Offset(x(cornerX), 0.94)],
      [for (final p in _ci(cx, 0.5, arcR, a0: -arcA, a1: arcA, n: 30, aspect: bA)) Offset(x(p.dx), p.dy)],
      [for (final p in _ci(cx, 0.5, 0.45 / 15, aspect: bA, n: 16)) Offset(x(p.dx), p.dy)],
    ];
  }

  // Soccer, 105 × 68 m.
  const sA = 105 / 68;
  List<List<Offset>> soccerHalf(bool right) {
    double x(double v) => right ? 1 - v : v;
    final box = 16.5 / 105, spot = 11 / 105, r = 9.15 / 68;
    final a = math.acos((16.5 - 11) / 9.15);
    return [
      _rc(x(0), 0.5 - 20.16 / 68, x(box), 0.5 + 20.16 / 68),
      _rc(x(0), 0.5 - 9.16 / 68, x(5.5 / 105), 0.5 + 9.16 / 68),
      [for (final p in _ci(spot, 0.5, r, a0: -a, a1: a, n: 16, aspect: sA)) Offset(x(p.dx), p.dy)],
      _rc(x(-0.0), 0.5 - 3.66 / 68, x(0.012), 0.5 + 3.66 / 68),
    ];
  }

  // Ice hockey, 61 × 26 m.
  const hA = 61 / 26;

  return [
    // ------------------------------------------------------------- tactics
    s('tac_red', 'tactics', _player(0xFFE53935, '1')),
    s('tac_blue', 'tactics', _player(0xFF1E88E5, '1')),
    s('tac_coach', 'tactics', _sh(1, [_ln([_ci(0.5, 0.5, 0.42)], w: 0.08), _tx('C', size: 0.5)])),
    s('tac_run', 'tactics', _sh(2.5, [..._arrow(_o(0.04, 0.5), _o(0.96, 0.5), w: 0.08, head: 0.34, aspect: 2.5)])),
    s('tac_curve', 'tactics', _sh(2, [..._curveArrow([for (var k = 0; k <= 20; k++) Offset(0.06 + 0.86 * k / 20, 0.8 - 0.6 * math.sin(math.pi * k / 20 * 0.9))], w: 0.07, head: 0.3, aspect: 2)])),
    s('tac_pass', 'tactics', _sh(2.5, [_ln(_dash(_o(0.04, 0.5), _o(0.8, 0.5), dashes: 7), w: 0.07), ..._arrow(_o(0.78, 0.5), _o(0.96, 0.5), w: 0.07, head: 0.34, aspect: 2.5)])),
    s('tac_dribble', 'tactics', _sh(2.5, [_ln([_wave(0.04, 0.78, 0.5, 0.18, 4)], w: 0.07), ..._arrow(_o(0.78, 0.5), _o(0.96, 0.5), w: 0.07, head: 0.34, aspect: 2.5)])),
    s(
      'tac_screen',
      'tactics',
      _sh(2, [
        _ln([
          [_o(0.06, 0.5), _o(0.88, 0.5)],
          [_o(0.88, 0.15), _o(0.88, 0.85)],
        ], w: 0.08),
      ]),
    ),
    s('tac_zone', 'tactics', _sh(1.4, [_fl([_el(0.5, 0.5, 0.48, 0.46)], color: 0x5542A5F5), _ln([_el(0.5, 0.5, 0.48, 0.46)], w: 0.02, color: 0xFF42A5F5)])),
    s('tac_ring', 'tactics', _sh(1, [_ln([_ci(0.5, 0.5, 0.42)], w: 0.07, color: 0xFFFFEB3B)])),
    s('tac_basketball', 'tactics', ic('sports_basketball', color: 0xFFFB8C00)),
    s('tac_soccer', 'tactics', ic('sports_soccer')),
    s('tac_whistle', 'tactics', ic('sports')),

    // ------------------------------------------------------- courts & fields
    s(
      'court_basketball',
      'fields',
      _court(bA, 0xFFD9A066, [
        _rc(0.006, 0.01, 0.994, 0.99),
        [_o(0.5, 0.01), _o(0.5, 0.99)],
        _ci(0.5, 0.5, 1.8 / 15, aspect: bA),
        ...basketHalf(false),
        ...basketHalf(true),
      ]),
    ),
    s(
      'court_soccer',
      'fields',
      _court(sA, 0xFF2E7D32, [
        _rc(0.01, 0.015, 0.99, 0.985),
        [_o(0.5, 0.015), _o(0.5, 0.985)],
        _ci(0.5, 0.5, 9.15 / 68, aspect: sA),
        ...soccerHalf(false),
        ...soccerHalf(true),
      ], more: [
        _fl([_ci(0.5, 0.5, 0.008), _ci(11 / 105, 0.5, 0.008), _ci(1 - 11 / 105, 0.5, 0.008)], color: _white),
      ]),
    ),
    s(
      'court_volleyball',
      'fields',
      _court(2, 0xFFEF8F3A, [
        _rc(0.01, 0.02, 0.99, 0.98),
        [_o(0.5, 0.0), _o(0.5, 1.0)],
        [_o(0.5 - 3 / 18, 0.02), _o(0.5 - 3 / 18, 0.98)],
        [_o(0.5 + 3 / 18, 0.02), _o(0.5 + 3 / 18, 0.98)],
      ], w: 0.016),
    ),
    s(
      'court_badminton',
      'fields',
      _court(13.4 / 6.1, 0xFF2E7D57, [
        _rc(0.005, 0.01, 0.995, 0.99),
        [_o(0.005, 0.075), _o(0.995, 0.075)],
        [_o(0.005, 0.925), _o(0.995, 0.925)],
        [_o(0.5 - 0.148, 0.01), _o(0.5 - 0.148, 0.99)],
        [_o(0.5 + 0.148, 0.01), _o(0.5 + 0.148, 0.99)],
        [_o(0.057, 0.01), _o(0.057, 0.99)],
        [_o(1 - 0.057, 0.01), _o(1 - 0.057, 0.99)],
        [_o(0.005, 0.5), _o(0.5 - 0.148, 0.5)],
        [_o(0.5 + 0.148, 0.5), _o(0.995, 0.5)],
        [_o(0.5, 0.0), _o(0.5, 1.0)],
      ], w: 0.014),
    ),
    s(
      'court_tennis',
      'fields',
      _court(23.77 / 10.97, 0xFF1565C0, [
        _rc(0.005, 0.01, 0.995, 0.99),
        [_o(0.005, 0.125), _o(0.995, 0.125)],
        [_o(0.005, 0.875), _o(0.995, 0.875)],
        [_o(0.5 - 0.269, 0.125), _o(0.5 - 0.269, 0.875)],
        [_o(0.5 + 0.269, 0.125), _o(0.5 + 0.269, 0.875)],
        [_o(0.5 - 0.269, 0.5), _o(0.5 + 0.269, 0.5)],
        [_o(0.5, 0.0), _o(0.5, 1.0)],
      ], w: 0.014),
    ),
    s(
      'court_tabletennis',
      'fields',
      _court(2.74 / 1.525, 0xFF0D47A1, [
        _rc(0.01, 0.02, 0.99, 0.98),
        [_o(0.01, 0.5), _o(0.99, 0.5)],
        [_o(0.5, 0.0), _o(0.5, 1.0)],
      ], w: 0.02),
    ),
    s(
      'court_baseball',
      'fields',
      _sh(1, [
        _fl([
          [_o(0.5, 0.95), _o(0.02, 0.47), ..._ci(0.5, 0.95, 0.68, a0: math.pi * 1.25, a1: math.pi * 1.75, n: 24), _o(0.98, 0.47), _o(0.5, 0.95)],
        ], color: 0xFF2E7D32),
        _fl([
          [_o(0.5, 0.95), _o(0.27, 0.72), _o(0.5, 0.49), _o(0.73, 0.72), _o(0.5, 0.95)],
        ], color: 0xFFB9855A),
        _fl([
          [_o(0.5, 0.88), _o(0.34, 0.72), _o(0.5, 0.56), _o(0.66, 0.72), _o(0.5, 0.88)],
        ], color: 0xFF388E3C),
        _fl([_ci(0.5, 0.72, 0.035), _rc(0.48, 0.93, 0.52, 0.96), _rc(0.26, 0.7, 0.29, 0.73), _rc(0.485, 0.475, 0.515, 0.505), _rc(0.71, 0.7, 0.74, 0.73)], color: _white),
        _ln([
          [_o(0.02, 0.47), _o(0.5, 0.95), _o(0.98, 0.47)],
        ], w: 0.01, color: _white),
      ]),
    ),
    s(
      'court_football',
      'fields',
      _court(120 / 53.3, 0xFF2E7D32, [
        _rc(0.005, 0.01, 0.995, 0.99),
        for (var k = 1; k <= 11; k++) [_o(k / 12, 0.01), _o(k / 12, 0.99)],
      ], more: [
        _fl([_rc(0.005, 0.01, 1 / 12, 0.99), _rc(11 / 12, 0.01, 0.995, 0.99)], color: 0xFF1B5E20),
      ], w: 0.01),
    ),
    s(
      'court_hockey',
      'fields',
      _sh(hA, [
        _fl([_rr(0, 0, 1, 1, 8.5 / 26, aspect: hA)], color: 0xFFF2F6F9),
        _ln([_rr(0.003, 0.008, 0.997, 0.992, 8.5 / 26, aspect: hA)], w: 0.012, color: 0xFF37474F),
        _ln([
          [_o(0.5, 0.01), _o(0.5, 0.99)],
          [_o(4 / 61, 0.06), _o(4 / 61, 0.94)],
          [_o(1 - 4 / 61, 0.06), _o(1 - 4 / 61, 0.94)],
          _ci(0.5, 0.5, 4.5 / 26, aspect: hA),
          for (final cx in [10 / 61, 1 - 10 / 61]) for (final cy in [0.27, 0.73]) _ci(cx, cy, 4.5 / 26, aspect: hA),
        ], w: 0.012, color: 0xFFE53935),
        _ln([
          [_o(0.5 - 7.62 / 61, 0.01), _o(0.5 - 7.62 / 61, 0.99)],
          [_o(0.5 + 7.62 / 61, 0.01), _o(0.5 + 7.62 / 61, 0.99)],
        ], w: 0.02, color: 0xFF1E88E5),
      ]),
    ),
    s(
      'court_pool',
      'fields',
      _sh(2, [
        _fl([_rc(0, 0, 1, 1)], color: 0xFF29B6F6),
        _ln([_rc(0.005, 0.01, 0.995, 0.99)], w: 0.02, color: _white),
        _ln([for (var k = 1; k < 8; k++) ..._dash(_o(0.02, k / 8), _o(0.98, k / 8), dashes: 20)], w: 0.012, color: _white),
        _ln([for (var k = 0; k < 8; k++) [_o(0.06, (k + 0.5) / 8), _o(0.94, (k + 0.5) / 8)]], w: 0.008, color: 0xFF0D47A1),
      ]),
    ),

    // ------------------------------------------------------------- fitness
    s('fit_dumbbell', 'fitness', ic('fitness_center')),
    s('fit_timer', 'fitness', ic('timer')),
    s('fit_run', 'fitness', ic('directions_run')),
    s('fit_sprint', 'fitness', ic('sprint')),
    s('fit_stretch', 'fitness', ic('self_improvement')),
    s('fit_body', 'fitness', ic('accessibility_new')),
    s('fit_sets', 'fitness', _sh(2, [_ln([_rr(0.03, 0.1, 0.97, 0.9, 0.25, aspect: 2)], w: 0.06), _tx('3 × 12', size: 0.48)])),
    s('fit_rotate', 'fitness', _sh(1, [..._curveArrow(_ci(0.5, 0.5, 0.38, a0: -math.pi * 0.4, a1: math.pi * 1.3, n: 30), w: 0.07, head: 0.26)])),
    s('fit_up', 'fitness', _sh(0.6, [..._arrow(_o(0.5, 0.94), _o(0.5, 0.06), w: 0.12, head: 0.3, aspect: 0.6)])),

    // ------------------------------------------------------ golf & billiards
    s('golf_flag', 'golf', ic('golf_course')),
    s(
      'golf_shot',
      'golf',
      _sh(2.4, [
        _ln([for (final d in _dash(_o(0, 0), _o(1, 0), dashes: 12)) [for (final p in d) Offset(0.06 + 0.86 * p.dx, 0.85 - 0.75 * math.sin(math.pi * p.dx))]], w: 0.05),
        _fl([_ci(0.06, 0.85, 0.06, aspect: 2.4)], color: _white),
        _ln([_ci(0.06, 0.85, 0.06, aspect: 2.4)], w: 0.02),
      ]),
    ),
    s(
      'golf_table',
      'golf',
      _sh(2, [
        _fl([_rr(0, 0, 1, 1, 0.12, aspect: 2)], color: 0xFF5D4037),
        _fl([_rc(0.05, 0.1, 0.95, 0.9)], color: 0xFF2E7D32),
        _fl([for (final x in [0.05, 0.5, 0.95]) for (final y in [0.1, 0.9]) _ci(x, y, 0.06, aspect: 2)], color: 0xFF111111),
        _ln([
          [_o(0.27, 0.1), _o(0.27, 0.9)]
        ], w: 0.008, color: _white),
      ]),
    ),
    s(
      'golf_aim',
      'golf',
      _sh(2.4, [
        _ln(_dash(_o(0.12, 0.5), _o(0.82, 0.5), dashes: 9), w: 0.04),
        _fl([_ci(0.08, 0.5, 0.1, aspect: 2.4)], color: _white),
        _ln([_ci(0.08, 0.5, 0.1, aspect: 2.4), _ci(0.9, 0.5, 0.1, aspect: 2.4)], w: 0.03),
      ]),
    ),
    s('golf_ball', 'golf', _sh(1, [_fl([_ci(0.5, 0.5, 0.42)], color: _white), _ln([_ci(0.5, 0.5, 0.42)], w: 0.04)])),
  ];
}
