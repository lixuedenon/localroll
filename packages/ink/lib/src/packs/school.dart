// packages/ink/lib/src/packs/school.dart
part of '../stamp_packs.dart';

// Kids and school subjects. Drawn here (simple lines) or from Material
// Symbols (Apache 2.0). Names: the app's text 'stamp.<id>'.

const int _red = 0xFFE53935, _gold = 0xFFFFB300, _green = 0xFF43A047, _blue = 0xFF1E88E5, _pink = 0xFFEC407A;

/// 田 grid / 米 grid / 9 grid (writing practice).
StampShape _writingGrid({bool diagonals = false, bool nine = false}) => _sh(1, [
      _ln([_rc(0.04, 0.04, 0.96, 0.96)], w: 0.04),
      if (nine)
        _ln([
          [_o(0.347, 0.04), _o(0.347, 0.96)],
          [_o(0.653, 0.04), _o(0.653, 0.96)],
          [_o(0.04, 0.347), _o(0.96, 0.347)],
          [_o(0.04, 0.653), _o(0.96, 0.653)],
        ], w: 0.015)
      else
        _ln([
          ..._dash(_o(0.5, 0.04), _o(0.5, 0.96), dashes: 10),
          ..._dash(_o(0.04, 0.5), _o(0.96, 0.5), dashes: 10),
          if (diagonals) ..._dash(_o(0.04, 0.04), _o(0.96, 0.96), dashes: 12),
          if (diagonals) ..._dash(_o(0.96, 0.04), _o(0.04, 0.96), dashes: 12),
        ], w: 0.015),
    ]);

