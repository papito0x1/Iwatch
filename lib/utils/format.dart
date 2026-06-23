import 'package:intl/intl.dart';

/// Number / time formatters — ports of the helpers in renderer.js.

final _usd = NumberFormat.currency(locale: 'en_US', symbol: '\$', decimalDigits: 2);

String fmtUsd(double? n) {
  if (n == null || n.isNaN) return '—';
  return _usd.format(n);
}

String fmtPrice(double? n) {
  if (n == null || n.isNaN) return '—';
  if (n == 0) return '\$0';
  if (n < 0.0001) return '\$${n.toStringAsExponential(2)}';
  if (n < 1) return '\$${_precision(n, 3)}';
  return fmtUsd(n);
}

// Mimic JS Number.prototype.toPrecision (trims to N significant digits).
String _precision(double n, int digits) {
  if (n == 0) return '0';
  final s = n.toStringAsPrecision(digits);
  // strip trailing zeros / dot, like JS toPrecision largely does for these ranges
  if (s.contains('.')) {
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

String fmtCompactUsd(double? n) {
  if (n == null || n.isNaN) return '';
  final a = n.abs();
  if (a >= 1e9) return '\$${(n / 1e9).toStringAsFixed(1)}B';
  if (a >= 1e6) return '\$${(n / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e3) return '\$${(n / 1e3).toStringAsFixed(1)}K';
  return '\$${n.toStringAsFixed(0)}';
}

final _amt4 = NumberFormat('#,##0.####', 'en_US');
final _amt6 = NumberFormat('#,##0.######', 'en_US');

String fmtAmount(double? n) {
  if (n == null || n.isNaN) return '—';
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)}B';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(2)}M';
  if (n >= 1) return _amt4.format(n);
  return _amt6.format(n);
}

String fmtPct(double? n) {
  if (n == null || n.isNaN) return '—';
  return '${n >= 0 ? '+' : ''}${n.toStringAsFixed(2)}%';
}

String fmtTime(int tsMs) {
  return DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(tsMs));
}

/// Short calendar date for multi-day chart axes, e.g. "Jun 16".
String fmtDate(int tsMs) {
  return DateFormat('MMM d').format(DateTime.fromMillisecondsSinceEpoch(tsMs));
}

/// Date + time for tooltips on multi-day charts, e.g. "Jun 16, 01:12 PM".
String fmtDateTime(int tsMs) {
  return DateFormat('MMM d, hh:mm a')
      .format(DateTime.fromMillisecondsSinceEpoch(tsMs));
}

String shortAddr(String? a) {
  if (a == null || a.isEmpty) return '—';
  return '${a.substring(0, 4)}…${a.substring(a.length - 4)}';
}
