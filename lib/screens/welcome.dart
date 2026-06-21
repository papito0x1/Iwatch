import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/wallet_model.dart';
import '../theme.dart';

/// Shown when no wallet is being tracked: branding + the address entry form.
class WelcomeView extends StatefulWidget {
  const WelcomeView({super.key});

  @override
  State<WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<WelcomeView> {
  final _input = TextEditingController();

  static const _demo1 = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  static const _demo2 = 'Gjwcz1uMnFFiv5XCRG7sgmJWnYbWNRRJYqXMnnEpDvY9';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _track([String? addr]) {
    final v = (addr ?? _input.text).trim();
    if (v.isNotEmpty) context.read<WalletModel>().startTracking(v);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset('assets/icon/iwatch.png',
                    width: 112, height: 112),
              ),
              const SizedBox(height: 22),
              const Text('Welcome to Iwatch',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              const Text(
                'Paste a Solana wallet address to watch its tokens, holdings '
                'and total value update in real time as prices move on-chain.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: AppColors.muted, fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      autofocus: true,
                      onSubmitted: (_) => _track(),
                      style: const TextStyle(
                          color: AppColors.text,
                          fontFamily: 'monospace',
                          fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.account_balance_wallet_outlined,
                            size: 18, color: AppColors.muted),
                        hintText: 'Solana wallet address…',
                        hintStyle: const TextStyle(color: AppColors.muted2),
                        filled: true,
                        fillColor: AppColors.card,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 15),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: AppColors.orange, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () => _track(),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 17),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Watch',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Try a demo wallet:',
                      style: TextStyle(color: AppColors.muted2, fontSize: 13)),
                  _DemoChip(label: 'Demo 1', onTap: () => _track(_demo1)),
                  _DemoChip(label: 'Demo 2', onTap: () => _track(_demo2)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoChip extends StatelessWidget {
  const _DemoChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(label,
              style: const TextStyle(color: AppColors.text2, fontSize: 13)),
        ),
      ),
    );
  }
}
