/// A single OHLCV candlestick (open / high / low / close / volume).
///
/// Fetched from GeckoTerminal's keyless OHLCV endpoint, which returns rows as
/// [timestamp, open, high, low, close, volume]. Values may arrive as either
/// num or String depending on the token, so [_toDouble] handles both.
class Candle {
  final int time; // unix seconds (candle open time)
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  bool get isUp => close >= open;

  factory Candle.fromGeckoRow(List<dynamic> row) {
    return Candle(
      time: _toInt(row[0]),
      open: _toDouble(row[1]),
      high: _toDouble(row[2]),
      low: _toDouble(row[3]),
      close: _toDouble(row[4]),
      volume: _toDouble(row[5]),
    );
  }

  static int _toInt(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

  static double _toDouble(dynamic v) =>
      v is double ? v : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0);
}

/// Chart time intervals, mirroring jup.ag's range selector.
enum ChartRange {
  m5('5m', 'minute', 5),
  m15('15m', 'minute', 15),
  h1('1H', 'hour', 1),
  h4('4H', 'hour', 4),
  d1('1D', 'day', 1);

  final String label;
  final String timeframe; // GeckoTerminal ohlcv path segment
  final int aggregate;

  const ChartRange(this.label, this.timeframe, this.aggregate);
}
