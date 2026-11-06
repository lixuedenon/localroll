// apps/desktop/lib/services/smart_query.dart
import 'package:localroll_core/localroll_core.dart' show MediaKind;

/// A search said in ordinary words ("去年夏天海边的视频", "photos from last
/// month"): when it was and what it is, taken out; the rest is searched as
/// usual (words in the photo / file, and what the photo looks like). All on
/// this PC, by simple rules — no AI service, no cost.
class SmartQuery {
  const SmartQuery({this.from, this.to, this.kind, required this.rest});

  /// Taken between [from] and [to] (null: any time).
  final DateTime? from, to;

  /// Photos / videos only (null: anything).
  final MediaKind? kind;

  /// What is left to search for.
  final String rest;

  bool get hasWhen => from != null || to != null;

  bool contains(DateTime t) => (from == null || !t.isBefore(from!)) && (to == null || t.isBefore(to!));

  static SmartQuery parse(String text, {DateTime? now}) {
    final n = now ?? DateTime.now();
    var s = ' ${text.trim()} ';
    DateTime? from, to;
    MediaKind? kind;
    int? year, month;
    List<int>? months;

    bool take(RegExp r, void Function(RegExpMatch m) f) {
      final m = r.firstMatch(s);
      if (m == null) return false;
      f(m);
      s = s.replaceRange(m.start, m.end, ' ');
      return true;
    }

    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);

    // Days and weeks.
    if (take(RegExp(r'今天|today', caseSensitive: false), (_) {})) {
      from = day(n);
      to = from!.add(const Duration(days: 1));
    } else if (take(RegExp(r'昨天|yesterday', caseSensitive: false), (_) {})) {
      to = day(n);
      from = to!.subtract(const Duration(days: 1));
    } else if (take(RegExp(r'前天'), (_) {})) {
      to = day(n).subtract(const Duration(days: 1));
      from = to!.subtract(const Duration(days: 1));
    } else if (take(RegExp(r'这周|本周|this week', caseSensitive: false), (_) {})) {
      from = day(n).subtract(Duration(days: n.weekday - 1));
      to = from!.add(const Duration(days: 7));
    } else if (take(RegExp(r'上周|上个?星期|last week', caseSensitive: false), (_) {})) {
      to = day(n).subtract(Duration(days: n.weekday - 1));
      from = to!.subtract(const Duration(days: 7));
    } else if (take(RegExp(r'最近|近来|recent(ly)?', caseSensitive: false), (_) {})) {
      from = day(n).subtract(const Duration(days: 30));
    }

    // Years.
    take(RegExp(r'(20\d\d|19\d\d)\s*年?'), (m) => year = int.parse(m.group(1)!));
    if (year == null) {
      if (take(RegExp(r'前年|year before last', caseSensitive: false), (_) {})) {
        year = n.year - 2;
      } else if (take(RegExp(r'去年|last year', caseSensitive: false), (_) {})) {
        year = n.year - 1;
      } else if (take(RegExp(r'今年|this year', caseSensitive: false), (_) {})) {
        year = n.year;
      }
    }

    // Months and seasons.
    if (take(RegExp(r'上个?月|last month', caseSensitive: false), (_) {})) {
      final t = DateTime(n.year, n.month - 1);
      year ??= t.year;
      month = t.month;
    } else if (take(RegExp(r'这个?月|本月|this month', caseSensitive: false), (_) {})) {
      year ??= n.year;
      month = n.month;
    } else if (take(RegExp(r'(1[0-2]|[1-9])\s*月'), (m) => month = int.parse(m.group(1)!))) {
    } else if (take(RegExp(r'春天|春季|spring', caseSensitive: false), (_) {})) {
      months = [3, 4, 5];
    } else if (take(RegExp(r'夏天|夏季|summer', caseSensitive: false), (_) {})) {
      months = [6, 7, 8];
    } else if (take(RegExp(r'秋天|秋季|autumn|fall', caseSensitive: false), (_) {})) {
      months = [9, 10, 11];
    } else if (take(RegExp(r'冬天|冬季|winter', caseSensitive: false), (_) {})) {
      months = [12, 13, 14];
    }

    if (from == null && to == null) {
      final y = year ?? n.year;
      if (month != null) {
        from = DateTime(y, month!);
        to = DateTime(y, month! + 1);
        // "3月" alone, still to come this year: last year's.
        if (year == null && from!.isAfter(n)) {
          from = DateTime(y - 1, month!);
          to = DateTime(y - 1, month! + 1);
        }
      } else if (months != null) {
        from = DateTime(y, months!.first);
        to = DateTime(y, months!.last + 1);
        if (year == null && from!.isAfter(n)) {
          from = DateTime(y - 1, months!.first);
          to = DateTime(y - 1, months!.last + 1);
        }
      } else if (year != null) {
        from = DateTime(y);
        to = DateTime(y + 1);
      }
    }

    // What it is.
    if (take(RegExp(r'视频|录像|影片|videos?|movies?', caseSensitive: false), (_) {})) {
      kind = MediaKind.video;
    } else if (take(RegExp(r'照片|相片|图片|photos?|pictures?|pics?', caseSensitive: false), (_) {})) {
      kind = MediaKind.image;
    }

    // Little words left over ("的", "from", "in"…).
    var rest = s.replaceAll(RegExp(r'(^|\s)(的|在|拍的|里|中|from|in|of|the|at|taken)(?=\s|$)', caseSensitive: false), ' ');
    rest = rest.replaceAll('的', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return SmartQuery(from: from, to: to, kind: kind, rest: rest);
  }
}
