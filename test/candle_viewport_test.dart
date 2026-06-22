import 'package:flutter_test/flutter_test.dart';
import 'package:iwatch/models/candle.dart';
import 'package:iwatch/widgets/candle_chart.dart';

List<Candle> series(int n, {int startTime = 1000, int step = 3600}) => [
      for (var i = 0; i < n; i++)
        Candle(
          time: startTime + i * step,
          open: 1,
          high: 1,
          low: 1,
          close: 1,
          volume: 1,
        ),
    ];

void main() {
  group('nextViewport', () {
    test('default view stays default when a bar is appended', () {
      final r = nextViewport(
        start: null,
        end: null,
        oldCandles: series(100),
        newCandles: series(101),
      );
      expect(r, (null, null)); // fit-all auto-includes the new bar
    });

    test('zoomed at the live edge follows the new bar, same span', () {
      // Viewing bars [60, 100) of 100, parked at the right edge.
      final r = nextViewport(
        start: 60,
        end: 100,
        oldCandles: series(100),
        newCandles: series(101),
      );
      expect(r, (61.0, 101.0)); // shifted right by one, span 40 preserved
    });

    test('zoomed into history stays put when a bar is appended', () {
      // Viewing bars [20, 60) of 100 — not at the edge.
      final r = nextViewport(
        start: 20,
        end: 60,
        oldCandles: series(100),
        newCandles: series(101),
      );
      expect(r, (20.0, 60.0)); // unchanged; new bar stays off-screen
    });

    test('series change (different first timestamp) resets to default', () {
      final r = nextViewport(
        start: 60,
        end: 100,
        oldCandles: series(100, startTime: 1000),
        newCandles: series(100, startTime: 999999), // e.g. token/range switch
      );
      expect(r, (null, null));
    });

    test('intra-bar update (same length) keeps the zoomed view', () {
      final r = nextViewport(
        start: 60,
        end: 100,
        oldCandles: series(100),
        newCandles: series(100), // same count, last bar mutated
      );
      expect(r, (60.0, 100.0));
    });

    test('following never produces a negative start', () {
      final r = nextViewport(
        start: 0,
        end: 5,
        oldCandles: series(5),
        newCandles: series(6),
      );
      expect(r.$1, isNonNegative);
      expect(r.$2, 6.0);
    });
  });
}
