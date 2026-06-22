import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/candle.dart';
import '../theme.dart';
import '../utils/format.dart';

/// Computes the chart viewport (start, end as fractional candle indices) after
/// the candle list changes. `(null, null)` means the default fit-all view.
///
/// Rules:
/// - Series change (token/range switch — different first timestamp, or either
///   list empty): reset to the default view.
/// - Same series with new bars appended while zoomed: if the view was parked at
///   the live edge, follow the newest bar keeping the same zoom span; otherwise
///   (panned back into history) leave it on the same bars.
/// - Otherwise: unchanged.
///
/// Pure (no widget state) so the live-follow behaviour can be unit-tested.
@visibleForTesting
(double?, double?) nextViewport({
  required double? start,
  required double? end,
  required List<Candle> oldCandles,
  required List<Candle> newCandles,
}) {
  final seriesChanged = oldCandles.isEmpty ||
      newCandles.isEmpty ||
      oldCandles.first.time != newCandles.first.time;
  if (seriesChanged) return (null, null);

  if (end != null && newCandles.length != oldCandles.length) {
    final oldN = oldCandles.length.toDouble();
    if (end >= oldN - 0.5) {
      // Was at the live edge — follow it, preserving the visible span.
      final span = end - (start ?? 0);
      final newN = newCandles.length.toDouble();
      return (math.max(0, newN - span), newN);
    }
  }
  return (start, end);
}

/// A TradingView / jup.ag-style candlestick chart: OHLC candles with wicks in
/// the upper band, a volume histogram in a separate lower band, a right-hand
/// price axis with a live last-price tag, time labels along the bottom, an
/// OHLC legend in the top-left that follows the cursor, and a dashed crosshair
/// on hover.
///
/// Interaction (TradingView-style):
/// - scroll wheel zooms in/out, anchored on the cursor;
/// - click-drag pans through time;
/// - a "scroll to latest" button (bottom-right) resets the view to the full
///   range. It only appears once you've zoomed or panned away.
/// The price axis auto-scales to whatever candles are currently in view.
class CandleChart extends StatefulWidget {
  const CandleChart({
    super.key,
    required this.candles,
    required this.symbol,
    this.rangeLabel = '',
    this.height = 300,
  });

  final List<Candle> candles;
  final String symbol;
  final String rangeLabel;
  final double height;

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  int? _hoverIndex;

  // Visible window in fractional candle-index units. null => default (full
  // range). Candles only reload on a range change, so indices stay valid.
  double? _viewStart;
  double? _viewEnd;
  double _panZoomScale = 1.0; // cumulative scale during a trackpad pinch

  static const _minSpan = 8.0; // most-zoomed-in: at least this many candles

  @override
  void didUpdateWidget(CandleChart old) {
    super.didUpdateWidget(old);
    final next = nextViewport(
        start: _viewStart,
        end: _viewEnd,
        oldCandles: old.candles,
        newCandles: widget.candles);
    _viewStart = next.$1;
    _viewEnd = next.$2;
    // Drop the crosshair when the series itself changed (token/range switch).
    if (old.candles.isEmpty ||
        widget.candles.isEmpty ||
        old.candles.first.time != widget.candles.first.time) {
      _hoverIndex = null;
    }
  }

  bool get _isDefaultView => _viewStart == null && _viewEnd == null;

  double get _start => _viewStart ?? 0;
  double get _end => _viewEnd ?? widget.candles.length.toDouble();

