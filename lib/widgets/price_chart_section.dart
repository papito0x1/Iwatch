import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/candle.dart';
import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';
import 'candle_chart.dart';
import 'sections.dart';

/// "Price chart" section for a single token — a TradingView-style candle chart
/// with a live price header and a jup.ag-style range selector. Placed above the
/// holdings/details in the token detail view.
class PriceChartSection extends StatefulWidget {
  const PriceChartSection({super.key, required this.tokenId});

  final String tokenId;

  @override
  State<PriceChartSection> createState() => _PriceChartSectionState();
}

class _PriceChartSectionState extends State<PriceChartSection> {
  @override
  void initState() {
    super.initState();
    // Kick off the first load after the first frame so the model is wired up.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _load() {
    final m = context.read<WalletModel>();
    m.loadChart(widget.tokenId, m.chartRangeFor(widget.tokenId));
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<WalletModel>();
    final id = widget.tokenId;
    final candles = m.chartFor(id);
    final range = m.chartRangeFor(id);
    final loading = m.chartLoadingFor(id);
    final error = m.chartErrorFor(id);
    final row = m.rowById(id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Price chart'),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(
                symbol: row?.symbol ?? '',
                price: row?.price,
                change: row?.change,
              ),
              const SizedBox(height: 10),
              _RangeSelector(
                range: range,
                loading: loading,
                onSelect: (r) => m.setChartRange(id, r),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: _ChartBody(
                  candles: candles,
                  loading: loading,
                  error: error,
                  symbol: row?.symbol ?? '',
                  rangeLabel: range.label,
                  onRetry: () => m.refreshChart(id),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.symbol, required this.price, required this.change});

  final String symbol;
  final double? price;
  final double? change;

  @override
  Widget build(BuildContext context) {
    final up = (change ?? 0) >= 0;
    final col = up ? AppColors.up : AppColors.down;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          fmtPrice(price),
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 10),
        if (change != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: col.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              fmtPct(change),
              style: TextStyle(
                color: col,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        const Spacer(),
        Text('$symbol / USD',
            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
      ],
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.range,
    required this.loading,
    required this.onSelect,
  });

  final ChartRange range;
  final bool loading;
  final ValueChanged<ChartRange> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final r in ChartRange.values) ...[
          _RangeChip(
            label: r.label,
            selected: r == range,
            onTap: () => onSelect(r),
          ),
          const SizedBox(width: 6),
        ],
        const SizedBox(width: 4),
        if (loading)
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.muted),
          ),
      ],
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.orange.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.orange : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.orange : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _ChartBody extends StatelessWidget {
  const _ChartBody({
    required this.candles,
    required this.loading,
    required this.error,
    required this.symbol,
    required this.rangeLabel,
    required this.onRetry,
  });

  final List<Candle> candles;
  final bool loading;
  final String? error;
  final String symbol;
  final String rangeLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading && candles.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
        ),
      );
    }
    if (error != null && candles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.show_chart, color: AppColors.muted2, size: 26),
            const SizedBox(height: 8),
            Text(error!,
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text2,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      );
    }
    return CandleChart(
        candles: candles, symbol: symbol, rangeLabel: rangeLabel, height: 300);
  }
}
