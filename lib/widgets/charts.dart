import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';
import '../utils/format.dart';

List<FlSpot> _spots(List<Point> pts) =>
    pts.map((p) => FlSpot(p.x, p.y)).toList();

/// Shared min/max helpers — fl_chart needs explicit bounds for a clean look.
({double min, double max}) _bounds(List<Point> pts, double Function(Point) sel) {
  double lo = double.infinity, hi = double.negativeInfinity;
  for (final p in pts) {
    final v = sel(p);
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  if (!lo.isFinite || !hi.isFinite) return (min: 0, max: 1);
  if (lo == hi) return (min: lo - 1, max: hi + 1);
  return (min: lo, max: hi);
}

/// Large area chart for the portfolio total (with axes + tooltips).
class TotalChart extends StatelessWidget {
  const TotalChart({super.key, required this.points, this.up, this.dateAxis = false});

  final List<Point> points;

  /// Force the trend colour; when null it is inferred from the series.
  final bool? up;

  /// Label the x-axis (and tooltip) with calendar dates rather than the
  /// time-of-day — used for the multi-day balance windows (1W / 1M) where a
  /// bare clock time would wrap around and read like hours.
  final bool dateAxis;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return const Center(
        child: Text('Collecting live history…',
            style: TextStyle(color: AppColors.muted2, fontSize: 13)),
      );
    }
    final trendUp = up ?? (points.last.y >= points.first.y);
    final color = trendUp ? AppColors.up : AppColors.down;
    final xb = _bounds(points, (p) => p.x);
    final yb = _bounds(points, (p) => p.y);
    final yPad = (yb.max - yb.min) * 0.08;

    return RepaintBoundary(
      child: LineChart(
      LineChartData(
        minX: xb.min,
        maxX: xb.max,
        minY: yb.min - yPad,
        maxY: yb.max + yPad,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: Color(0x0DFFFFFF), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              getTitlesWidget: (v, meta) {
                if (v == meta.min || v == meta.max) return const SizedBox();
                return Text(fmtCompactUsd(v),
                    style: const TextStyle(color: AppColors.muted2, fontSize: 11));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: ((xb.max - xb.min) / 5).clamp(1, double.infinity),
              getTitlesWidget: (v, meta) {
                if (v == meta.min) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      dateAxis ? fmtDate(v.toInt()) : fmtTime(v.toInt()),
                      style: const TextStyle(color: AppColors.muted2, fontSize: 11)),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => const Color(0xF20A0A12),
            tooltipBorder: const BorderSide(color: AppColors.borderStrong),
            getTooltipItems: (spots) => spots
                .map((s) => LineTooltipItem(
                      '${dateAxis ? fmtDateTime(s.x.toInt()) : fmtTime(s.x.toInt())}\n${fmtUsd(s.y)}',
                      const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 12),
                    ))
                .toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: _spots(points),
            isCurved: true,
            curveSmoothness: 0.35,
            color: color,
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withValues(alpha: 0.33), color.withValues(alpha: 0)],
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    ),
    );
  }
}

/// Compact sparkline for a token card (no axes, no touch).
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.points, required this.up});

  final List<Point> points;
  final bool up;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return const SizedBox.expand();
    }
    final color = up ? AppColors.up : AppColors.down;
    final xb = _bounds(points, (p) => p.x);
    final yb = _bounds(points, (p) => p.y);
    final yPad = (yb.max - yb.min) * 0.1;

    return RepaintBoundary(
      child: LineChart(
      LineChartData(
        minX: xb.min,
        maxX: xb.max,
        minY: yb.min - yPad,
        maxY: yb.max + yPad,
        clipData: const FlClipData.all(),
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: _spots(points),
            isCurved: true,
            curveSmoothness: 0.35,
            color: color,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withValues(alpha: 0.33), color.withValues(alpha: 0)],
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    ),
    );
  }
}
