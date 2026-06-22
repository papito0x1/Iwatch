import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yaru/yaru.dart';

import '../state/wallet_model.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../widgets/common.dart';
import '../widgets/dialogs.dart';
import '../widgets/sidebar_tile.dart';
import 'detail_views.dart';
import 'welcome.dart';

const double _paneWidth = 280;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<WalletModel>();
    if (!model.hasWallet) return const _WelcomeScaffold();

    final selected = model.selectedId;
    final isPortfolio = selected == WalletModel.portfolioId;
    final selectedRow = isPortfolio ? null : model.rowById(selected);

    // page title shown on the right side of the split header
    final String pageTitle =
        isPortfolio ? 'Portfolio' : (selectedRow?.symbol ?? 'Portfolio');
    final String pageSubtitle = isPortfolio
        ? shortAddr(model.address)
        // (selectedRow?.name ?? '');
        : '';

    return Scaffold(
      backgroundColor: AppColors.windowBg,
      body: Column(
        children: [
          _SplitHeader(
            model: model,
            pageTitle: pageTitle,
            pageSubtitle: pageSubtitle,
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(model: model),
                Expanded(
                  child: (isPortfolio || selectedRow == null)
                      ? PortfolioDetail(model: model)
                      : TokenDetail(model: model, row: selectedRow),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Welcome layout: a native title bar (with window controls) + the entry form.
class _WelcomeScaffold extends StatelessWidget {
  const _WelcomeScaffold();

  @override
  Widget build(BuildContext context) {
    final model = context.read<WalletModel>();
    return Scaffold(
      backgroundColor: AppColors.windowBg,
      appBar: YaruWindowTitleBar(
        backgroundColor: AppColors.windowBg,
        border: const BorderSide(color: AppColors.border),
        foregroundColor: AppColors.text,
        centerTitle: false,
        titleSpacing: 0,
        leading: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Center(child: AppLogo()),
        ),
        title: const Text('Iwatch',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        actions: [
          _settingsButton(context, model),
          const SizedBox(width: 6),
        ],
      ),
      body: const WelcomeView(),
    );
  }
}

/// The split header: app brand over the pane (draggable), and a real Yaru
/// window title bar (page title + window controls) over the detail area.
class _SplitHeader extends StatelessWidget {
  const _SplitHeader({
    required this.model,
    required this.pageTitle,
    required this.pageSubtitle,
  });

  final WalletModel model;
  final String pageTitle;
  final String pageSubtitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kYaruTitleBarHeight,
      child: Row(
        children: [
          // left: brand over the sidebar (draggable to move the window)
          SizedBox(
            width: _paneWidth,
            child: DragToMoveArea(
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.paneBg,
                  border: Border(
                    bottom: BorderSide(color: AppColors.border),
                    right: BorderSide(color: AppColors.border),
                  ),
                ),
                padding: const EdgeInsets.only(left: 12, right: 6),
                child: Row(
                  children: [
                    const AppLogo(),
                    const SizedBox(width: 10),
                    const Text('Iwatch',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    _SortButton(model: model),
                    YaruIconButton(
                      icon: const Icon(Icons.tune, size: 18),
                      tooltip: 'Manage tokens',
                      onPressed: () => _showDialog(
                          context, model, const ManageDialog()),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // right: page title + status + window controls
          Expanded(
            child: YaruWindowTitleBar(
              backgroundColor: AppColors.windowBg,
              border: const BorderSide(color: AppColors.border),
              foregroundColor: AppColors.text,
              centerTitle: false,
              titleSpacing: 16,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(pageTitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  if (pageSubtitle.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(pageSubtitle,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.muted)),
                    ),
                  ],
                ],
              ),
              actions: [
                StatusPill(kind: model.statusKind, text: model.statusText),
                const SizedBox(width: 6),
                YaruIconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Refresh now',
                  onPressed: model.refreshBalances,
                ),
                _settingsButton(context, model),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.model});

  final WalletModel model;

  @override
  Widget build(BuildContext context) {
    final rows = model.orderedVisible;
    return Container(
      width: _paneWidth,
      decoration: const BoxDecoration(
        color: AppColors.paneBg,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          SidebarTile(
            // Neutral overview icon (the app logo already sits in the header).
            leading: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.orange.withValues(alpha: 0.15),
              ),
              child: const Icon(Icons.donut_small,
                  size: 18, color: AppColors.orange),
            ),
            title: 'PORTFOLIO',
            titleStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 17,
              letterSpacing: 0.5,
            ),
            value: fmtUsd(model.totalValue),
            points: model.totalHistory,
            up: (model.totalChangePct ?? 0) >= 0,
            selected: model.selectedId == WalletModel.portfolioId,
            onTap: () => model.select(WalletModel.portfolioId),
            trailing: ChangeBadge(pct: model.totalChangePct, background: false),
          ),
          const Divider(
              height: 9, indent: 14, endIndent: 14, color: AppColors.divider),
          for (final t in rows)
            SidebarTile(
              leading: TokenIcon(url: t.icon, symbol: t.symbol, size: 30),
              title: t.symbol,
              value: fmtUsd(t.value),
              points: model.historyFor(t.id),
              up: (t.change ?? 0) >= 0,
              selected: model.selectedId == t.id,
              onTap: () => model.select(t.id),
              trailing: ChangeBadge(pct: t.change, background: false),
            ),
        ],
      ),
    );
  }
}

/// Sort menu (by value / 24h change / name).
class _SortButton extends StatelessWidget {
  const _SortButton({required this.model});

  final WalletModel model;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SortMode>(
      tooltip: 'Sort',
      initialValue: model.sort,
      color: AppColors.card,
      icon: const Icon(Icons.swap_vert, size: 18, color: AppColors.muted),
      onSelected: model.setSort,
      itemBuilder: (_) => const [
        PopupMenuItem(value: SortMode.value, child: Text('Sort by value')),
        PopupMenuItem(
            value: SortMode.change, child: Text('Sort by 24h change')),
        PopupMenuItem(value: SortMode.name, child: Text('Sort by name')),
      ],
    );
  }
}

Widget _settingsButton(BuildContext context, WalletModel model) {
  return YaruIconButton(
    icon: const Icon(Icons.settings_outlined, size: 18),
    tooltip: 'Settings',
    onPressed: () => _showDialog(context, model, const SettingsDialog()),
  );
}

void _showDialog(BuildContext context, WalletModel model, Widget child) {
  showDialog(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(value: model, child: child),
  );
}
