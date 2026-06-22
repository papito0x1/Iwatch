import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/candle.dart';
import '../theme.dart';
import '../utils/format.dart';

/// A TradingView / jup.ag-style candlestick chart: OHLC candles with wicks in
/// the upper band, a volume histogram in a separate lower band, a right-hand
/// price axis with a live last-price tag, time labels along the bottom, an
/// OHLC legend in the top-left that follows the cursor, and a dashed crosshair
/// on hover.
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
      child: MouseRegion(
        onHover: (e) => _updateHover(e.localPosition, cs),
        onExit: (_) => _clearHover(),
        child: GestureDetector(
          onPanUpdate: (e) => _updateHover(e.localPosition, cs),
          onTapDown: (d) => _updateHover(d.localPosition, cs),
          child: _Chart(
            candles: cs,
            symbol: widget.symbol,
            rangeLabel: widget.rangeLabel,
            hoverIndex: _hoverIndex,
            height: widget.height,
          ),
        ),
      ),
    );
  }

  void _updateHover(Offset pos, List<Candle> cs) {
    final w = (context.findRenderObject() as RenderBox?)?.size.width ?? 300;
    final plotW = w - _Chart.priceAxisWidth;
    if (pos.dx < 0 || pos.dx > plotW) return;
    final slot = plotW / cs.length;
    final i = (pos.dx / slot).floor().clamp(0, cs.length - 1);
    if (_hoverIndex != i) setState(() => _hoverIndex = i);
  }

  void _clearHover() {
    if (_hoverIndex != null) setState(() => _hoverIndex = null);
  }
}

class _Chart extends StatelessWidget {
  const _Chart({
    required this.candles,
    required this.symbol,
    required this.rangeLabel,
    required this.hoverIndex,
    required this.height,
  });

  final List<Candle> candles;
  final String symbol;
  final String rangeLabel;
  final int? hoverIndex;
  final double height;

  static const priceAxisWidth = 62.0;
  static const timeAxisHeight = 20.0;

  @override
  Widget build(BuildContext context) {
    // No background — the chart blends into the surrounding card.
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _CandlePainter(
              candles: candles,
              hoverIndex: hoverIndex,
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
  _CandlePainter({required this.candles, required this.hoverIndex});

  final List<Candle> candles;
  final int? hoverIndex;

  static const _volumeBandRatio = 0.20; // bottom share for the volume band
  static const _bandGap = 10.0; // gap between price and volume bands

  @override
  void paint(Canvas canvas, Size size) {
    final n = candles.length;
    final plotW = size.width - _Chart.priceAxisWidth;
    final plotH = size.height - _Chart.timeAxisHeight;
    final volH = plotH * _volumeBandRatio;
    final priceH = plotH - volH - _bandGap; // price candles live in [0, priceH]

    // Price + volume extents.
    double lo = double.infinity, hi = double.negativeInfinity, volMax = 0;
    for (final c in candles) {
      if (c.low < lo) lo = c.low;
      if (c.high > hi) hi = c.high;
      if (c.volume > volMax) volMax = c.volume;
    }
    if (!lo.isFinite || !hi.isFinite) return;
    final pad = (hi - lo) * 0.06;
    final yMin = lo - pad;
    final yMax = hi + pad;
    final span = (yMax - yMin) <= 0 || !(yMax - yMin).isFinite ? 1.0 : yMax - yMin;

    double y(double price) => priceH - ((price - yMin) / span) * priceH;

    _drawGrid(canvas, plotW, priceH, yMin, yMax, y);
    _drawPriceAxis(canvas, size, plotW, yMin, yMax, y);

    final slot = plotW / n;
    final bodyW = (slot * 0.7).clamp(1.0, 14.0);

    final upPaint = Paint()..color = AppColors.up;
    final downPaint = Paint()..color = AppColors.down;
    final upWick = Paint()
      ..color = AppColors.up
      ..strokeWidth = 1;
    final downWick = Paint()
      ..color = AppColors.down
      ..strokeWidth = 1;

    final volTop = priceH + _bandGap;
    for (var i = 0; i < n; i++) {
      final c = candles[i];
      final cx = i * slot + slot / 2;
      final isUp = c.isUp;

      // Volume bar in its own bottom band.
      if (volMax > 0) {
        final vh = (c.volume / volMax) * volH;
        canvas.drawRect(
          Rect.fromLTWH(cx - bodyW / 2, plotH - vh, bodyW, vh),
          Paint()
            ..color =
                (isUp ? AppColors.up : AppColors.down).withValues(alpha: 0.45),
        );
      }

      // Wick.
      canvas.drawLine(
          Offset(cx, y(c.high)), Offset(cx, y(c.low)), isUp ? upWick : downWick);

      // Body.
      final yOpen = y(c.open), yClose = y(c.close);
      final top = math.min(yOpen, yClose);
      final h = (yClose - yOpen).abs().clamp(1.0, double.infinity);
      canvas.drawRect(Rect.fromLTWH(cx - bodyW / 2, top, bodyW, h),
          isUp ? upPaint : downPaint);
    }
    // Faint separator above the volume band.
    canvas.drawLine(Offset(0, volTop - _bandGap / 2),
        Offset(plotW, volTop - _bandGap / 2), Paint()..color = AppColors.chartGrid);

    _drawTimeAxis(canvas, plotH, slot, n);
    _drawLastPrice(canvas, size, plotW, y);

    if (hoverIndex != null) {
      final i = hoverIndex!;
      _drawCrosshair(canvas, size, plotW, priceH, i * slot + slot / 2,
          candles[i], y);
    }
  }

  void _drawGrid(Canvas canvas, double plotW, double priceH, double yMin,
      double yMax, double Function(double) y) {
    final paint = Paint()
      ..color = AppColors.chartGrid
      ..strokeWidth = 1;
    const steps = 5;
    final span = yMax - yMin;
    for (var i = 0; i <= steps; i++) {
      final v = yMin + span * i / steps;
      final gy = y(v);
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

  void _drawTimeAxis(Canvas canvas, double plotH, double slot, int n) {
    final count = n >= 6 ? 6 : n;
    final step = (n / count).floor().clamp(1, n);
    final labelY = plotH + 4;
    // Show times for an intraday span, dates once it covers multiple days.
    final spanSec = candles.last.time - candles.first.time;
    final showDate = spanSec > 2 * 86400;
    for (var i = 0; i < n; i += step) {
      final cx = i * slot + slot / 2;
      final dt = DateTime.fromMillisecondsSinceEpoch(candles[i].time * 1000);
      final label = showDate
          ? '${dt.month}/${dt.day}'
          : '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      final tp = _text(label, AppColors.chartAxis, 10);
      tp.paint(canvas, Offset(cx - tp.width / 2, labelY));
    }
  }

  /// Always-on last-price line + colored tag on the right axis (jup style).
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
      Rect.fromLTWH(plotW + 1, cy - h / 2,
          _Chart.priceAxisWidth - 2, h),
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
      final start = a + dir * d;
      final end = a + dir * math.min(d + dash, total);
      canvas.drawLine(start, end, p);
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
      old.candles != candles || old.hoverIndex != hoverIndex;
}
