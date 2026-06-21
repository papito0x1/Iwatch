import 'package:flutter/material.dart';

import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';

/// Coloured percentage badge, green up / red down.
class ChangeBadge extends StatelessWidget {
  const ChangeBadge({super.key, required this.pct, this.background = true});

  final double? pct;
  final bool background;

  @override
  Widget build(BuildContext context) {
    final color = pct == null
        ? AppColors.muted
        : (pct! >= 0 ? AppColors.up : AppColors.down);
    final text = Text(
      fmtPct(pct),
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 13,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (!background) return text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: text,
    );
  }
}

/// Connection status pill.
class StatusPill extends StatefulWidget {
  const StatusPill({super.key, required this.kind, required this.text});

  final StatusKind kind;
  final String text;

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color get _color {
    switch (widget.kind) {
      case StatusKind.live:
        return AppColors.up;
      case StatusKind.error:
        return AppColors.down;
      case StatusKind.loading:
        return AppColors.warn;
      case StatusKind.idle:
        return AppColors.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.kind == StatusKind.live;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          live
              ? AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, _) {
                    final t = _pulse.value;
                    return Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _color,
                        boxShadow: [
                          BoxShadow(
                            color: _color.withValues(alpha: (1 - t) * 0.5),
                            spreadRadius: t * 6,
                          ),
                        ],
                      ),
                    );
                  },
                )
              : Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: _color),
                ),
          const SizedBox(width: 7),
          Text(
            widget.text,
            style: TextStyle(
                color:
                    widget.kind == StatusKind.idle ? AppColors.muted : _color,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Round token icon with graceful fallback to a tinted initial.
class TokenIcon extends StatelessWidget {
  const TokenIcon(
      {super.key, required this.url, required this.symbol, this.size = 32});

  final String? url;
  final String symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0x1FFFFFFF),
      ),
      child: Text(
        symbol.isNotEmpty ? symbol.characters.first.toUpperCase() : '?',
        style: TextStyle(
            color: AppColors.muted,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.4),
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (ctx, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

/// The Iwatch app mark (the generated icon), rounded.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 28, this.radius = 8});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset('assets/icon/iwatch.png',
          width: size, height: size, fit: BoxFit.cover),
    );
  }
}
