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

    test('carry-forward holds the last close until the next candle', () {
      final candles = [c(0, 10), c(1800, 20)];
      final s = balanceSeriesOnGrid(grid, candles, 2, 0);
      expect(s.map((p) => p.y).toList(), [20, 20, 40, 40]);
      // x is the bucket time in milliseconds.
      expect(s.map((p) => p.x).toList(), [0, 900000, 1800000, 2700000]);
    });

    test('back-fills the head with the earliest close', () {
      final candles = [c(1800, 30)]; // nothing for the first two buckets
      final s = balanceSeriesOnGrid(grid, candles, 1, 0);
      expect(s.map((p) => p.y).toList(), [30, 30, 30, 30]);
    });

    test('falls back to a flat line at the current value with no candles', () {
      final s = balanceSeriesOnGrid(grid, const [], 5, 42);
      expect(s.map((p) => p.y).toList(), [42, 42, 42, 42]);
    });

    test('scales close by the holding amount', () {
      final s = balanceSeriesOnGrid([0], [c(0, 2.5)], 4, 0);
      expect(s.single.y, 10);
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
