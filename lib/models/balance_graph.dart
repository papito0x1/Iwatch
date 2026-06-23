import 'models.dart';

/// Window for the *main* balance area chart — the portfolio "Total value" card
/// and a token's "Holdings value" card. Each window is reconstructed from OHLCV
/// candles at an aggregate chosen to give a smooth, fixed-size curve.
///
/// The sidebar sparklines are deliberately independent of this and always show
/// the 24h ([d1]) series.
enum BalanceRange {
  d1('1D', ChartRange.m15, 96), // 24h of 15-minute buckets
  w1('1W', ChartRange.h1, 168), // 7d of hourly buckets
  m1('1M', ChartRange.h4, 180); // 30d of 4-hour buckets

  const BalanceRange(this.label, this.candle, this.buckets);

  final String label;

  /// OHLCV timeframe used to reconstruct this window.
  final ChartRange candle;

  /// Number of buckets that make up the window.
  final int buckets;

  /// Seconds per bucket (e.g. 1D → 900, 1W → 3600, 1M → 14400).
  int get bucketSec => candle.bucketSeconds;

  /// Total span of the window in seconds.
  int get windowSec => bucketSec * buckets;
}

/// Bucket-start timestamps (seconds, ascending) for [range]'s window ending at
/// the bucket containing [nowSec].
List<int> balanceGrid(BalanceRange range, int nowSec) {
  final last = (nowSec ~/ range.bucketSec) * range.bucketSec;
  return [
    for (var i = range.buckets - 1; i >= 0; i--) last - i * range.bucketSec,
  ];
}

/// Map a token's candle closes onto the [grid] (carry-forward, with the earliest
/// close back-filled across the head) scaled by [amount] to give the holding's
/// value at each bucket. A flat line at [fallbackValue] when the token has no
/// candles (illiquid / pool-less). [candles] must be oldest-first; [grid] is in
/// seconds and the returned points' x are in milliseconds.
List<Point> balanceSeriesOnGrid(
    List<int> grid, List<Candle> candles, double amount, double fallbackValue) {
  if (candles.isEmpty) {
    return [for (final b in grid) Point(b * 1000.0, fallbackValue)];
  }
  final out = <Point>[];
  var idx = 0;
  var lastClose = candles.first.close;
  for (final bucket in grid) {
    while (idx < candles.length && candles[idx].time <= bucket) {
      lastClose = candles[idx].close;
      idx++;
    }
    out.add(Point(bucket * 1000.0, lastClose * amount));
  }
  return out;
}

/// Roll a balance series [arr] forward for the current [value] at [nowSec],
/// mirroring how a candle's forming bar rolls over: refine the last bucket, or —
/// once the clock crosses into a new [bucketSec]-wide bucket — open a fresh one
/// and drop anything older than [windowSec]. Mutates [arr] in place; a no-op on
/// an empty series (reconstruction is responsible for seeding it).
void advanceBalancePoint(
    List<Point> arr, int nowSec, double value, int bucketSec, int windowSec) {
  if (arr.isEmpty) return;
  final bucketMs = ((nowSec ~/ bucketSec) * bucketSec) * 1000.0;
  if (bucketMs > arr.last.x) {
    arr.add(Point(bucketMs, value));
    final cutoff = (nowSec - windowSec) * 1000.0;
    while (arr.length > 2 && arr.first.x < cutoff) {
      arr.removeAt(0);
    }
  } else {
    arr[arr.length - 1] = Point(arr.last.x, value);
  }
}
