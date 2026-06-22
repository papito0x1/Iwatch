import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/candle.dart';
import '../services/solana_service.dart';
import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';
import 'candle_chart.dart';

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

  @override
  void didUpdateWidget(PriceChartSection old) {
    super.didUpdateWidget(old);
    // Switching tokens reuses this State (same widget position), so the new
    // token's chart must be (re)loaded here — initState only runs once. Deferred
    // to post-frame so loadChart's notifyListeners doesn't fire during build.
    if (old.tokenId != widget.tokenId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  void _load() {
    if (!mounted) return;
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

    // Show the chart's current (last) candle close so the header price stays in
    // sync with the candle; fall back to the live quote before candles load.
    final headerPrice = candles.isNotEmpty ? candles.last.close : row?.price;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                price: headerPrice,
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
    // Show the spinner while loading *or* before the first load has been kicked
    // off (empty with no error yet) — avoids a "No chart data yet" flash when
    // switching tokens.
    if (candles.isEmpty && error == null) {
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

/// "BTC" reference chart — a candle chart for Bitcoin (via a wBTC pool) shown
/// beside a token's price chart. Reuses the same candle pipeline and helpers as
/// [PriceChartSection]; the only difference is the id is fixed to the wBTC mint,
/// so BTC resolves even for wallets that hold no BTC.
class BtcChartSection extends StatefulWidget {
  const BtcChartSection({super.key});

  @override
  State<BtcChartSection> createState() => _BtcChartSectionState();
}

class _BtcChartSectionState extends State<BtcChartSection> {
  static const _id = SolanaService.btcMint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _load() {
    if (!mounted) return;
    final m = context.read<WalletModel>();
    m.loadChart(_id, m.chartRangeFor(_id));
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<WalletModel>();
    final candles = m.chartFor(_id);
    final range = m.chartRangeFor(_id);
    final loading = m.chartLoadingFor(_id);
    final error = m.chartErrorFor(_id);

    // Header price tracks the latest candle close (the wallet holds no BTC, so
    // there's no live quote to fall back on). Change is omitted — the OHLC
    // legend already shows the range move.
    final headerPrice = candles.isNotEmpty ? candles.last.close : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                symbol: 'BTC',
                price: headerPrice,
                change: null,
              ),
              const SizedBox(height: 10),
              _RangeSelector(
                range: range,
                loading: loading,
                onSelect: (r) => m.setChartRange(_id, r),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: _ChartBody(
                  candles: candles,
                  loading: loading,
                  error: error,
                  symbol: 'BTC',
                  rangeLabel: range.label,
                  onRetry: () => m.refreshChart(_id),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
