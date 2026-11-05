// packages/ink/lib/src/packs/work.dart
part of '../stamp_packs.dart';

// Jobs: software tutorials, business, online selling, interior design,
// engineering, car repair, document review, medicine, driving, cooking,
// game commentary, astronomy. Drawn here or from Material Symbols (Apache
// 2.0). Names: the app's text 'stamp.<id>'.

/// A rounded label with a word.
StampShape _label(String word, {int? color, double aspect = 2.4}) => _sh(aspect, [
      _fl([_rr(0.02, 0.08, 0.98, 0.92, 0.25, aspect: aspect)], color: color),
      _tx(word, size: 0.5, color: _white),
    ]);

/// A rubber stamp: a word in a double ring, slightly turned.
StampShape _seal(String word, int color) => _sh(2.6, [
      _ln([_rr(0.03, 0.08, 0.97, 0.92, 0.18, aspect: 2.6), _rr(0.07, 0.2, 0.93, 0.8, 0.12, aspect: 2.6)], w: 0.05, color: color),
      _tx(word, size: 0.42, color: color),
    ]);

List<Stamp> _workStamps() {
  Stamp s(String id, String pack, StampShape shape) => Stamp(id: id, pack: pack, shape: shape);
  StampShape ic(String name, {int? color}) => StampPacks._ic(name, color: color);
  const orange = 0xFFFB8C00, green = 0xFF43A047, red = 0xFFE53935, grey = 0xFF757575;
  // A key cap with a word.
  StampShape key(String t, {double aspect = 1.2}) => _sh(aspect, [
        _ln([_rr(0.04, 0.06, 0.96, 0.94, 0.18, aspect: aspect)], w: 0.06),
        _ln([_rr(0.12, 0.14, 0.88, 0.76, 0.12, aspect: aspect)], w: 0.025),
        _tx(t, y: 0.45, size: 0.36),
      ]);
  return [
    // ------------------------------------------------------ software tutorials
    s('tut_mouse', 'tutorial', ic('mouse')),
    s(
      'tut_left',
      'tutorial',
      _sh(0.7, [
        _ln([_rr(0.06, 0.04, 0.94, 0.96, 0.4, aspect: 0.7), [_o(0.5, 0.04), _o(0.5, 0.42)], [_o(0.06, 0.42), _o(0.94, 0.42)]], w: 0.04),
        _fl([
          [_o(0.5, 0.06), _o(0.5, 0.4), _o(0.08, 0.4), ..._el(0.5, 0.42, 0.42, 0.36, a0: math.pi, a1: math.pi * 1.5, n: 12)],
        ], color: orange),
      ]),
    ),
    s(
      'tut_right',
      'tutorial',
      _sh(0.7, [
        _ln([_rr(0.06, 0.04, 0.94, 0.96, 0.4, aspect: 0.7), [_o(0.5, 0.04), _o(0.5, 0.42)], [_o(0.06, 0.42), _o(0.94, 0.42)]], w: 0.04),
        _fl([
          [_o(0.5, 0.06), _o(0.5, 0.4), _o(0.92, 0.4), ..._el(0.5, 0.42, 0.42, 0.36, a0: 0, a1: -math.pi / 2, n: 12)],
        ], color: 0xFF42A5F5),
      ]),
    ),
    s(
      'tut_wheel',
      'tutorial',
      _sh(0.7, [
        _ln([_rr(0.06, 0.04, 0.94, 0.96, 0.4, aspect: 0.7), [_o(0.06, 0.42), _o(0.94, 0.42)]], w: 0.04),
        _fl([_rr(0.42, 0.12, 0.58, 0.36, 0.06, aspect: 0.7)], color: orange),
        ..._arrow(_o(0.5, 0.62), _o(0.5, 0.88), w: 0.04, head: 0.12, aspect: 0.7, both: true),
      ]),
    ),
    s('tut_key', 'tutorial', key('Ctrl', aspect: 1.6)),
    s('tut_key_c', 'tutorial', key('C')),
    s('tut_keyboard', 'tutorial', ic('keyboard')),
    s('tut_tap', 'tutorial', ic('touch_app')),
    s('tut_swipe', 'tutorial', ic('swipe')),
    s('tut_pinch', 'tutorial', ic('pinch')),
    s('tut_click', 'tutorial', ic('ads_click')),
    s('tut_zoom', 'tutorial', ic('zoom_in')),
    s('tut_mosaic', 'tutorial', _sh(1.4, [for (var i = 0; i < 7; i++) for (var j = 0; j < 5; j++) _fl([_rc(i / 7, j / 5, (i + 1) / 7, (j + 1) / 5)], color: [0xFF9E9E9E, 0xFFBDBDBD, 0xFF757575, 0xFFE0E0E0][(i * 3 + j * 5) % 4])])),
    s('tut_step', 'tutorial', _sh(1, [_fl([_ci(0.5, 0.5, 0.46)], color: red), _tx('1', size: 0.6, color: _white)])),

    // ---------------------------------------------------------------- business
    s('biz_org', 'business', ic('account_tree')),
    s('biz_bar', 'business', ic('bar_chart')),
    s('biz_pie', 'business', ic('pie_chart')),
    s(
      'biz_gantt',
      'business',
      _sh(2, [
        _ln([
          [_o(0.03, 0.04), _o(0.03, 0.96)]
        ], w: 0.025),
        _fl([_rr(0.06, 0.1, 0.5, 0.26, 0.06, aspect: 2), _rr(0.3, 0.4, 0.78, 0.56, 0.06, aspect: 2), _rr(0.62, 0.7, 0.97, 0.86, 0.06, aspect: 2)]),
      ]),
    ),
    s(
      'biz_swot',
      'business',
      _sh(1, [
        _ln([_rc(0.03, 0.03, 0.97, 0.97), [_o(0.5, 0.03), _o(0.5, 0.97)], [_o(0.03, 0.5), _o(0.97, 0.5)]], w: 0.03),
        for (final (t, x, y) in const [('S', 0.27, 0.27), ('W', 0.73, 0.27), ('O', 0.27, 0.73), ('T', 0.73, 0.73)]) _tx(t, x: x, y: y, size: 0.28),
      ]),
    ),
    s('biz_high', 'business', _label('P1', color: red)),
    s('biz_mid', 'business', _label('P2', color: orange)),
    s('biz_low', 'business', _label('P3', color: green)),
    s('biz_todo', 'business', _sh(1, [_ln([_rr(0.1, 0.1, 0.9, 0.9, 0.12)], w: 0.07)])),
    s('biz_done', 'business', ic('task_alt', color: green)),
    s('biz_milestone', 'business', _sh(1, [_fl([[_o(0.5, 0.06), _o(0.94, 0.5), _o(0.5, 0.94), _o(0.06, 0.5), _o(0.5, 0.06)]])])),
    s('biz_team', 'business', ic('groups')),
    s('biz_seal_done', 'business', _seal('DONE', green)),
    s('biz_seal_wip', 'business', _seal('WIP', orange)),
    s('biz_seal_hold', 'business', _seal('HOLD', grey)),

    // ------------------------------------------------------------ online selling
    s('shop_price', 'shop', _sh(2.2, [
      _fl([
        [_o(0.0, 0.5), _o(0.16, 0.05), _o(1, 0.05), _o(1, 0.95), _o(0.16, 0.95), _o(0.0, 0.5)]
      ], color: red),
      _fl([_ci(0.13, 0.5, 0.06, aspect: 2.2)], color: _white),
      _tx('¥99', x: 0.58, size: 0.52, color: _white),
    ])),
    s('shop_was', 'shop', _sh(2.2, [_tx('¥199', size: 0.6, color: grey), _ln([[_o(0.1, 0.55), _o(0.9, 0.45)]], w: 0.07, color: red)])),
    s(
      'shop_burst',
      'shop',
      _sh(1, [
        _fl([
          [for (var k = 0; k <= 24; k++) Offset(0.5 + (k.isEven ? 0.48 : 0.36) * math.cos(_tau * k / 24), 0.5 + (k.isEven ? 0.48 : 0.36) * math.sin(_tau * k / 24))]
        ], color: 0xFFFFC107),
        _tx('-50%', size: 0.28, color: red),
      ]),
    ),
    s('shop_hot', 'shop', ic('local_fire_department', color: red)),
    s('shop_new', 'shop', _label('NEW', color: 0xFF1E88E5)),
    s('shop_limited', 'shop', _label('LIMITED', color: red, aspect: 3.2)),
    s('shop_sale', 'shop', _label('SALE', color: red)),
    s('shop_cart', 'shop', ic('shopping_cart')),
    s('shop_size', 'shop', _sh(3, [..._arrow(_o(0.03, 0.5), _o(0.97, 0.5), w: 0.06, head: 0.3, aspect: 3, both: true), _ln([[_o(0.01, 0.15), _o(0.01, 0.85)], [_o(0.99, 0.15), _o(0.99, 0.85)]], w: 0.05)])),
    s(
      'shop_compare',
      'shop',
      _sh(2, [
        _ln([_rc(0.02, 0.04, 0.98, 0.96), [_o(0.5, 0.04), _o(0.5, 0.96)]], w: 0.03),
        _tx('BEFORE', x: 0.26, y: 0.14, size: 0.12),
        _tx('AFTER', x: 0.74, y: 0.14, size: 0.12),
      ]),
    ),
    s('shop_countdown', 'shop', _sh(2.6, [_fl([_rr(0.02, 0.08, 0.98, 0.92, 0.2, aspect: 2.6)], color: 0xFF212121), _tx('00:59', size: 0.56, color: 0xFFFF5252)])),
    s('shop_tag', 'shop', ic('sell')),

    // --------------------------------------------------------- interior design
    s(
      'int_dim',
      'interior',
      _sh(4, [
        ..._arrow(_o(0.02, 0.6), _o(0.98, 0.6), w: 0.05, head: 0.25, aspect: 4, both: true),
        _ln([[_o(0.005, 0.3), _o(0.005, 0.9)], [_o(0.995, 0.3), _o(0.995, 0.9)]], w: 0.05),
        _tx('3600', y: 0.25, size: 0.36),
      ]),
    ),
    s('int_wall', 'interior', _sh(4, [_fl([_rc(0.0, 0.3, 1.0, 0.7)])])),
    s(
      'int_door',
      'interior',
      _sh(1, [
        _ln([
          [_o(0.06, 0.94), _o(0.06, 0.06)],
          _ci(0.06, 0.94, 0.88, a0: -math.pi / 2, a1: 0, n: 20),
        ], w: 0.04),
        _ln([
          [_o(0.0, 0.94), _o(1.0, 0.94)]
        ], w: 0.1),
      ]),
    ),
    s('int_window', 'interior', _sh(4, [_ln([_rc(0.0, 0.3, 1.0, 0.7), [_o(0.0, 0.5), _o(1.0, 0.5)]], w: 0.05)])),
    s('int_stairs', 'interior', ic('stairs')),
    s('int_bed', 'interior', ic('bed')),
    s('int_sofa', 'interior', ic('weekend')),
    s('int_table', 'interior', ic('table_restaurant')),
    s('int_chair', 'interior', ic('chair')),
    s('int_bath', 'interior', ic('bathtub')),
    s('int_wc', 'interior', ic('wc')),
    s('int_kitchen', 'interior', ic('kitchen')),
    s('int_area', 'interior', _sh(2.4, [_ln([_rc(0.02, 0.06, 0.98, 0.94)], w: 0.04), _tx('12 m²', size: 0.44)])),

    // ------------------------------------------------------------- engineering
    s('eng_gear', 'engineering', ic('settings')),
    s('eng_tools', 'engineering', ic('build')),
    s('eng_build', 'engineering', ic('construction')),
    s('eng_pipe', 'engineering', ic('plumbing')),
    s('eng_electric', 'engineering', ic('electrical_services')),
    s('eng_chip', 'engineering', ic('memory')),
    s('eng_robot', 'engineering', ic('precision_manufacturing')),
    s(
      'eng_and',
      'engineering',
      _sh(1.6, [
        _ln([
          [_o(0.25, 0.1), _o(0.55, 0.1), ..._ci(0.55, 0.5, 0.4, a0: -math.pi / 2, a1: math.pi / 2, n: 20, aspect: 1.6), _o(0.25, 0.9), _o(0.25, 0.1)],
          [_o(0.02, 0.3), _o(0.25, 0.3)],
          [_o(0.02, 0.7), _o(0.25, 0.7)],
          [_o(0.8, 0.5), _o(0.98, 0.5)],
        ], w: 0.05),
      ]),
    ),
    s(
      'eng_or',
      'engineering',
      _sh(1.6, [
        _ln([
          [for (var k = 0; k <= 12; k++) Offset(0.2 + 0.1 * math.sin(math.pi * k / 12), 0.1 + 0.8 * k / 12)],
          [for (var k = 0; k <= 12; k++) Offset(0.2 + 0.62 * k / 12, 0.1 + 0.4 * (k / 12) * (k / 12))],
          [for (var k = 0; k <= 12; k++) Offset(0.2 + 0.62 * k / 12, 0.9 - 0.4 * (k / 12) * (k / 12))],
          [_o(0.02, 0.3), _o(0.27, 0.3)],
          [_o(0.02, 0.7), _o(0.27, 0.7)],
          [_o(0.82, 0.5), _o(0.98, 0.5)],
        ], w: 0.05),
      ]),
    ),
    s('eng_not', 'engineering', _sh(1.6, [_ln([[_o(0.2, 0.1), _o(0.72, 0.5), _o(0.2, 0.9), _o(0.2, 0.1)], _ci(0.78, 0.5, 0.07, aspect: 1.6), [_o(0.02, 0.5), _o(0.2, 0.5)], [_o(0.84, 0.5), _o(0.98, 0.5)]], w: 0.05)])),
    s(
      'eng_tolerance',
      'engineering',
      _sh(4, [
        ..._arrow(_o(0.02, 0.65), _o(0.98, 0.65), w: 0.05, head: 0.25, aspect: 4, both: true),
        _tx('50 ±0.1', y: 0.27, size: 0.36),
      ]),
    ),
    s('eng_weld', 'engineering', _sh(1, [_fl([_ci(0.5, 0.5, 0.18)]), _ln([_ci(0.5, 0.5, 0.36)], w: 0.04)])),

    // ------------------------------------------------------------- car repair
    s('car_car', 'auto', ic('directions_car')),
    s('car_repair', 'auto', ic('car_repair')),
    s('car_tire', 'auto', ic('tire_repair')),
    s('car_oil', 'auto', ic('oil_barrel')),
    s('car_tools', 'auto', ic('handyman')),
    s('car_tighten', 'auto', _sh(1, [..._curveArrow(_ci(0.5, 0.5, 0.36, a0: -math.pi * 0.6, a1: math.pi * 1.1, n: 30), w: 0.08, head: 0.28), _tx('+', size: 0.4)])),
    s('car_loosen', 'auto', _sh(1, [..._curveArrow(_ci(0.5, 0.5, 0.36, a0: math.pi * 1.6, a1: -math.pi * 0.1, n: 30), w: 0.08, head: 0.28), _tx('−', size: 0.4)])),
    s('car_warning', 'auto', ic('warning', color: 0xFFFFB300)),
    s('car_part', 'auto', _sh(2.4, [_fl([_ci(0.12, 0.5, 0.1, aspect: 2.4)], color: red), ..._arrow(_o(0.22, 0.5), _o(0.97, 0.5), w: 0.06, head: 0.3, aspect: 2.4, color: red)])),

    // --------------------------------------------------------- document review
    s('law_gavel', 'legal', ic('gavel')),
    s('law_note', 'legal', ic('edit_note')),
    s('law_sign', 'legal', ic('signature')),
    s('law_checked', 'legal', _seal('CHECKED', green)),
    s('law_returned', 'legal', _seal('RETURNED', red)),
    s('law_pending', 'legal', _seal('TO SIGN', orange)),
    s('law_approved', 'legal', ic('approval', color: green)),
    s('law_signhere', 'legal', _sh(3.2, [_ln([[_o(0.06, 0.78), _o(0.96, 0.78)]], w: 0.04), _tx('✕', x: 0.08, y: 0.52, size: 0.4), _fl([[_o(0.0, 0.2), _o(0.0, 0.5), _o(0.04, 0.35), _o(0.0, 0.2)]], color: red)])),
    s('law_page', 'legal', _label('p. 12', color: 0xFF5C6BC0, aspect: 2.2)),

    // --------------------------------------------------------------- medicine
    s('med_steth', 'medical', ic('stethoscope')),
    s('med_heart', 'medical', ic('monitor_heart', color: red)),
    s('med_teeth', 'medical', ic('dentistry')),
    s('med_eye', 'medical', ic('ophthalmology')),
    s('med_pill', 'medical', ic('medication')),
    s('med_vaccine', 'medical', ic('vaccines')),
    s('med_emergency', 'medical', ic('emergency', color: red)),
    s('med_skeleton', 'medical', ic('skeleton')),
    s(
      'med_pain',
      'medical',
      _sh(5, [
        for (var k = 0; k <= 10; k++)
          _fl([_rc(0.01 + k * 0.09, 0.15, 0.09 + k * 0.09, 0.85)], color: Color.lerp(const Color(0xFF43A047), const Color(0xFFE53935), k / 10)!.toARGB32()),
        for (final k in [0, 5, 10]) _tx('$k', x: 0.05 + k * 0.09, size: 0.4, color: _white),
      ]),
    ),

    // --------------------------------------------------------------- driving
    s(
      'drv_cross',
      'traffic',
      _sh(1, [
        _fl([_rc(0.3, 0, 0.7, 1), _rc(0, 0.3, 1, 0.7)], color: 0xFF616161),
        _ln([..._dash(_o(0.5, 0), _o(0.5, 0.3), dashes: 3), ..._dash(_o(0.5, 0.7), _o(0.5, 1), dashes: 3), ..._dash(_o(0, 0.5), _o(0.3, 0.5), dashes: 3), ..._dash(_o(0.7, 0.5), _o(1, 0.5), dashes: 3)], w: 0.02, color: _white),
      ]),
    ),
    s(
      'drv_round',
      'traffic',
      _sh(1, [
        _fl([_ci(0.5, 0.5, 0.46)], color: 0xFF616161),
        _fl([_ci(0.5, 0.5, 0.2)], color: 0xFF43A047),
        _ln([_ci(0.5, 0.5, 0.33)], w: 0.015, color: _white),
      ]),
    ),
    s('drv_lanes', 'traffic', _sh(0.8, [_fl([_rc(0, 0, 1, 1)], color: 0xFF616161), _ln([[_o(0.04, 0), _o(0.04, 1)], [_o(0.96, 0), _o(0.96, 1)]], w: 0.03, color: _white), _ln([..._dash(_o(0.36, 0), _o(0.36, 1), dashes: 6), ..._dash(_o(0.64, 0), _o(0.64, 1), dashes: 6)], w: 0.025, color: _white)])),
    s('drv_car', 'traffic', ic('directions_car', color: 0xFF1E88E5)),
    s('drv_walk', 'traffic', ic('directions_walk')),
    s('drv_bike', 'traffic', ic('pedal_bike')),
    s('drv_light', 'traffic', ic('traffic')),
    s('drv_left', 'traffic', ic('turn_left')),
    s('drv_right', 'traffic', ic('turn_right')),
    s('drv_uturn', 'traffic', ic('u_turn_left')),
    s('drv_stop', 'traffic', _sh(1, [_fl([[for (var k = 0; k <= 8; k++) Offset(0.5 + 0.46 * math.cos(math.pi / 8 + k * math.pi / 4), 0.5 + 0.46 * math.sin(math.pi / 8 + k * math.pi / 4))]], color: red), _tx('STOP', size: 0.26, color: _white)])),
    s('drv_noentry', 'traffic', _sh(1, [_fl([_ci(0.5, 0.5, 0.46)], color: red), _fl([_rc(0.2, 0.42, 0.8, 0.58)], color: _white)])),

    // --------------------------------------------------------------- cooking
    s('cook_high', 'cooking', _sh(1, [for (final x in [0.25, 0.5, 0.75]) _fl([[_o(x, 0.12), ..._el(x, 0.7, 0.13, 0.22, a0: -math.pi / 2 + 0.6, a1: math.pi * 1.5 - 0.6, n: 12), _o(x, 0.12)]], color: red)])),
    s('cook_mid', 'cooking', _sh(1, [for (final x in [0.35, 0.65]) _fl([[_o(x, 0.24), ..._el(x, 0.72, 0.12, 0.18, a0: -math.pi / 2 + 0.6, a1: math.pi * 1.5 - 0.6, n: 12), _o(x, 0.24)]], color: orange)])),
    s('cook_low', 'cooking', _sh(1, [_fl([[_o(0.5, 0.42), ..._el(0.5, 0.75, 0.12, 0.14, a0: -math.pi / 2 + 0.6, a1: math.pi * 1.5 - 0.6, n: 12), _o(0.5, 0.42)]], color: 0xFF1E88E5)])),
    s('cook_timer', 'cooking', ic('timer')),
    s('cook_pan', 'cooking', ic('skillet')),
    s('cook_pot', 'cooking', ic('soup_kitchen')),
    s('cook_egg', 'cooking', ic('egg')),
    s('cook_scale', 'cooking', ic('scale')),
    s('cook_spoon', 'cooking', _sh(0.5, [_fl([_el(0.5, 0.22, 0.3, 0.18)]), _ln([[_o(0.5, 0.38), _o(0.5, 0.96)]], w: 0.06)])),
    s('cook_cut', 'cooking', _sh(2, [_ln(_dash(_o(0.04, 0.5), _o(0.96, 0.5), dashes: 8), w: 0.05), _tx('✂', x: 0.1, y: 0.25, size: 0.4)])),

    // ------------------------------------------------------- game commentary
    s('game_pad', 'gaming', ic('sports_esports')),
    s('game_us', 'gaming', _sh(1, [_fl([[_o(0.5, 0.04), _o(0.92, 0.5), _o(0.5, 0.96), _o(0.08, 0.5), _o(0.5, 0.04)]], color: 0xFF1E88E5)])),
    s('game_enemy', 'gaming', _sh(1, [_fl([[_o(0.5, 0.04), _o(0.92, 0.5), _o(0.5, 0.96), _o(0.08, 0.5), _o(0.5, 0.04)]], color: red)])),
    s('game_target', 'gaming', ic('my_location', color: red)),
    s('game_range', 'gaming', _sh(1, [_fl([_ci(0.5, 0.5, 0.46)], color: 0x44FFEB3B), _ln([_ci(0.5, 0.5, 0.46)], w: 0.03, color: 0xFFFFC107)])),
    s('game_rally', 'gaming', _sh(1, [_ln([_ci(0.5, 0.5, 0.42), _ci(0.5, 0.5, 0.24)], w: 0.05, color: green), _fl([_ci(0.5, 0.5, 0.08)], color: green)])),
    s('game_danger', 'gaming', ic('skull', color: red)),
    s('game_shield', 'gaming', ic('shield')),
    s('game_fight', 'gaming', ic('swords')),

    // ------------------------------------------------------------- astronomy
    s('astro_planet', 'astro', ic('planet')),
    s('astro_moon', 'astro', ic('dark_mode', color: 0xFFFFD54F)),
    s('astro_sun', 'astro', ic('brightness_7', color: 0xFFFFB300)),
    s('astro_earth', 'astro', ic('public', color: 0xFF1E88E5)),
    s('astro_rocket', 'astro', ic('rocket')),
    s('astro_satellite', 'astro', ic('satellite_alt')),
    s(
      'astro_orbit',
      'astro',
      _sh(1.6, [
        _ln([_el(0.5, 0.5, 0.46, 0.4)], w: 0.02),
        _fl([_ci(0.5, 0.5, 0.12, aspect: 1.6)], color: 0xFFFFB300),
        _fl([_ci(0.96, 0.5, 0.06, aspect: 1.6)], color: 0xFF1E88E5),
      ]),
    ),
    s(
      'astro_phases',
      'astro',
      _sh(4, [
        for (var k = 0; k < 4; k++) _ln([_ci(0.125 + k * 0.25, 0.5, 0.38, aspect: 4)], w: 0.03),
        _fl([
          _ci(0.125, 0.5, 0.38, aspect: 4),
          [..._ci(0.375, 0.5, 0.38, a0: -math.pi / 2, a1: math.pi / 2, n: 16, aspect: 4)],
          [..._ci(0.875, 0.5, 0.38, a0: math.pi / 2, a1: math.pi * 1.5, n: 16, aspect: 4)],
        ]),
      ]),
    ),
    s(
      'astro_constellation',
      'astro',
      _sh(1.6, [
        _ln([
          [_o(0.06, 0.7), _o(0.26, 0.55), _o(0.46, 0.6), _o(0.62, 0.38), _o(0.86, 0.3), _o(0.94, 0.62), _o(0.7, 0.72), _o(0.62, 0.38)]
        ], w: 0.02),
        _fl([for (final p in const [(0.06, 0.7), (0.26, 0.55), (0.46, 0.6), (0.62, 0.38), (0.86, 0.3), (0.94, 0.62), (0.7, 0.72)]) _ci(p.$1, p.$2, 0.045, aspect: 1.6)]),
      ]),
    ),
    s(
      'astro_compass',
      'astro',
      _sh(1, [
        _ln([_ci(0.5, 0.5, 0.34)], w: 0.03),
        for (final (t, x, y) in const [('N', 0.5, 0.07), ('E', 0.93, 0.5), ('S', 0.5, 0.93), ('W', 0.07, 0.5)]) _tx(t, x: x, y: y, size: 0.14),
        _ln([
          [_o(0.5, 0.2), _o(0.5, 0.8)],
          [_o(0.2, 0.5), _o(0.8, 0.5)],
        ], w: 0.015),
      ]),
    ),
  ];
}