  double _plotWidth() {
    final w = (context.findRenderObject() as RenderBox?)?.size.width ?? 300;
    return w - _Chart.priceAxisWidth;
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.candles;
    if (cs.length < 2) {
      return SizedBox(
        height: widget.height,
        child: const Center(
          child: Text('No chart data yet',
              style: TextStyle(color: AppColors.muted2, fontSize: 13)),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: Listener(
        onPointerSignal: (e) {
          // Mouse wheel (and trackpad two-finger scroll on some platforms).
          if (e is PointerScrollEvent) {
            _zoomBy(e.localPosition, e.scrollDelta.dy < 0 ? 0.85 : 1 / 0.85);
          } else if (e is PointerScaleEvent) {
            // Trackpad pinch delivered as a scale signal (macOS/web).
            _zoomBy(e.localPosition, e.scale != 0 ? 1 / e.scale : 1.0);
          }
        },
        // Trackpad gestures (Linux/Wayland/X11): pinch to zoom, two-finger
        // horizontal swipe to pan. This is what laptops actually send.
        onPointerPanZoomStart: (_) => _panZoomScale = 1.0,
        onPointerPanZoomUpdate: (e) {
          final ratio = _panZoomScale == 0 ? 1.0 : e.scale / _panZoomScale;
          _panZoomScale = e.scale;
          if ((ratio - 1).abs() > 0.002) {
            _zoomBy(e.localPosition, 1 / ratio); // pinch
          } else if (e.panDelta.dx.abs() > e.panDelta.dy.abs()) {
            _pan(e.panDelta.dx); // two-finger horizontal swipe
          }
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          onHover: (e) => _updateHover(e.localPosition, cs),
          onExit: (_) => _clearHover(),
          child: GestureDetector(
            // Horizontal-only so vertical drags still scroll the page.
            onHorizontalDragUpdate: (e) => _pan(e.delta.dx),
            onDoubleTap: _reset,
            child: Stack(
              children: [
                Positioned.fill(
                  child: _Chart(
                    candles: cs,
                    symbol: widget.symbol,
                    rangeLabel: widget.rangeLabel,
                    hoverIndex: _hoverIndex,
                    start: _start,
                    end: _end,
                  ),
                ),
                if (!_isDefaultView)
                  Positioned(
                    right: _Chart.priceAxisWidth + 8,
                    bottom: _Chart.timeAxisHeight + 8,
                    child: _ResetButton(onTap: _reset),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _updateHover(Offset pos, List<Candle> cs) {
    final plotW = _plotWidth();
    if (pos.dx < 0 || pos.dx > plotW) return _clearHover();
    final span = _end - _start;
    final idx = (_start + (pos.dx / plotW) * span).floor().clamp(0, cs.length - 1);
    if (_hoverIndex != idx) setState(() => _hoverIndex = idx);
  }

  void _clearHover() {
    if (_hoverIndex != null) setState(() => _hoverIndex = null);
  }

  /// Zoom around [pos] by [factor]: <1 zooms in (fewer candles), >1 zooms out.
  /// Used by the mouse wheel, trackpad pinch, and trackpad pinch-signal.
  void _zoomBy(Offset pos, double factor) {
    if (factor == 1.0 || factor <= 0) return;
    final n = widget.candles.length.toDouble();
    final plotW = _plotWidth();
    final start = _start, end = _end;
    final span = end - start;
    final frac = (pos.dx / plotW).clamp(0.0, 1.0);
    final anchor = start + frac * span; // candle index under the cursor

    final newSpan = (span * factor).clamp(_minSpan, n);
    if (newSpan >= n) return _reset(); // fully zoomed out => default view

    var newStart = anchor - frac * newSpan;
    var newEnd = newStart + newSpan;
    (newStart, newEnd) = _clampWindow(newStart, newEnd, n);
    setState(() {
      _viewStart = newStart;
      _viewEnd = newEnd;
    });
  }

  void _pan(double dx) {
    if (_isDefaultView) return; // nothing to pan when showing everything
    final n = widget.candles.length.toDouble();
    final plotW = _plotWidth();
    final span = _end - _start;
    final d = -(dx / plotW) * span; // drag right => move back in time
    var (newStart, newEnd) = _clampWindow(_start + d, _end + d, n);
    setState(() {
      _viewStart = newStart;
      _viewEnd = newEnd;
    });
  }

  (double, double) _clampWindow(double start, double end, double n) {
    final span = end - start;
    if (start < 0) {
      start = 0;
      end = span;
    }
    if (end > n) {
      end = n;
      start = n - span;
    }
    return (math.max(0, start), math.min(n, end));
  }

  void _reset() {
    if (_isDefaultView) return;
    setState(() {
      _viewStart = null;
      _viewEnd = null;
    });
  }
}

/// "Scroll to latest" / reset-view button, like TradingView's bottom-right
/// affordance that appears once you've moved away from the live edge.
class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Reset view',
      child: Material(
        color: AppColors.cardHi,
        shape: const CircleBorder(
            side: BorderSide(color: AppColors.borderStrong)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: const SizedBox(
            width: 30,
            height: 30,
            child: Icon(Icons.keyboard_double_arrow_right,
                size: 18, color: AppColors.text2),
          ),
        ),
      ),
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({
    required this.candles,
    required this.symbol,
    required this.rangeLabel,
    required this.hoverIndex,
    required this.start,
    required this.end,
  });

  final List<Candle> candles;
  final String symbol;
  final String rangeLabel;
  final int? hoverIndex;
  final double start;
  final double end;

  static const priceAxisWidth = 62.0;
  static const timeAxisHeight = 20.0;

  @override
  Widget build(BuildContext context) {
    // No background — the chart blends into the surrounding card.
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _CandlePainter(
                candles: candles,
                hoverIndex: hoverIndex,
                start: start,
                end: end,
              ),
            ),
          ),
        ),
        Positioned(
          left: 2,
          top: 4,
          right: priceAxisWidth + 8,
          child: _Legend(
            candles: candles,
            symbol: symbol,
            rangeLabel: rangeLabel,
            hoverIndex: hoverIndex,
          ),
        ),
      ],
    );
  }
}

/// Top-left OHLC legend, jup.ag style. Reflects the hovered candle, or the
/// latest candle when not hovering.
class _Legend extends StatelessWidget {
  const _Legend({
    required this.candles,
    required this.symbol,
    required this.rangeLabel,
    required this.hoverIndex,
  });

  final List<Candle> candles;
  final String symbol;
  final String rangeLabel;
  final int? hoverIndex;

  @override
  Widget build(BuildContext context) {
    final c = candles[hoverIndex ?? candles.length - 1];
    final chg = c.open == 0 ? 0.0 : ((c.close - c.open) / c.open) * 100;
    final col = c.isUp ? AppColors.up : AppColors.down;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '$symbol/USD',
              style: const TextStyle(
                  color: AppColors.text2,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
            if (rangeLabel.isNotEmpty)
              Text('  ·  $rangeLabel',
                  style: const TextStyle(color: AppColors.muted2, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 3),
        Wrap(
          spacing: 8,
          runSpacing: 2,
          children: [
            _ohlc('O', c.open, col),
            _ohlc('H', c.high, col),
            _ohlc('L', c.low, col),
            _ohlc('C', c.close, col),
            Text(
              '${chg >= 0 ? '+' : ''}${chg.toStringAsFixed(2)}%',
              style: TextStyle(
                  color: col,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
        const SizedBox(height: 3),
        RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 11),
            children: [
              const TextSpan(
                  text: 'Vol ', style: TextStyle(color: AppColors.muted2)),
              TextSpan(
                text: fmtCompactUsd(c.volume),
                style: TextStyle(
                    color: col.withValues(alpha: 0.95),
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ohlc(String k, double v, Color col) => RichText(
        text: TextSpan(
          style: const TextStyle(
              fontSize: 11, fontFeatures: [FontFeature.tabularFigures()]),
          children: [
            TextSpan(text: '$k ', style: const TextStyle(color: AppColors.muted2)),
            TextSpan(
                text: fmtPrice(v),
                style:
                    TextStyle(color: col, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.candles,
    required this.hoverIndex,
    required this.start,
    required this.end,
  });

  final List<Candle> candles;
  final int? hoverIndex;
  final double start;
  final double end;

  static const _volumeBandRatio = 0.20; // bottom share for the volume band
  static const _bandGap = 10.0; // gap between price and volume bands

  @override
  void paint(Canvas canvas, Size size) {
    final n = candles.length;
    final plotW = size.width - _Chart.priceAxisWidth;
    final plotH = size.height - _Chart.timeAxisHeight;
    final volH = plotH * _volumeBandRatio;
    final priceH = plotH - volH - _bandGap; // price candles live in [0, priceH]

    final span = (end - start) <= 0 ? n.toDouble() : end - start;
    final slot = plotW / span;
    // Visible candle index range (with a little overscan).
    final firstVis = math.max(0, start.floor() - 1);
    final lastVis = math.min(n - 1, end.ceil());

    // Price + volume extents over the *visible* candles (auto-scale).
    double lo = double.infinity, hi = double.negativeInfinity, volMax = 0;
    for (var i = firstVis; i <= lastVis; i++) {
      final c = candles[i];
      if (c.low < lo) lo = c.low;
      if (c.high > hi) hi = c.high;
      if (c.volume > volMax) volMax = c.volume;
    }
    if (!lo.isFinite || !hi.isFinite) return;
    final pad = (hi - lo) * 0.06;
    final yMin = lo - pad;
    final yMax = hi + pad;
    final priceSpan =
        (yMax - yMin) <= 0 || !(yMax - yMin).isFinite ? 1.0 : yMax - yMin;

    double y(double price) => priceH - ((price - yMin) / priceSpan) * priceH;
    double xOf(int i) => (i + 0.5 - start) * slot;

    _drawGrid(canvas, plotW, yMin, yMax, y);
    _drawPriceAxis(canvas, size, plotW, yMin, yMax, y);

    final bodyW = (slot * 0.7).clamp(1.0, 16.0);
    final upPaint = Paint()..color = AppColors.up;
    final downPaint = Paint()..color = AppColors.down;
    final upWick = Paint()
      ..color = AppColors.up
      ..strokeWidth = 1;
    final downWick = Paint()
      ..color = AppColors.down
      ..strokeWidth = 1;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, plotW, plotH));
    for (var i = firstVis; i <= lastVis; i++) {
      final c = candles[i];
      final cx = xOf(i);
      final isUp = c.isUp;

      if (volMax > 0) {
        final vh = (c.volume / volMax) * volH;
        canvas.drawRect(
          Rect.fromLTWH(cx - bodyW / 2, plotH - vh, bodyW, vh),
          Paint()
            ..color =
                (isUp ? AppColors.up : AppColors.down).withValues(alpha: 0.45),
        );
      }

      canvas.drawLine(
          Offset(cx, y(c.high)), Offset(cx, y(c.low)), isUp ? upWick : downWick);

      final yOpen = y(c.open), yClose = y(c.close);
      final top = math.min(yOpen, yClose);
      final h = (yClose - yOpen).abs().clamp(1.0, double.infinity);
      canvas.drawRect(Rect.fromLTWH(cx - bodyW / 2, top, bodyW, h),
          isUp ? upPaint : downPaint);
    }
    canvas.restore();

    // Faint separator above the volume band.
    final sepY = priceH + _bandGap / 2;
    canvas.drawLine(Offset(0, sepY), Offset(plotW, sepY),
        Paint()..color = AppColors.chartGrid);

    _drawTimeAxis(canvas, plotH, slot, firstVis, lastVis);

    // Last-price line/tag only when the newest candle is in view.
    if (end >= n - 0.5) _drawLastPrice(canvas, size, plotW, y);

    if (hoverIndex != null && hoverIndex! >= firstVis && hoverIndex! <= lastVis) {
      _drawCrosshair(
          canvas, size, plotW, priceH, xOf(hoverIndex!), candles[hoverIndex!], y);
    }
  }

  void _drawGrid(Canvas canvas, double plotW, double yMin, double yMax,
      double Function(double) y) {
    final paint = Paint()
      ..color = AppColors.chartGrid
      ..strokeWidth = 1;
    const steps = 5;
    final span = yMax - yMin;
    for (var i = 0; i <= steps; i++) {
      final gy = y(yMin + span * i / steps);
      canvas.drawLine(Offset(0, gy), Offset(plotW, gy), paint);
    }
  }

  void _drawPriceAxis(Canvas canvas, Size size, double plotW, double yMin,
      double yMax, double Function(double) y) {
    const steps = 5;
    final span = yMax - yMin;
    for (var i = 0; i <= steps; i++) {
      final v = yMin + span * i / steps;
      final tp = _text(fmtPrice(v), AppColors.chartAxis, 10);
      tp.paint(canvas, Offset(plotW + 7, y(v) - tp.height / 2));
    }
  }

  void _drawTimeAxis(
      Canvas canvas, double plotH, double slot, int firstVis, int lastVis) {
    final visCount = lastVis - firstVis + 1;
    final count = visCount >= 6 ? 6 : visCount;
    final step = (visCount / count).floor().clamp(1, visCount);
    final labelY = plotH + 4;
    final spanSec = candles[lastVis].time - candles[firstVis].time;
    final showDate = spanSec > 2 * 86400;
    for (var i = firstVis; i <= lastVis; i += step) {
      final cx = (i + 0.5 - start) * slot;
      if (cx < 0 || cx > (slot * (end - start))) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(candles[i].time * 1000);
      final label = showDate
          ? '${dt.month}/${dt.day}'
          : '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      final tp = _text(label, AppColors.chartAxis, 10);
      tp.paint(canvas, Offset(cx - tp.width / 2, labelY));
    }
  }

  void _drawLastPrice(
      Canvas canvas, Size size, double plotW, double Function(double) y) {
    final c = candles.last;
    final col = c.isUp ? AppColors.up : AppColors.down;
    final ly = y(c.close);
    _dashedLine(canvas, Offset(0, ly), Offset(plotW, ly),
        Paint()
          ..color = col.withValues(alpha: 0.7)
          ..strokeWidth = 1);
    _priceTag(canvas, size, plotW, ly, fmtPrice(c.close), col, Colors.white);
  }

  void _drawCrosshair(Canvas canvas, Size size, double plotW, double priceH,
      double cx, Candle c, double Function(double) y) {
    final paint = Paint()
      ..color = AppColors.borderStrong
      ..strokeWidth = 1;
    _dashedLine(canvas, Offset(cx, 0), Offset(cx, priceH), paint);
    final cy = y(c.close);
    _dashedLine(canvas, Offset(0, cy), Offset(plotW, cy), paint);
    _priceTag(canvas, size, plotW, cy, fmtPrice(c.close), AppColors.cardHi,
        AppColors.text);
  }

  void _priceTag(Canvas canvas, Size size, double plotW, double cy, String text,
      Color bg, Color fg) {
    final tp = _text(text, fg, 10, weight: FontWeight.w600);
    final h = tp.height + 6;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(plotW + 1, cy - h / 2, _Chart.priceAxisWidth - 2, h),
      const Radius.circular(3),
    );
    canvas.drawRRect(rect, Paint()..color = bg);
    tp.paint(canvas, Offset(plotW + 7, cy - tp.height / 2));
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint p,
      {double dash = 4, double gap = 4}) {
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final s = a + dir * d;
      final e = a + dir * math.min(d + dash, total);
      canvas.drawLine(s, e, p);
      d += dash + gap;
    }
  }

  TextPainter _text(String s, Color color, double size,
      {FontWeight weight = FontWeight.w400}) {
    return TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: weight,
            fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(_CandlePainter old) =>
      old.candles != candles ||
      old.hoverIndex != hoverIndex ||
      old.start != start ||
      old.end != end;
}
