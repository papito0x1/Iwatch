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

  /// Duration of one candle bucket in seconds — i.e. how long a single candle
  /// covers before the next one opens (e.g. 5m → 300, 1H → 3600, 1D → 86400).
  int get bucketSeconds => switch (timeframe) {
        'minute' => aggregate * 60,
        'hour' => aggregate * 3600,
        'day' => aggregate * 86400,
        _ => aggregate * 60,
      };
}

/// Advance a candle [series] for a live [price] at wall-clock [nowSec], given a
/// [bucketSeconds]-wide timeframe. Returns the updated series, or `null` when
/// nothing changes (so callers can skip a repaint).
///
/// This is what makes the chart roll forward on its own: once the clock crosses
/// into a new bucket, a fresh candle is appended (opening at the prior close) —
/// e.g. on the 5m range a new candle prints every 5 minutes. Within the same
/// bucket the forming (last) candle's close/high/low are refined instead.
///
/// A `null` [price] means "no live trade yet" (timer-driven sweep): a rolled-over
/// candle tracks the last close flat, and the forming candle is left untouched.
/// Buckets align to the Unix epoch, matching GeckoTerminal's candle timestamps,
/// so when the real candle arrives it merges over the synthetic one by time.
///
/// Pure (no widget/model state) so the rollover can be unit-tested.
List<Candle>? advanceCandles(
  List<Candle> series,
  int nowSec,
  int bucketSeconds,
  double? price,
) {
  if (series.isEmpty || bucketSeconds <= 0) return null;
  final last = series.last;
  final curBucketStart = (nowSec ~/ bucketSeconds) * bucketSeconds;

  if (curBucketStart > last.time) {
    final p = price ?? last.close;
    final fresh = Candle(
      time: curBucketStart,
      open: last.close,
      high: p > last.close ? p : last.close,
      low: p < last.close ? p : last.close,
      close: p,
      volume: 0,
    );
    return List<Candle>.of(series)..add(fresh);
  }

  if (price == null) return null; // nothing to seed without a trade
  if (last.close == price && price <= last.high && price >= last.low) {
    return null; // already reflects this price
  }
  final refined = Candle(
    time: last.time,
    open: last.open,
    high: price > last.high ? price : last.high,
    low: price < last.low ? price : last.low,
    close: price,
    volume: last.volume,
  );
  return List<Candle>.of(series)..[series.length - 1] = refined;
}
