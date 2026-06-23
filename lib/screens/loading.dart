import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

/// Shown after a wallet is added (or reset) while the first balances load — a
/// branded, animated loader so the empty master–detail UI never flashes. Swaps
/// to the real UI the moment data arrives (handled by [HomeScreen]).
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<WalletModel>();
    final errored = model.statusKind == StatusKind.error;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child:
                errored ? _ErrorState(model: model) : _LoadingState(model: model),
          ),
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.model});
  final WalletModel model;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('loading'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const _BrandSpinner(size: 132),
        const SizedBox(height: 36),
        Text(
          'Loading wallet',
          style: const TextStyle(
              fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.text),
        ),
        const SizedBox(height: 8),
        // The live status line ("Syncing…") with a soft cross-fade between states.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            model.statusText,
            key: ValueKey(model.statusText),
            style: const TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ),
        const SizedBox(height: 22),
        _AddressPill(address: model.address),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.model});
  final WalletModel model;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.down.withValues(alpha: 0.14),
          ),
          child: const Icon(Icons.cloud_off_rounded,
              size: 30, color: AppColors.down),
        ),
        const SizedBox(height: 24),
        const Text("Couldn't load this wallet",
            style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppColors.text)),
        const SizedBox(height: 8),
        Text(
          model.statusText,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.muted),
        ),
        const SizedBox(height: 22),
        _AddressPill(address: model.address),
        const SizedBox(height: 28),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              onPressed: () => model.clearData(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text2,
                side: const BorderSide(color: AppColors.border),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Change wallet'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => model.refreshBalances(),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The short wallet address in a soft pill, with a monospace face.
class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.address});
  final String address;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: AppColors.orange),
          ),
          const SizedBox(width: 9),
          Text(
            shortAddr(address),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppColors.text2,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// The app icon orbited by a rotating Ubuntu-orange → aubergine comet arc, over
/// a soft breathing glow. One controller drives the whole thing.
class _BrandSpinner extends StatefulWidget {
  const _BrandSpinner({required this.size});
  final double size;

  @override
  State<_BrandSpinner> createState() => _BrandSpinnerState();
}

class _BrandSpinnerState extends State<_BrandSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = widget.size * 0.44;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          // A slow sine for the breathing glow + a gentle logo pulse, decoupled
          // from the faster comet rotation.
          final breathe =
              0.5 + 0.5 * math.sin(_c.value * 2 * math.pi); // 0..1
          return CustomPaint(
            painter: _SpinnerPainter(turn: _c.value, glow: breathe),
            child: Center(
              child: Transform.scale(
                scale: 1 + 0.04 * breathe,
                child: child,
              ),
            ),
          );
        },
        child: AppLogo(size: logo, radius: logo * 0.28),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turn, required this.glow});

  /// 0..1 rotation phase.
  final double turn;

  /// 0..1 breathing amount.
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    // Soft pulsing radial glow behind the icon.
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppColors.orange.withValues(alpha: 0.06 + 0.16 * glow),
          AppColors.aubergine.withValues(alpha: 0.05 + 0.06 * glow),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, glowPaint);

    final ringRect = Rect.fromCircle(center: center, radius: radius - 7);

    // Faint full track.
    canvas.drawCircle(
      center,
      radius - 7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = AppColors.border,
    );

    // Rotating comet: a gradient arc that fades into its own tail.
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          AppColors.orange.withValues(alpha: 0.0),
          AppColors.aubergine,
          AppColors.orange,
          AppColors.orangeHi,
        ],
        stops: const [0.0, 0.45, 0.8, 1.0],
        transform: GradientRotation(turn * 2 * math.pi),
      ).createShader(ringRect);
    canvas.drawArc(ringRect, turn * 2 * math.pi, 1.5 * math.pi, false, sweep);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.turn != turn || old.glow != glow;
}
