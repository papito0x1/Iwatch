import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';
import 'charts.dart';

/// Bold section header, e.g. "Value", "Details" (like Resources' "Usage").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Text(text,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text)),
    );
  }
}

/// A section with a bold header that expands/collapses its body when tapped.
/// Collapsed by default. Matches [SectionHeader]'s look with a chevron added.
class CollapsibleSection extends StatefulWidget {
  const CollapsibleSection({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Row(
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text)),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.chevron_right,
                      size: 22, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: SizedBox(width: double.infinity, child: widget.child),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          sizeCurve: Curves.easeInOut,
        ),
      ],
    );
  }
}

/// A boxed card holding a large area chart with a label + value beneath,
/// mirroring the "Total Usage / 71%" card in GNOME Resources.
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.label,
    required this.value,
    required this.points,
    required this.up,
    this.height = 220,
  });

  final String label;
  final String value;
  final List<Point> points;
  final bool up;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: height, child: TotalChart(points: points, up: up)),
          const SizedBox(height: 12),
          Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class PropertyRow {
  final String label;
  final Widget value;
  final VoidCallback? onTap;
  const PropertyRow(this.label, this.value, {this.onTap});
}

/// A grouped "boxed list" of label/value rows with dividers — the GNOME
/// Adwaita pattern used by the Resources "Properties" section.
class PropertyList extends StatelessWidget {
  const PropertyList({super.key, required this.rows});

  final List<PropertyRow> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, thickness: 1, color: AppColors.divider),
            _Row(row: rows[i]),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row});
  final PropertyRow row;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(row.label,
                style: const TextStyle(color: AppColors.muted, fontSize: 14)),
          ),
          const SizedBox(width: 16),
          DefaultTextStyle.merge(
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.text2,
                fontFeatures: [FontFeature.tabularFigures()]),
            child: row.value,
          ),
          if (row.onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.open_in_new, size: 15, color: AppColors.muted),
          ],
        ],
      ),
    );
    if (row.onTap == null) return content;
    return InkWell(onTap: row.onTap, child: content);
  }
}

/// A card row with a label and a trailing control (e.g. a toggle), like the
/// "Show Usages of Logical CPUs" option row in Resources.
class OptionRow extends StatelessWidget {
  const OptionRow(
      {super.key, required this.label, required this.trailing, this.subtitle});

  final String label;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12)),
                ],
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
