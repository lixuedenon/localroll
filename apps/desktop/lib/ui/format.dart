// apps/desktop/lib/ui/format.dart
import '../l10n/l10n.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatDate(DateTime t) =>
    '${t.year}-${_2(t.month)}-${_2(t.day)} ${_2(t.hour)}:${_2(t.minute)}';

String formatMonth(DateTime t) => formatMonthYear(t);

String _2(int n) => n.toString().padLeft(2, '0');

/// "Today 18:02", "Yesterday 21:10", "Nov 3 09:15".
String formatWhen(DateTime t) {
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final today = DateTime(now.year, now.month, now.day);
  if (!t.isBefore(today)) return tr('when.today', {'time': hm});
  if (!t.isBefore(today.subtract(const Duration(days: 1)))) return tr('when.yesterday', {'time': hm});
  return '${formatDayShort(t)} $hm';
}
