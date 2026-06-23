import 'package:flutter_test/flutter_test.dart';
import 'package:iwatch/models/balance_graph.dart';
import 'package:iwatch/models/models.dart';

Candle c(int time, double close) =>
    Candle(time: time, open: close, high: close, low: close, close: close, volume: 0);

void main() {
  group('BalanceRange', () {
    test('windows cover the advertised spans', () {
      expect(BalanceRange.d1.windowSec, 24 * 60 * 60);
      expect(BalanceRange.w1.windowSec, 7 * 24 * 60 * 60);
      expect(BalanceRange.m1.windowSec, 30 * 24 * 60 * 60);
    });
  });

  group('balanceGrid', () {
    test('is ascending, bucket-aligned and ends at the current bucket', () {
      const r = BalanceRange.d1; // 900s buckets, 96 of them
      final grid = balanceGrid(r, 100000);
      expect(grid.length, r.buckets);
      expect(grid.last, (100000 ~/ 900) * 900); // current bucket start
      for (var i = 1; i < grid.length; i++) {
        expect(grid[i] - grid[i - 1], r.bucketSec); // evenly spaced
      }
    });
  });

  group('balanceSeriesOnGrid', () {
    final grid = [0, 900, 1800, 2700];

    test('anchors the latest bucket to the current value, scaling history by ratio', () {
      // closes carry-forward to [10,10,20,20]; latest 20 anchors to value 80.
      final s = balanceSeriesOnGrid(grid, [c(0, 10), c(1800, 20)], 80);
      expect(s.map((p) => p.y).toList(), [40, 40, 80, 80]);
      // x is the bucket time in milliseconds.
      expect(s.map((p) => p.x).toList(), [0, 900000, 1800000, 2700000]);
    });

    test('back-fills the head with the earliest close', () {
      final candles = [c(1800, 30)]; // nothing for the first two buckets
      final s = balanceSeriesOnGrid(grid, candles, 99);
      // every bucket carries the one close → flat at the current value.
      expect(s.map((p) => p.y).toList(), [99, 99, 99, 99]);
    });

    test('falls back to a flat line at the current value with no candles', () {
      final s = balanceSeriesOnGrid(grid, const [], 42);
      expect(s.map((p) => p.y).toList(), [42, 42, 42, 42]);
    });

    test('is scale-invariant — an odd pool unit never blows up the magnitude', () {
      // A pool quoting in huge units (~1e9) must stay anchored to the real value.
      final s = balanceSeriesOnGrid([0, 900], [c(0, 1.1e9), c(900, 1.0e9)], 1676);
      expect(s.last.y, closeTo(1676, 0.01)); // latest anchors to current value
      expect(s.first.y, closeTo(1843.6, 0.1)); // earlier scaled by 1.1 ratio
    });
  });

  group('reuseSeriesOnGrid', () {
    test('carry-forwards a prior series onto a shifted grid, anchored to value', () {
      // prev is on buckets 0,900,1800; new grid shifts to 900,1800,2700.
      final prev = [Point(0, 10), Point(900000, 20), Point(1800000, 30)];
      // carried = [20,30,30]; anchor last (30) to currentValue 30 → unchanged.
      final s = reuseSeriesOnGrid([900, 1800, 2700], prev, 30);
      expect(s.map((p) => p.y).toList(), [20, 30, 30]);
      expect(s.map((p) => p.x).toList(), [900000, 1800000, 2700000]);
    });

    test('re-anchors a stale / mis-scaled prior series to the current value', () {
      // prev ends at a bogus 1e9; must rescale so the latest bucket = value.
      final prev = [Point(0, 5e8), Point(900000, 1e9)];
      final s = reuseSeriesOnGrid([0, 900], prev, 100);
      expect(s.last.y, closeTo(100, 0.01));
      expect(s.first.y, closeTo(50, 0.01)); // 5e8/1e9 ratio × 100
    });

    test('falls back to a flat line when there is no prior series', () {
      final s = reuseSeriesOnGrid([0, 900], const [], 7);
      expect(s.map((p) => p.y).toList(), [7, 7]);
    });
  });

  group('advanceBalancePoint', () {
    const bucket = 900;
    const window = 900 * 4; // tiny 4-bucket window for trimming

    List<Point> seed() => [
          Point(0, 10),
          Point(900000, 11),
          Point(1800000, 12),
        ];

    test('refines the forming bucket within the same bucket', () {
      final arr = seed();
      // nowSec 2000 is still inside the 1800 bucket → no new point, retip last.
      advanceBalancePoint(arr, 2000, 99, bucket, window);
      expect(arr.length, 3);
      expect(arr.last.x, 1800000); // same bucket time
      expect(arr.last.y, 99); // value updated in place
    });

    test('opens a new bucket once the clock crosses the boundary', () {
      final arr = seed();
      advanceBalancePoint(arr, 2700, 50, bucket, window); // into the 2700 bucket
      expect(arr.length, 4);
      expect(arr.last.x, 2700000);
      expect(arr.last.y, 50);
    });

    test('drops points older than the window when a new bucket opens', () {
      // 5 buckets present; window only holds 4. nowSec well past the last one.
      final arr = [
        Point(0, 1),
        Point(900000, 2),
        Point(1800000, 3),
        Point(2700000, 4),
        Point(3600000, 5),
      ];
      advanceBalancePoint(arr, 4500, 6, bucket, window); // opens bucket 4500
      // cutoff = (4500 - 3600) * 1000 = 900000 → drop anything strictly older.
      expect(arr.first.x, greaterThanOrEqualTo(900000));
      expect(arr.last.x, 4500000);
    });

    test('is a no-op on an empty series', () {
      final arr = <Point>[];
      advanceBalancePoint(arr, 1000, 5, bucket, window);
      expect(arr, isEmpty);
    });
  });
}