List<Stamp> _schoolStamps() {
  Stamp s(String id, String pack, StampShape shape) => Stamp(id: id, pack: pack, shape: shape);
  StampShape ic(String name, {int? color}) => StampPacks._ic(name, color: color);
  // A word in a circle (circuit meters).
  StampShape inCircle(String t) => _sh(1, [_ln([_ci(0.5, 0.5, 0.4)], w: 0.06), _tx(t, size: 0.42)]);
  return [
    // ---------------------------------------------------------------- kids
    s('kids_flower', 'kids', ic('local_florist', color: _red)),
    s('kids_star', 'kids', ic('star', color: _gold)),
    s('kids_medal', 'kids', ic('military_tech', color: _gold)),
    s('kids_award', 'kids', ic('workspace_premium', color: _gold)),
    s('kids_crown', 'kids', ic('crown', color: _gold)),
    s('kids_happy', 'kids', ic('sentiment_very_satisfied', color: _gold)),
    s('kids_party', 'kids', ic('celebration', color: _pink)),
    s('kids_heart', 'kids', ic('favorite', color: _pink)),
    s('kids_paw', 'kids', ic('pets')),
    s('kids_rabbit', 'kids', ic('cruelty_free')),
    s('kids_apple', 'kids', ic('nutrition', color: _red)),
    s('kids_leaf', 'kids', ic('eco', color: _green)),
    s('kids_toy', 'kids', ic('toys')),
    s('kids_tian', 'kids', _writingGrid()),
    s(
      'kids_pinyin',
      'kids',
      _sh(3, [
        _ln([
          [_o(0.02, 0.1), _o(0.98, 0.1)],
          [_o(0.02, 0.9), _o(0.98, 0.9)],
        ], w: 0.04),
        _ln([
          [_o(0.02, 0.37), _o(0.98, 0.37)],
          [_o(0.02, 0.63), _o(0.98, 0.63)],
        ], w: 0.03, color: _red),
      ]),
    ),

    // ---------------------------------------------------------------- math
    s('math_axes', 'math', _sh(1, [..._axes(0.08, 0.06, 0.94, 0.92), _tx('x', x: 0.9, y: 0.82, size: 0.14), _tx('y', x: 0.16, y: 0.1, size: 0.14)])),
    s(
      'math_plane',
      'math',
      _sh(1, [
        _ln(_grid(0.06, 0.06, 0.94, 0.94, 8, 8), w: 0.008),
        ..._arrow(_o(0.02, 0.5), _o(0.98, 0.5), w: 0.03, head: 0.09),
        ..._arrow(_o(0.5, 0.98), _o(0.5, 0.02), w: 0.03, head: 0.09),
      ]),
    ),
    s('math_grid', 'math', _sh(1, [_ln(_grid(0.04, 0.04, 0.96, 0.96, 10, 10), w: 0.012)])),
    s(
      'math_numberline',
      'math',
      _sh(4, [
        ..._arrow(_o(0.02, 0.55), _o(0.98, 0.55), w: 0.06, head: 0.28, aspect: 4),
        _ln([
          for (var k = 0; k <= 8; k++) [_o(0.08 + k * 0.1, 0.4), _o(0.08 + k * 0.1, 0.7)],
        ], w: 0.05),
        _tx('0', x: 0.48, y: 0.2, size: 0.3),
      ]),
    ),
    s(
      'math_ruler',
      'math',
      _sh(5, [
        _ln([_rc(0.01, 0.1, 0.99, 0.9)], w: 0.06),
        _ln([
          for (var k = 1; k < 20; k++) [_o(0.01 + k * 0.049, 0.1), _o(0.01 + k * 0.049, k.isEven ? 0.55 : 0.35)],
        ], w: 0.04),
      ]),
    ),
    s(
      'math_protractor',
      'math',
      _sh(2, [
        _ln([
          [..._ci(0.5, 0.92, 0.86, a0: math.pi, a1: _tau, aspect: 2), _o(0.07, 0.92)],
        ], w: 0.04),
        _ln([
          for (var k = 1; k < 18; k++)
            [
              Offset(0.5 + 0.43 * math.cos(math.pi + math.pi * k / 18), 0.92 + 0.86 * math.sin(math.pi + math.pi * k / 18)),
              Offset(0.5 + (k % 9 == 0 ? 0.32 : 0.38) * math.cos(math.pi + math.pi * k / 18), 0.92 + (k % 9 == 0 ? 0.64 : 0.76) * math.sin(math.pi + math.pi * k / 18)),
            ],
        ], w: 0.025),
        _fl([_ci(0.5, 0.92, 0.04, aspect: 2)]),
      ]),
    ),
    s(
      'math_compass',
      'math',
      _sh(1, [
        _ln([_ci(0.5, 0.5, 0.42)], w: 0.04),
        _fl([_ci(0.5, 0.5, 0.04)]),
        _ln([
          [_o(0.5, 0.5), _o(0.86, 0.29)],
        ], w: 0.025),
        _tx('r', x: 0.66, y: 0.33, size: 0.16),
      ]),
    ),
    s(
      'math_angle',
      'math',
      _sh(1, [
        _ln([
          [_o(0.92, 0.12), _o(0.08, 0.88), _o(0.95, 0.88)],
        ], w: 0.05),
        _ln([_ci(0.08, 0.88, 0.32, a0: -0.74, a1: 0, n: 16)], w: 0.035),
        _tx('α', x: 0.5, y: 0.76, size: 0.18),
      ]),
    ),
    s(
      'math_right',
      'math',
      _sh(1, [
        _ln([
          [_o(0.1, 0.06), _o(0.1, 0.9), _o(0.94, 0.9)],
        ], w: 0.06),
        _ln([
          [_o(0.1, 0.66), _o(0.34, 0.66), _o(0.34, 0.9)],
        ], w: 0.04),
      ]),
    ),
    s('math_parallel', 'math', _sh(1, [_tx('∥', size: 0.8)])),
    s('math_perp', 'math', _sh(1, [_tx('⊥', size: 0.8)])),
    s('math_congruent', 'math', _sh(1, [_tx('≅', size: 0.8)])),
    s('math_similar', 'math', _sh(1, [_tx('∽', size: 0.8)])),
    s('math_parabola', 'math', _sh(1, [..._axes(0.06, 0.06, 0.94, 0.94), _ln([_curve((x) => 3.6 * (x - 0.5) * (x - 0.5) + 0.06, 0.12, 0.08, 0.94, 0.9)], w: 0.045)])),
    s('math_sine', 'math', _sh(2, [..._axes(0.03, 0.04, 0.97, 0.96, aspect: 2), _ln([_curve((x) => 0.5 + 0.42 * math.sin(_tau * 1.5 * x), 0.05, 0.04, 0.95, 0.96)], w: 0.045)])),
    s('math_exp', 'math', _sh(1, [..._axes(0.06, 0.06, 0.94, 0.94), _ln([_curve((x) => (math.exp(3 * x) - 1) / (math.exp(3) - 1), 0.08, 0.1, 0.92, 0.9)], w: 0.045)])),
    s(
      'math_cube',
      'math',
      _sh(1, [
        _ln([
          _rc(0.08, 0.3, 0.7, 0.92),
          [_o(0.08, 0.3), _o(0.3, 0.08), _o(0.92, 0.08), _o(0.7, 0.3)],
          [_o(0.92, 0.08), _o(0.92, 0.7), _o(0.7, 0.92)],
        ], w: 0.04),
        _ln([
          ..._dash(_o(0.3, 0.08), _o(0.3, 0.7), dashes: 6),
          ..._dash(_o(0.3, 0.7), _o(0.92, 0.7), dashes: 6),
          ..._dash(_o(0.3, 0.7), _o(0.08, 0.92), dashes: 3),
        ], w: 0.025),
      ]),
    ),
    s(
      'math_cylinder',
      'math',
      _sh(0.8, [
        _ln([
          _el(0.5, 0.15, 0.4, 0.1),
          [_o(0.1, 0.15), _o(0.1, 0.85)],
          [_o(0.9, 0.15), _o(0.9, 0.85)],
          _el(0.5, 0.85, 0.4, 0.1, a0: 0, a1: math.pi, n: 24),
        ], w: 0.04),
        _ln([
          for (var k = 0; k < 8; k++) _el(0.5, 0.85, 0.4, 0.1, a0: math.pi + math.pi * k / 8, a1: math.pi + math.pi * (k + 0.55) / 8, n: 3),
        ], w: 0.025),
      ]),
    ),
    s(
      'math_cone',
      'math',
      _sh(0.8, [
        _ln([
          [_o(0.1, 0.85), _o(0.5, 0.06), _o(0.9, 0.85)],
          _el(0.5, 0.85, 0.4, 0.1, a0: 0, a1: math.pi, n: 24),
        ], w: 0.04),
        _ln([
          for (var k = 0; k < 8; k++) _el(0.5, 0.85, 0.4, 0.1, a0: math.pi + math.pi * k / 8, a1: math.pi + math.pi * (k + 0.55) / 8, n: 3),
        ], w: 0.025),
      ]),
    ),
    s(
      'math_sphere',
      'math',
      _sh(1, [
        _ln([_ci(0.5, 0.5, 0.44)], w: 0.04),
        _ln([_el(0.5, 0.5, 0.44, 0.13, a0: 0, a1: math.pi, n: 24)], w: 0.03),
        _ln([
          for (var k = 0; k < 8; k++) _el(0.5, 0.5, 0.44, 0.13, a0: math.pi + math.pi * k / 8, a1: math.pi + math.pi * (k + 0.55) / 8, n: 3),
        ], w: 0.02),
      ]),
    ),
    s('math_venn', 'math', _sh(1.5, [_ln([_ci(0.38, 0.5, 0.38, aspect: 1.5), _ci(0.62, 0.5, 0.38, aspect: 1.5)], w: 0.04), _tx('A', x: 0.25, size: 0.2), _tx('B', x: 0.75, size: 0.2)])),
    s(
      'math_fraction',
      'math',
      _sh(1, [
        _fl([
          [_o(0.5, 0.5), ..._ci(0.5, 0.5, 0.42, a0: -math.pi / 2, a1: 0, n: 16), _o(0.5, 0.5)],
        ]),
        _ln([
          _ci(0.5, 0.5, 0.42),
          [_o(0.5, 0.08), _o(0.5, 0.92)],
          [_o(0.08, 0.5), _o(0.92, 0.5)],
        ], w: 0.035),
      ]),
    ),

    // ------------------------------------------------------------- physics
    s('phys_force', 'physics', _sh(2, [..._arrow(_o(0.06, 0.6), _o(0.94, 0.6), w: 0.09, head: 0.36, aspect: 2), _tx('F', x: 0.5, y: 0.22, size: 0.34)])),
    s('phys_velocity', 'physics', _sh(2, [..._arrow(_o(0.06, 0.6), _o(0.94, 0.6), w: 0.07, head: 0.32, aspect: 2), _tx('v', x: 0.5, y: 0.22, size: 0.34)])),
    s('phys_accel', 'physics', _sh(2, [..._arrow(_o(0.06, 0.6), _o(0.94, 0.6), w: 0.07, head: 0.32, aspect: 2), _tx('a', x: 0.5, y: 0.22, size: 0.34)])),
    s(
      'phys_battery',
      'physics',
      _sh(2, [
        _ln([
          [_o(0.02, 0.5), _o(0.44, 0.5)],
          [_o(0.56, 0.5), _o(0.98, 0.5)],
        ], w: 0.05),
        _ln([
          [_o(0.44, 0.12), _o(0.44, 0.88)]
        ], w: 0.05),
        _ln([
          [_o(0.56, 0.3), _o(0.56, 0.7)]
        ], w: 0.12),
      ]),
    ),
    s('phys_resistor', 'physics', _sh(2.5, [_ln([_rc(0.25, 0.3, 0.75, 0.7), [_o(0.02, 0.5), _o(0.25, 0.5)], [_o(0.75, 0.5), _o(0.98, 0.5)]], w: 0.06)])),
    s(
      'phys_switch',
      'physics',
      _sh(2.5, [
        _ln([
          [_o(0.02, 0.7), _o(0.3, 0.7)],
          [_o(0.3, 0.7), _o(0.66, 0.25)],
          [_o(0.7, 0.7), _o(0.98, 0.7)],
        ], w: 0.06),
        _fl([_ci(0.3, 0.7, 0.07, aspect: 2.5), _ci(0.7, 0.7, 0.07, aspect: 2.5)]),
      ]),
    ),
    s(
      'phys_lamp',
      'physics',
      _sh(1, [
        _ln([
          _ci(0.5, 0.5, 0.36),
          [_o(0.25, 0.25), _o(0.75, 0.75)],
          [_o(0.75, 0.25), _o(0.25, 0.75)],
        ], w: 0.05),
      ]),
    ),
    s('phys_ammeter', 'physics', inCircle('A')),
    s('phys_voltmeter', 'physics', inCircle('V')),
    s(
      'phys_capacitor',
      'physics',
      _sh(2, [
        _ln([
          [_o(0.02, 0.5), _o(0.44, 0.5)],
          [_o(0.56, 0.5), _o(0.98, 0.5)],
          [_o(0.44, 0.15), _o(0.44, 0.85)],
          [_o(0.56, 0.15), _o(0.56, 0.85)],
        ], w: 0.06),
      ]),
    ),
    s(
      'phys_diode',
      'physics',
      _sh(2, [
        _ln([
          [_o(0.02, 0.5), _o(0.98, 0.5)],
          [_o(0.64, 0.18), _o(0.64, 0.82)],
        ], w: 0.06),
        _fl([
          [_o(0.38, 0.18), _o(0.64, 0.5), _o(0.38, 0.82), _o(0.38, 0.18)],
        ]),
      ]),
    ),
    s(
      'phys_ground',
      'physics',
      _sh(1, [
        _ln([
          [_o(0.5, 0.06), _o(0.5, 0.5)],
          [_o(0.14, 0.5), _o(0.86, 0.5)],
          [_o(0.26, 0.66), _o(0.74, 0.66)],
          [_o(0.38, 0.82), _o(0.62, 0.82)],
        ], w: 0.06),
      ]),
    ),
    s(
      'phys_magnet',
      'physics',
      _sh(2.5, [
        _fl([_rc(0.1, 0.25, 0.5, 0.75)], color: _red),
        _fl([_rc(0.5, 0.25, 0.9, 0.75)], color: _blue),
        _tx('N', x: 0.3, size: 0.38, color: 0xFFFFFFFF),
        _tx('S', x: 0.7, size: 0.38, color: 0xFFFFFFFF),
      ]),
    ),
    s(
      'phys_field',
      'physics',
      _sh(2, [
        _ln([
          for (final ry in [0.18, 0.32, 0.46]) _el(0.5, 0.5, 0.46, ry, a0: math.pi * 1.1, a1: math.pi * 1.9, n: 24),
          for (final ry in [0.18, 0.32, 0.46]) _el(0.5, 0.5, 0.46, ry, a0: math.pi * 0.1, a1: math.pi * 0.9, n: 24),
        ], w: 0.03),
      ]),
    ),
    s('phys_ray', 'physics', _sh(2, [..._arrow(_o(0.04, 0.85), _o(0.96, 0.15), w: 0.04, head: 0.24, aspect: 2)])),
    s(
      'phys_lens',
      'physics',
      _sh(0.6, [
        _ln([
          [..._el(0.0, 0.5, 0.95, 0.46, a0: -0.55, a1: 0.55, n: 16), ..._el(1.0, 0.5, 0.95, 0.46, a0: math.pi - 0.55, a1: math.pi + 0.55, n: 16)],
        ], w: 0.035),
      ]),
    ),
    s(
      'phys_mirror',
      'physics',
      _sh(0.5, [
        _ln([
          [_o(0.4, 0.04), _o(0.4, 0.96)]
        ], w: 0.04),
        _ln([
          for (var k = 0; k < 9; k++) [_o(0.42, 0.06 + k * 0.11), _o(0.82, 0.14 + k * 0.11)],
        ], w: 0.02),
      ]),
    ),
    s('phys_spring', 'physics', _sh(3, [_ln([_zig(_o(0.02, 0.5), _o(0.98, 0.5), 12, 0.32, aspect: 3)], w: 0.06)])),
    s(
      'phys_pulley',
      'physics',
      _sh(0.8, [
        _ln([
          _ci(0.5, 0.25, 0.2, aspect: 0.8),
          [_o(0.5, 0.0), _o(0.5, 0.25)],
          [_o(0.25, 0.25), _o(0.25, 0.9)],
          [_o(0.75, 0.25), _o(0.75, 0.7)],
        ], w: 0.03),
        _fl([_rc(0.62, 0.7, 0.88, 0.95)]),
      ]),
    ),
    s(
      'phys_incline',
      'physics',
      _sh(1.6, [
        _ln([
          [_o(0.04, 0.92), _o(0.96, 0.92), _o(0.96, 0.18), _o(0.04, 0.92)],
        ], w: 0.04),
        _fl([
          [_o(0.42, 0.62), _o(0.62, 0.46), _o(0.71, 0.58), _o(0.51, 0.74), _o(0.42, 0.62)],
        ]),
      ]),
    ),

    // ----------------------------------------------------------- chemistry
    s(
      'chem_benzene',
      'chem',
      _sh(1, [
        _ln([
          [for (var k = 0; k <= 6; k++) Offset(0.5 + 0.44 * math.cos(-math.pi / 2 + k * math.pi / 3), 0.5 + 0.44 * math.sin(-math.pi / 2 + k * math.pi / 3))],
          _ci(0.5, 0.5, 0.24),
        ], w: 0.04),
      ]),
    ),
    s('chem_single', 'chem', _sh(2, [_ln([[_o(0.08, 0.5), _o(0.92, 0.5)]], w: 0.08)])),
    s('chem_double', 'chem', _sh(2, [_ln([[_o(0.08, 0.36), _o(0.92, 0.36)], [_o(0.08, 0.64), _o(0.92, 0.64)]], w: 0.08)])),
    s('chem_triple', 'chem', _sh(2, [_ln([[_o(0.08, 0.24), _o(0.92, 0.24)], [_o(0.08, 0.5), _o(0.92, 0.5)], [_o(0.08, 0.76), _o(0.92, 0.76)]], w: 0.08)])),
    s(
      'chem_atom',
      'chem',
      _sh(1, [
        _fl([_ci(0.5, 0.5, 0.09)]),
        _ln([_ci(0.5, 0.5, 0.25), _ci(0.5, 0.5, 0.43)], w: 0.025),
        _fl([_ci(0.75, 0.5, 0.04), _ci(0.5, 0.07, 0.04), _ci(0.12, 0.68, 0.04)]),
      ]),
    ),
    s(
      'chem_tube',
      'chem',
      _sh(0.4, [
        _ln([
          [_o(0.15, 0.04), ..._el(0.5, 0.82, 0.35, 0.14, a0: math.pi, a1: 0, n: 16), _o(0.85, 0.04)],
        ], w: 0.025),
        _fl([
          [_o(0.15, 0.55), ..._el(0.5, 0.82, 0.35, 0.14, a0: math.pi, a1: 0, n: 16), _o(0.85, 0.55), _o(0.15, 0.55)],
        ], color: _blue),
      ]),
    ),
    s(
      'chem_beaker',
      'chem',
      _sh(0.9, [
        _ln([
          [_o(0.06, 0.06), _o(0.14, 0.12), _o(0.14, 0.94), _o(0.86, 0.94), _o(0.86, 0.06)],
        ], w: 0.04),
        _fl([_rc(0.16, 0.55, 0.84, 0.92)], color: _blue),
        _ln([
          for (var k = 0; k < 3; k++) [_o(0.64, 0.3 + k * 0.12), _o(0.84, 0.3 + k * 0.12)],
        ], w: 0.02),
      ]),
    ),
    s(
      'chem_flask',
      'chem',
      _sh(0.9, [
        _ln([
          [_o(0.38, 0.04), _o(0.38, 0.38), _o(0.06, 0.94), _o(0.94, 0.94), _o(0.62, 0.38), _o(0.62, 0.04)],
        ], w: 0.04),
        _fl([
          [_o(0.23, 0.64), _o(0.77, 0.64), _o(0.92, 0.92), _o(0.08, 0.92), _o(0.23, 0.64)],
        ], color: _green),
      ]),
    ),
    s(
      'chem_burner',
      'chem',
      _sh(0.8, [
        _fl([
          [_o(0.5, 0.06), ..._el(0.5, 0.36, 0.14, 0.18, a0: -math.pi / 2 + 0.4, a1: math.pi * 1.5 - 0.4, n: 20), _o(0.5, 0.06)],
        ], color: 0xFFFF8F00),
        _ln([
          [_o(0.44, 0.52), _o(0.44, 0.6)],
          [_o(0.56, 0.52), _o(0.56, 0.6)],
          [..._el(0.5, 0.78, 0.36, 0.2, a0: math.pi, a1: _tau, n: 20)],
          [_o(0.14, 0.78), _o(0.14, 0.95), _o(0.86, 0.95), _o(0.86, 0.78)],
        ], w: 0.035),
      ]),
    ),
    s(
      'chem_reversible',
      'chem',
      _sh(2.5, [
        _ln([
          [_o(0.06, 0.38), _o(0.94, 0.38), _o(0.8, 0.18)],
          [_o(0.94, 0.62), _o(0.06, 0.62), _o(0.2, 0.82)],
        ], w: 0.06),
      ]),
    ),
    s('chem_heat', 'chem', _sh(2.5, [..._arrow(_o(0.04, 0.72), _o(0.96, 0.72), w: 0.06, head: 0.3, aspect: 2.5), _tx('△', y: 0.3, size: 0.4)])),
    s(
      'chem_element',
      'chem',
      _sh(1, [
        _ln([_rc(0.06, 0.06, 0.94, 0.94)], w: 0.04),
        _tx('1', x: 0.22, y: 0.2, size: 0.18),
        _tx('H', y: 0.54, size: 0.48),
        _tx('1.008', y: 0.86, size: 0.14),
      ]),
    ),
    s('chem_dots', 'chem', _sh(1, [_fl([_ci(0.5, 0.14, 0.06), _ci(0.5, 0.86, 0.06), _ci(0.14, 0.5, 0.06), _ci(0.86, 0.5, 0.06)]), _tx('O', size: 0.5)])),
    s('chem_lab', 'chem', ic('science')),

    // ------------------------------------------------------------- biology
    s(
      'bio_animal_cell',
      'bio',
      _sh(1.3, [
        _ln([_el(0.5, 0.5, 0.46, 0.42)], w: 0.035),
        _fl([_el(0.46, 0.48, 0.13, 0.15)]),
        _fl([_el(0.75, 0.38, 0.03, 0.04), _el(0.3, 0.7, 0.03, 0.04), _el(0.68, 0.72, 0.03, 0.04), _el(0.24, 0.32, 0.03, 0.04)]),
      ]),
    ),
    s(
      'bio_plant_cell',
      'bio',
      _sh(1.3, [
        _ln([_rr(0.04, 0.06, 0.96, 0.94, 0.1, aspect: 1.3)], w: 0.045),
        _ln([_rr(0.09, 0.13, 0.91, 0.87, 0.08, aspect: 1.3)], w: 0.02),
        _ln([_el(0.6, 0.5, 0.22, 0.26)], w: 0.02),
        _fl([_el(0.26, 0.4, 0.09, 0.12)]),
        _fl([_el(0.22, 0.74, 0.04, 0.05), _el(0.84, 0.22, 0.04, 0.05)], color: _green),
      ]),
    ),
    s(
      'bio_dna',
      'bio',
      _sh(0.6, [
        _ln([
          [for (var k = 0; k <= 48; k++) Offset(0.5 + 0.42 * math.sin(_tau * 1.5 * k / 48), k / 48)],
          [for (var k = 0; k <= 48; k++) Offset(0.5 - 0.42 * math.sin(_tau * 1.5 * k / 48), k / 48)],
        ], w: 0.04),
        _ln([
          for (var k = 1; k < 12; k++)
            [Offset(0.5 + 0.42 * math.sin(_tau * 1.5 * k / 12), k / 12), Offset(0.5 - 0.42 * math.sin(_tau * 1.5 * k / 12), k / 12)],
        ], w: 0.02),
      ]),
    ),
    s('bio_heart', 'bio', ic('cardiology', color: _red)),
    s('bio_lungs', 'bio', ic('pulmonology')),
    s('bio_brain', 'bio', ic('neurology')),
    s('bio_genetics', 'bio', ic('genetics')),
    s('bio_microbe', 'bio', ic('microbiology')),
    s('bio_skeleton', 'bio', ic('skeleton')),
    s('bio_leaf', 'bio', ic('nest_eco_leaf', color: _green)),
    s('bio_chain', 'bio', _sh(3, [..._arrow(_o(0.04, 0.5), _o(0.46, 0.5), w: 0.07, head: 0.3, aspect: 3), ..._arrow(_o(0.54, 0.5), _o(0.96, 0.5), w: 0.07, head: 0.3, aspect: 3)])),
    s(
      'bio_microscope_view',
      'bio',
      _sh(1, [
        _ln([_ci(0.5, 0.5, 0.45)], w: 0.05),
        _ln([
          [_o(0.5, 0.1), _o(0.5, 0.9)],
          [_o(0.1, 0.5), _o(0.9, 0.5)],
        ], w: 0.012),
      ]),
    ),
    s('bio_lab', 'bio', ic('biotech')),

    // ----------------------------------------------------------- geography
    s(
      'geo_north',
      'geo',
      _sh(0.7, [
        _fl([
          [_o(0.5, 0.2), _o(0.8, 0.95), _o(0.5, 0.78), _o(0.2, 0.95), _o(0.5, 0.2)],
        ]),
        _tx('N', y: 0.09, size: 0.18),
      ]),
    ),
    s(
      'geo_scale',
      'geo',
      _sh(4, [
        _fl([_rc(0.04, 0.5, 0.28, 0.66), _rc(0.52, 0.5, 0.76, 0.66)]),
        _ln([_rc(0.04, 0.5, 0.96, 0.66)], w: 0.05),
        _tx('0', x: 0.04, y: 0.24, size: 0.3),
        _tx('1 km', x: 0.92, y: 0.24, size: 0.3),
      ]),
    ),
    s(
      'geo_globe_grid',
      'geo',
      _sh(1, [
        _ln([
          _ci(0.5, 0.5, 0.44),
          for (final dy in [-0.24, 0.24]) [Offset(0.5 - math.sqrt(0.44 * 0.44 - dy * dy), 0.5 + dy), Offset(0.5 + math.sqrt(0.44 * 0.44 - dy * dy), 0.5 + dy)],
          for (final rx in [0.15, 0.3]) _el(0.5, 0.5, rx, 0.44),
          [_o(0.06, 0.5), _o(0.94, 0.5)],
          [_o(0.5, 0.06), _o(0.5, 0.94)],
        ], w: 0.025),
      ]),
    ),
    s('geo_mountain', 'geo', _sh(1.4, [_fl([[_o(0.04, 0.9), _o(0.38, 0.2), _o(0.56, 0.52), _o(0.7, 0.36), _o(0.96, 0.9), _o(0.04, 0.9)]])])),
    s('geo_river', 'geo', _sh(3, [_ln([_wave(0.02, 0.98, 0.5, 0.25, 1.5)], w: 0.08, color: _blue)])),
    s('geo_lake', 'geo', _sh(1.4, [_fl([_el(0.5, 0.5, 0.44, 0.34)], color: _blue)])),
    s('geo_city', 'geo', _sh(1, [_ln([_ci(0.5, 0.5, 0.34)], w: 0.08), _fl([_ci(0.5, 0.5, 0.14)])])),
    s(
      'geo_railway',
      'geo',
      _sh(4, [
        _ln([
          [_o(0.02, 0.5), _o(0.98, 0.5)]
        ], w: 0.12),
        _ln([
          for (var k = 0; k < 10; k++) [_o(0.06 + k * 0.1, 0.25), _o(0.06 + k * 0.1, 0.75)],
        ], w: 0.06),
      ]),
    ),
    s('geo_road', 'geo', _sh(4, [_ln([[_o(0.02, 0.3), _o(0.98, 0.3)], [_o(0.02, 0.7), _o(0.98, 0.7)]], w: 0.08), _ln(_dash(_o(0.02, 0.5), _o(0.98, 0.5), dashes: 10), w: 0.05, color: _gold)])),
    s(
      'geo_border',
      'geo',
      _sh(4, [
        _ln([
          for (var k = 0; k < 6; k++) [_o(0.02 + k * 0.165, 0.5), _o(0.11 + k * 0.165, 0.5)],
        ], w: 0.1),
        _fl([for (var k = 0; k < 6; k++) _ci(0.145 + k * 0.165, 0.5, 0.06, aspect: 4)]),
      ]),
    ),
    s('geo_contour', 'geo', _sh(1.3, [_ln([_el(0.5, 0.52, 0.45, 0.42), _el(0.5, 0.54, 0.32, 0.3), _el(0.5, 0.56, 0.19, 0.18), _el(0.5, 0.58, 0.07, 0.07)], w: 0.025)])),
    s('geo_current', 'geo', _sh(2, [..._curveArrow([for (var k = 0; k <= 20; k++) Offset(0.06 + 0.86 * k / 20, 0.7 - 0.45 * math.sin(math.pi * k / 20))], w: 0.06, head: 0.3, aspect: 2, color: _blue)])),
    s('geo_sunny', 'geo', ic('sunny', color: _gold)),
    s('geo_cloudy', 'geo', ic('cloud')),
    s('geo_rain', 'geo', ic('rainy', color: _blue)),
    s('geo_snow', 'geo', ic('weather_snowy', color: _blue)),
    s('geo_storm', 'geo', ic('thunderstorm')),
    s('geo_wind', 'geo', ic('air')),
    s('geo_typhoon', 'geo', ic('cyclone')),

    // ------------------------------------------------------------- history
    s(
      'hist_timeline',
      'history',
      _sh(4, [
        ..._arrow(_o(0.02, 0.6), _o(0.98, 0.6), w: 0.06, head: 0.3, aspect: 4),
        _fl([for (var k = 0; k < 5; k++) _ci(0.1 + k * 0.19, 0.6, 0.09, aspect: 4)]),
      ]),
    ),
    s('hist_march', 'history', _sh(2, [..._curveArrow([for (var k = 0; k <= 20; k++) Offset(0.06 + 0.86 * k / 20, 0.8 - 0.5 * math.sin(math.pi * k / 24))], w: 0.12, head: 0.4, aspect: 2, color: _red)])),
    s('hist_battle', 'history', ic('swords', color: _red)),
    s('hist_castle', 'history', ic('castle')),
    s('hist_fort', 'history', ic('fort')),
    s('hist_crown', 'history', ic('crown')),
    s('hist_scroll', 'history', ic('history_edu')),
    s('hist_flag', 'history', ic('flag', color: _red)),
    s(
      'hist_label',
      'history',
      _sh(2.4, [
        _ln([_rr(0.03, 0.12, 0.97, 0.88, 0.2, aspect: 2.4)], w: 0.06),
        _tx('1840', size: 0.46),
      ]),
    ),

    // ------------------------------------------------------------ language
    s('lang_tone1', 'lang', _sh(1, [_tx('ā', size: 0.8)])),
    s('lang_tone2', 'lang', _sh(1, [_tx('á', size: 0.8)])),
    s('lang_tone3', 'lang', _sh(1, [_tx('ǎ', size: 0.8)])),
    s('lang_tone4', 'lang', _sh(1, [_tx('à', size: 0.8)])),
    s('lang_underline', 'lang', _sh(4, [_ln([[_o(0.02, 0.6), _o(0.98, 0.6)]], w: 0.12, color: _red)])),
    s('lang_wavy', 'lang', _sh(4, [_ln([_wave(0.02, 0.98, 0.55, 0.18, 6)], w: 0.1, color: _red)])),
    s('lang_dots', 'lang', _sh(4, [_fl([for (var k = 0; k < 5; k++) _ci(0.1 + k * 0.2, 0.55, 0.12, aspect: 4)], color: _red)])),
    s('lang_circle', 'lang', _sh(2.2, [_ln([_el(0.5, 0.5, 0.46, 0.42)], w: 0.06, color: _red)])),
    s('lang_strike', 'lang', _sh(4, [_ln([[_o(0.02, 0.5), _o(0.98, 0.5)]], w: 0.1, color: _red)])),
    s('lang_insert', 'lang', _sh(1, [_ln([[_o(0.15, 0.85), _o(0.5, 0.15), _o(0.85, 0.85)]], w: 0.08, color: _red)])),
    s('lang_para', 'lang', _sh(1, [_tx('¶', size: 0.8)])),
    s('lang_swap', 'lang', _sh(2, [_ln([[for (var k = 0; k <= 30; k++) Offset(0.06 + 0.88 * k / 30, 0.5 - 0.36 * math.sin(_tau * k / 30))]], w: 0.07, color: _red)])),
    s('lang_quote', 'lang', _sh(1, [_tx('“ ”', size: 0.7)])),

    // ----------------------------------------------------------- programming
    s('code_start', 'code', _sh(2.4, [_ln([_rr(0.03, 0.1, 0.97, 0.9, 0.4, aspect: 2.4)], w: 0.06)])),
    s('code_process', 'code', _sh(2.2, [_ln([_rc(0.03, 0.1, 0.97, 0.9)], w: 0.06)])),
    s('code_decision', 'code', _sh(1.6, [_ln([[_o(0.5, 0.04), _o(0.97, 0.5), _o(0.5, 0.96), _o(0.03, 0.5), _o(0.5, 0.04)]], w: 0.06)])),
    s('code_io', 'code', _sh(2.4, [_ln([[_o(0.15, 0.1), _o(0.97, 0.1), _o(0.85, 0.9), _o(0.03, 0.9), _o(0.15, 0.1)]], w: 0.06)])),
    s('code_arrow', 'code', _sh(2, [..._arrow(_o(0.06, 0.5), _o(0.94, 0.5), w: 0.06, head: 0.3, aspect: 2)])),
    s('code_highlight', 'code', _sh(6, [_fl([_rc(0.0, 0.1, 1.0, 0.9)], color: 0x66FFEB3B)])),
    s('code_braces', 'code', _sh(1.4, [_tx('{ }', size: 0.8)])),
    s(
      'code_array',
      'code',
      _sh(4, [
        _ln([_rc(0.02, 0.15, 0.98, 0.85), for (var k = 1; k < 5; k++) [_o(0.02 + k * 0.192, 0.15), _o(0.02 + k * 0.192, 0.85)]], w: 0.05),
      ]),
    ),
    s(
      'code_list',
      'code',
      _sh(3, [
        _ln([_rc(0.02, 0.25, 0.26, 0.75), [_o(0.17, 0.25), _o(0.17, 0.75)], _rc(0.4, 0.25, 0.64, 0.75), [_o(0.55, 0.25), _o(0.55, 0.75)]], w: 0.04),
        ..._arrow(_o(0.2, 0.5), _o(0.4, 0.5), w: 0.04, head: 0.2, aspect: 3),
        ..._arrow(_o(0.58, 0.5), _o(0.82, 0.5), w: 0.04, head: 0.2, aspect: 3),
        _tx('∅', x: 0.92, size: 0.4),
      ]),
    ),
    s(
      'code_tree',
      'code',
      _sh(1.3, [
        _ln([
          [_o(0.5, 0.2), _o(0.25, 0.55)],
          [_o(0.5, 0.2), _o(0.75, 0.55)],
          [_o(0.25, 0.55), _o(0.12, 0.85)],
          [_o(0.25, 0.55), _o(0.38, 0.85)],
        ], w: 0.03),
        _fl([
          _ci(0.5, 0.17, 0.11, aspect: 1.3),
          _ci(0.25, 0.55, 0.11, aspect: 1.3),
          _ci(0.75, 0.55, 0.11, aspect: 1.3),
          _ci(0.12, 0.85, 0.1, aspect: 1.3),
          _ci(0.38, 0.85, 0.1, aspect: 1.3),
        ]),
      ]),
    ),
    s('code_bug', 'code', ic('bug_report')),
    s('code_terminal', 'code', ic('terminal')),
    s('code_tag', 'code', ic('code')),

    // --------------------------------------------------------- calligraphy
    s('callig_tian', 'callig', _writingGrid()),
    s('callig_mi', 'callig', _writingGrid(diagonals: true)),
    s('callig_nine', 'callig', _writingGrid(nine: true)),
    s('callig_order', 'callig', _sh(1, [_fl([_ci(0.5, 0.5, 0.44)], color: _red), _tx('1', size: 0.6, color: 0xFFFFFFFF)])),
    s('callig_brush', 'callig', ic('brush')),
    s('callig_seal', 'callig', _sh(1, [_ln([_rr(0.06, 0.06, 0.94, 0.94, 0.12)], w: 0.08, color: _red), _tx('印', size: 0.6, color: _red)])),
  ];
}
