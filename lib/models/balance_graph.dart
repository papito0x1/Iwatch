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
/// close back-filled across the head) and scale to the holding's value, anchored
/// so the most recent bucket equals [currentValue].
///
/// We use the *ratio* of each close to the latest close — `currentValue ×
/// close(t) / close(now)` — rather than `close × amount`. This is scale-
/// invariant: the magnitude stays correct (and small) even when the candle pool
/// prices in odd units or a scam token resolves to a misleading pool, because
/// the authoritative current value comes from the price feed. Algebraically it
/// equals `balance × close(t)` whenever the candle is a true USD price.
///
/// A flat line at [currentValue] when the token has no candles (illiquid /
/// pool-less) or the latest close is non-positive. [candles] must be oldest-
/// first; [grid] is in seconds and the returned points' x are in milliseconds.
List<Point> balanceSeriesOnGrid(
    List<int> grid, List<Candle> candles, double currentValue) {
  if (candles.isEmpty) {
    return [for (final b in grid) Point(b * 1000.0, currentValue)];
  }
  final closes = <double>[];
  var idx = 0;
  var lastClose = candles.first.close;
  for (final bucket in grid) {
    while (idx < candles.length && candles[idx].time <= bucket) {
      lastClose = candles[idx].close;
      idx++;
    }
    closes.add(lastClose);
  }
  final anchor = closes.last;
  if (anchor <= 0) {
    return [for (final b in grid) Point(b * 1000.0, currentValue)];
  }
  return [
    for (var i = 0; i < grid.length; i++)
      Point(grid[i] * 1000.0, currentValue * closes[i] / anchor)
  ];
}

/// Re-align an existing value series [prev] (Points with x in milliseconds) onto
/// [grid] (seconds) by carry-forward, re-anchored so the latest bucket equals
/// [currentValue] — used to keep a token's *shape* when its candle re-fetch is
/// rate-limited, instead of dropping it to a flat line. Re-anchoring keeps the
/// magnitude correct even if [prev] was persisted with a stale or mis-scaled
/// value. Buckets past the end of [prev] carry its last value; a flat
/// [currentValue] line when [prev] is empty or its latest value is non-positive.
List<Point> reuseSeriesOnGrid(
    List<int> grid, List<Point> prev, double currentValue) {
  if (prev.isEmpty) {
    return [for (final b in grid) Point(b * 1000.0, currentValue)];
  }
  final carried = <double>[];
  var idx = 0;
  var last = prev.first.y;
  for (final b in grid) {
    final bMs = b * 1000.0;
    while (idx < prev.length && prev[idx].x <= bMs) {
      last = prev[idx].y;
      idx++;
    }
    carried.add(last);
  }
  final anchor = carried.last;
  if (anchor <= 0) {
    return [for (final b in grid) Point(b * 1000.0, currentValue)];
  }
  return [
    for (var i = 0; i < grid.length; i++)
      Point(grid[i] * 1000.0, currentValue * carried[i] / anchor)
  ];
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
