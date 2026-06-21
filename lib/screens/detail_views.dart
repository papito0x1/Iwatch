import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../widgets/common.dart';
import '../widgets/sections.dart';

EdgeInsets _bodyPadding(BuildContext context) =>
    const EdgeInsets.fromLTRB(28, 8, 28, 28);

void _openSolscan(String path) => launchUrl(
      Uri.parse('https://solscan.io/$path'),
      mode: LaunchMode.externalApplication,
    );

/// Detail pane for the "Portfolio" overview entry.
class PortfolioDetail extends StatelessWidget {
  const PortfolioDetail({super.key, required this.model});

  final WalletModel model;

  @override
  Widget build(BuildContext context) {
    final up = (model.totalChangePct ?? 0) >= 0;
    return ListView(
      padding: _bodyPadding(context),
      children: [
        const SectionHeader('Total value'),
        ChartCard(
          label: 'Portfolio value',
          value: fmtUsd(model.totalValue),
          points: model.totalHistory,
          up: up,
        ),
        const SizedBox(height: 24),
        const SectionHeader('Summary'),
        PropertyList(rows: [
          PropertyRow('Total value', Text(fmtUsd(model.totalValue))),
          PropertyRow('24h change', ChangeBadge(pct: model.totalChangePct)),
          PropertyRow('Tokens', Text('${model.tokenCount}')),
          PropertyRow('Shown in sidebar', Text('${model.visibleCount}')),
          PropertyRow(
            'Wallet',
            Text(shortAddr(model.address),
                style: const TextStyle(fontFamily: 'monospace')),
            onTap: () => _openSolscan('account/${model.address}'),
          ),
          PropertyRow(
              'Updated',
              Text(model.lastUpdatedMs == 0
                  ? '—'
                  : fmtTime(model.lastUpdatedMs))),
        ]),
      ],
    );
  }
}

/// Detail pane for a single token.
class TokenDetail extends StatelessWidget {
  const TokenDetail({super.key, required this.model, required this.row});

  final WalletModel model;
  final TokenRow row;

  @override
  Widget build(BuildContext context) {
    final up = (row.change ?? 0) >= 0;
    return ListView(
      padding: _bodyPadding(context),
      children: [
        const SectionHeader('Value'),
        ChartCard(
          label: 'Holdings value',
          value: fmtUsd(row.value),
          points: model.historyFor(row.id),
          up: up,
        ),
        const SizedBox(height: 24),
        const SectionHeader('Details'),
        PropertyList(rows: [
          PropertyRow('Price', Text(fmtPrice(row.price))),
          PropertyRow('24h change', ChangeBadge(pct: row.change)),
          PropertyRow('Holdings',
              Text('${fmtAmount(row.amount)} ${row.symbol}')),
          PropertyRow('Value', Text(fmtUsd(row.value))),
          PropertyRow('Name', Flexible(child: Text(row.name, overflow: TextOverflow.ellipsis))),
          if (!row.isNative)
            PropertyRow(
              'Mint',
              Text(shortAddr(row.mint),
                  style: const TextStyle(fontFamily: 'monospace')),
              onTap: () => _openSolscan('token/${row.mint}'),
            ),
        ]),
        const SizedBox(height: 24),
        const SectionHeader('Options'),
        OptionRow(
          label: 'Show in sidebar',
          subtitle: 'Hidden tokens still count toward your total value.',
          trailing: _HideButton(
            onPressed: () {
              model.select(WalletModel.portfolioId);
              model.toggleHidden(row.id, true);
            },
          ),
        ),
      ],
    );
  }
}

class _HideButton extends StatelessWidget {
  const _HideButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.visibility_off_outlined, size: 16),
      label: const Text('Hide'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text2,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
