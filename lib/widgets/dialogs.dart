import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yaru/yaru.dart';

import '../models/models.dart';
import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';
import 'common.dart';

const _dialogShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(kYaruWindowRadius)),
);

/// Manage widgets drawer — toggle which tokens show a live graph.
class ManageDialog extends StatelessWidget {
  const ManageDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: _dialogShape,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.of(context).size.height * 0.86,
        ),
        child: Consumer<WalletModel>(
          builder: (context, model, _) {
            final full = model.fullSortedRows;
            final list = full.take(WalletModel.manageLimit).toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const YaruDialogTitleBar(title: Text('Manage tokens')),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Choose which tokens appear in the sidebar. Hidden '
                          'tokens still count toward your total value.',
                          style:
                              TextStyle(color: AppColors.muted, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        if (full.isEmpty)
                          const Text('No tokens found in this wallet yet.',
                              style: TextStyle(color: AppColors.muted))
                        else
                          ...list.map((t) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _ManageRow(model: model, row: t),
                              )),
                        if (full.length > list.length)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '+${full.length - list.length} more lower-value '
                              'tokens not listed.',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({required this.model, required this.row});

  final WalletModel model;
  final TokenRow row;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          TokenIcon(url: row.icon, symbol: row.symbol, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.symbol,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                Text(
                  '${fmtUsd(row.value)} · ${fmtAmount(row.amount)} ${row.symbol}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          YaruSwitch(
            value: !model.isHidden(row.id),
            onChanged: (v) => model.toggleHidden(row.id, !v),
          ),
        ],
      ),
    );
  }
}

/// Settings modal — RPC + refresh intervals + clear data.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _rpc;
  late final TextEditingController _price;
  late final TextEditingController _balance;

  @override
  void initState() {
    super.initState();
    final m = context.read<WalletModel>();
    _rpc = TextEditingController(text: m.rpcUrl);
    _price = TextEditingController(text: m.priceInterval.toString());
    _balance = TextEditingController(text: m.balanceInterval.toString());
  }

  @override
  void dispose() {
    _rpc.dispose();
    _price.dispose();
    _balance.dispose();
    super.dispose();
  }

  InputDecoration _dec(String? hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.muted2),
        filled: true,
        fillColor: const Color(0x0AFFFFFF),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.orange, width: 1.5),
        ),
      );

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child:
            Text(s, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      );

  @override
  Widget build(BuildContext context) {
    final model = context.read<WalletModel>();
    return Dialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: _dialogShape,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YaruDialogTitleBar(title: Text('Settings')),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Custom RPC endpoint'),
                    TextField(
                      controller: _rpc,
                      style: const TextStyle(color: AppColors.text),
                      decoration: _dec('https://api.mainnet-beta.solana.com'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'The public RPC is rate-limited. Paste a Helius / '
                      'QuickNode / Triton URL for smoother updates.',
                      style: TextStyle(color: AppColors.muted2, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Price refresh (seconds)'),
                              TextField(
                                controller: _price,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: AppColors.text),
                                decoration: _dec(null),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Balance refresh (seconds)'),
                              TextField(
                                controller: _balance,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: AppColors.text),
                                decoration: _dec(null),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () {
                            model.clearData();
                            Navigator.of(context).pop();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFFF9AA8),
                            backgroundColor: const Color(0x1FFF5D73),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Clear saved data',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        FilledButton(
                          onPressed: () {
                            model.saveSettings(
                              rpc: _rpc.text,
                              priceInt: int.tryParse(_price.text) ?? 12,
                              balInt: int.tryParse(_balance.text) ?? 90,
                            );
                            Navigator.of(context).pop();
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.orange,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Save',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
