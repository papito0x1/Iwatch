import 'package:flutter_test/flutter_test.dart';
import 'package:iwatch/models/candle.dart';

Candle c(int time, {double open = 10, double high = 12, double low = 9, double close = 11, double volume = 5}) =>
    Candle(time: time, open: open, high: high, low: low, close: close, volume: volume);

void main() {
  group('advanceCandles', () {
    const bucket = 300; // 5-minute candles

    test('opens a new candle once the clock crosses the bucket boundary', () {
      final series = [c(0), c(300, close: 11)];
      // now is inside the next (600) bucket — a new candle should print.
      final r = advanceCandles(series, 615, bucket, 11.5);
      expect(r, isNotNull);
      expect(r!.length, 3);
      final fresh = r.last;
      expect(fresh.time, 600); // aligned to the epoch bucket
      expect(fresh.open, 11); // opens at the previous close
      expect(fresh.close, 11.5);
      expect(fresh.high, 11.5);
      expect(fresh.low, 11); // wick stretches from the open
    });

    test('refines the forming candle within the same bucket', () {
      final series = [c(0), c(300, high: 12, low: 9, close: 11)];
      final r = advanceCandles(series, 400, bucket, 13); // new high, same bucket
      expect(r, isNotNull);
      expect(r!.length, 2); // no new candle
      final last = r.last;
      expect(last.time, 300);
      expect(last.close, 13);
      expect(last.high, 13); // high stretched up
      expect(last.low, 9); // low unchanged
    });

    test('returns null when the price changes nothing in the same bucket', () {
      final series = [c(300, high: 12, low: 9, close: 11)];
      final r = advanceCandles(series, 400, bucket, 11); // same close, within range
      expect(r, isNull);
    });

    test('rolls forward flat with no live price (timer sweep)', () {
      final series = [c(300, close: 11)];
      final r = advanceCandles(series, 605, bucket, null);
      expect(r, isNotNull);
      expect(r!.length, 2);
      final fresh = r.last;
      expect(fresh.time, 600);
      expect(fresh.open, 11);
      expect(fresh.close, 11); // flat — tracks the last close
      expect(fresh.high, 11);
      expect(fresh.low, 11);
      expect(fresh.volume, 0);
    });

    test('no price + same bucket leaves the series untouched', () {
      final series = [c(300, close: 11)];
      final r = advanceCandles(series, 450, bucket, null);
      expect(r, isNull);
    });

    test('skips empty series and bad bucket sizes', () {
      expect(advanceCandles(const [], 600, bucket, 11), isNull);
      expect(advanceCandles([c(300)], 600, 0, 11), isNull);
    });

    test('does not mutate the input series', () {
      final series = [c(0), c(300, close: 11)];
      final copy = [...series];
      advanceCandles(series, 615, bucket, 12);
      expect(series, copy); // same elements, unchanged
      expect(series.length, 2);
    });
  });
}
