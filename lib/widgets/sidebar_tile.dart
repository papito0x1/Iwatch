import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';
import 'charts.dart';

/// A navigation tile in the left pane, modelled on GNOME Resources: an icon,
/// a label, a value, and a live sparkline filling the lower half. The selected
/// tile is raised with a highlight and an Ubuntu-orange accent bar.
class SidebarTile extends StatefulWidget {
  const SidebarTile({
    super.key,
    this.leading,
    required this.title,
    required this.value,
    required this.points,
    required this.up,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final Widget? leading;
  final String title;
  final String value;
  final List<Point> points;
  final bool up;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  State<SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<SidebarTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.selected
        ? AppColors.cardHi
        : (_hover ? const Color(0x0DFFFFFF) : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: widget.selected ? AppColors.border : Colors.transparent),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    if (widget.leading != null) ...[
                      widget.leading!,
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                          const SizedBox(height: 1),
                          Text(widget.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                  fontFeatures: [
                                    FontFeature.tabularFigures()
                                  ])),
                        ],
                      ),
                    ),
                    if (widget.trailing != null) widget.trailing!,
                  ],
                ),
              ),
              // sparkline preview filling the lower part of the tile
              SizedBox(
                height: 46,
                width: double.infinity,
                child: Sparkline(points: widget.points, up: widget.up),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
