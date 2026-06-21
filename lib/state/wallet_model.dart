import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/solana_service.dart';

enum StatusKind { idle, loading, live, error }

enum SortMode { value, change, name }

/// Central application state — a port of the renderer.js state machine.
///
/// Holds balances/prices/metadata, the per-wallet price history, polling
/// timers, persistence and all derived values the UI renders.
class WalletModel extends ChangeNotifier {
  WalletModel(this._svc, this._prefs);

  final SolanaService _svc;
  final SharedPreferences _prefs;

  // ---- tuning constants (mirror renderer.js) --------------------------------
  static const _maxPoints = 720;
  static const _persistPoints = 360;
  static const _defaultMaxWidgets = 12;
  static const _priceTickCap = 80;
  static const _metaCap = 80;
  static const manageLimit = 60;
  static const _wsol = SolanaService.wsolMint;

  // ---- persisted settings ---------------------------------------------------
  String address = '';
  String rpcUrl = '';
  int priceInterval = 12;
  int balanceInterval = 90;
  SortMode sort = SortMode.value;

  // ---- live data ------------------------------------------------------------
  List<Balance> _balances = [];
  final Map<String, TokenMeta?> _meta = {};
  final Map<String, PriceInfo> _prices = {};
  final List<Point> _historyTotal = [];
  final Map<String, List<Point>> _historyById = {};
  Set<String> _hidden = {};
  bool _hiddenInit = false;
  List<TokenRow> _lastList = [];

  // Sentinel id for the "Portfolio" overview entry in the sidebar.
  static const portfolioId = '__portfolio__';
  String selectedId = portfolioId;

  // Stable sidebar order (token ids). Kept steady across fast price ticks so
  // the selected item never jumps; only rebuilt on sort change / membership
  // change. Like the fixed list in GNOME Resources.
  List<String> _order = [];

  // ---- status / timing ------------------------------------------------------
  StatusKind statusKind = StatusKind.idle;
  String statusText = 'Idle';
  int _lastUpdatedMs = 0;
  int _nextTickAt = 0;

  Timer? _priceTimer;
  Timer? _balanceTimer;
  Timer? _countdownTimer;
  Timer? _histTimer;

  // ---- prefs keys (mirror the LS map) ---------------------------------------
  static const _kAddress = 'swt.address';
  static const _kRpc = 'swt.rpcUrl';
  static const _kPriceInt = 'swt.priceInterval';
  static const _kBalInt = 'swt.balanceInterval';
  static const _kSort = 'swt.sort';
  String _kHidden(String a) => 'swt.hidden.$a';
  String _kHistory(String a) => 'swt.history.$a';

  // ---- derived getters for the UI -------------------------------------------
  bool get hasWallet => address.isNotEmpty;
  List<Point> get totalHistory => _historyTotal;
  int get lastUpdatedMs => _lastUpdatedMs;

  int get nextTickSeconds {
    if (_nextTickAt == 0) return 0;
    final rem =
        ((_nextTickAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return rem < 0 ? 0 : rem;
  }

  double get totalValue => _lastList.fold(0.0, (s, t) => s + t.value);

  double? get totalChangePct {
    double past = 0, cur = 0;
    for (final t in _lastList) {
      if (t.price != null && t.change != null) {
        past += t.value / (1 + t.change! / 100);
        cur += t.value;
      }
    }
    return past > 0 ? (cur / past - 1) * 100 : null;
  }

  int get tokenCount => _lastList.length;

  int get visibleCount => _lastList.where((t) => !_hidden.contains(t.id)).length;

  /// Full, sorted list for the Manage dialog.
  List<TokenRow> get fullSortedRows => _sortList(_lastList);

  bool isHidden(String id) => _hidden.contains(id);

  List<Point> historyFor(String id) => _historyById[id] ?? const [];

  /// Sidebar token rows, in the stable display order.
  List<TokenRow> get orderedVisible {
    final byId = {for (final t in _lastList) t.id: t};
    return [
      for (final id in _order)
        if (byId[id] != null) byId[id]!,
    ];
  }

  TokenRow? rowById(String id) {
    for (final t in _lastList) {
      if (t.id == id) return t;
    }
    return null;
  }

  void select(String id) {
    if (selectedId == id) return;
    selectedId = id;
    notifyListeners();
  }

  // Rebuild [_order]: keep existing positions stable, drop departed ids and
  // append new visible ones in the current sort order.
  void _reconcileOrder() {
    final visible = _lastList.where((t) => !_hidden.contains(t.id)).toList();
    final visibleIds = visible.map((t) => t.id).toSet();
    _order.removeWhere((id) => !visibleIds.contains(id));
    final present = _order.toSet();
    final missing =
        _sortList(visible.where((t) => !present.contains(t.id)).toList())
            .map((t) => t.id);
    _order.addAll(missing);
    // If the selected token disappeared, fall back to the portfolio overview.
    if (selectedId != portfolioId && !visibleIds.contains(selectedId)) {
      selectedId = portfolioId;
    }
  }

  // ---------------------------------------------------------------------------
  // Boot / settings
  // ---------------------------------------------------------------------------
  void loadSettings() {
    address = _prefs.getString(_kAddress) ?? '';
    rpcUrl = _prefs.getString(_kRpc) ?? '';
    priceInterval = _clampInt(_prefs.getString(_kPriceInt), 5, 600, 12);
    balanceInterval = _clampInt(_prefs.getString(_kBalInt), 30, 3600, 90);
    sort = _sortFromString(_prefs.getString(_kSort));
  }

  void boot() {
    loadSettings();
    if (address.isNotEmpty) {
      startTracking(address);
    } else {
      _setStatus(StatusKind.idle, 'Idle');
    }
  }

  static int _clampInt(String? v, int min, int max, int def) {
    final n = int.tryParse(v ?? '');
    if (n == null) return def;
    return n.clamp(min, max);
  }

  static SortMode _sortFromString(String? v) {
    switch (v) {
      case 'name':
        return SortMode.name;
      case 'change':
        return SortMode.change;
      default:
        return SortMode.value;
    }
  }

  static String _sortToString(SortMode m) => m.name;

  // ---------------------------------------------------------------------------
  // Tracking lifecycle
  // ---------------------------------------------------------------------------
  void startTracking(String addr) {
    addr = addr.trim();
    if (addr.isEmpty) return;

    _clearTimers();
    _balances = [];
    _meta.clear();
    _prices.clear();
    _historyTotal.clear();
    _historyById.clear();
    _lastList = [];
    _order = [];
    selectedId = portfolioId;
    address = addr;

    _prefs.setString(_kAddress, addr);

    // restore saved hidden + history for this wallet
    final rawHidden = _prefs.getString(_kHidden(addr));
    if (rawHidden != null) {
      try {
        _hidden = Set<String>.from(jsonDecode(rawHidden) as List);
        _hiddenInit = true;
      } catch (_) {
        _hidden = {};
        _hiddenInit = false;
      }
    } else {
      _hidden = {};
      _hiddenInit = false;
    }

    final rawHist = _prefs.getString(_kHistory(addr));
    if (rawHist != null) {
      try {
        final h = jsonDecode(rawHist) as Map<String, dynamic>;
        _historyTotal
          ..clear()
          ..addAll(_pointsFromJson(h['total']));
        _historyById.clear();
        final byId = h['byId'] as Map<String, dynamic>? ?? {};
        byId.forEach((k, v) => _historyById[k] = _pointsFromJson(v));
      } catch (_) {}
    }

    notifyListeners();
    refreshBalances().then((_) => _startTimers());
  }

  static List<Point> _pointsFromJson(dynamic arr) {
    if (arr is! List) return [];
    return arr
        .whereType<Map>()
        .map((p) => Point((p['x'] as num).toDouble(), (p['y'] as num).toDouble()))
        .toList();
  }

  void _clearTimers() {
    _priceTimer?.cancel();
    _balanceTimer?.cancel();
    _countdownTimer?.cancel();
    _priceTimer = null;
    _balanceTimer = null;
    _countdownTimer = null;
  }

  void _startTimers() {
    _clearTimers();
    _priceTimer =
        Timer.periodic(Duration(seconds: priceInterval), (_) => tickPrices());
    _balanceTimer = Timer.periodic(
        Duration(seconds: balanceInterval), (_) => refreshBalances());
    _countdownTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    _nextTickAt =
        DateTime.now().millisecondsSinceEpoch + priceInterval * 1000;
  }

  Future<void> refreshBalances() async {
    if (address.isEmpty) return;
    _setStatus(StatusKind.loading, 'Syncing…');
    try {
      final result = await _svc.getBalances(address: address, rpcUrl: rpcUrl);
      _balances = result.tokens;

      // Slow path: price every holding so the total is accurate.
      final allMints = {..._balances.map((t) => t.mint)}.toList();
      final prices = await _svc.getPrices(allMints);
      _prices.addAll(prices);

      // Only fetch metadata for tokens we might actually show.
      final ranked = _balances
          .map((t) =>
              MapEntry(t.mint, (_prices[t.mint]?.usdPrice ?? 0) * t.uiAmount))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topMints = ranked.take(_metaCap).map((e) => e.key).toList();
      final meta = await _svc.getMeta({_wsol, ...topMints}.toList());
      _meta.addAll(meta);

      _applyData(append: true);
      _setStatus(StatusKind.live, 'Live');
    } catch (e) {
      _setStatus(StatusKind.error, _truncate(_errMsg(e)));
    }
  }

  Future<void> tickPrices() async {
    if (address.isEmpty || _balances.isEmpty) return;
    try {
      final prices = await _svc.getPrices(_mintsForTick());
      _prices.addAll(prices);
      _applyData(append: true);
      _setStatus(StatusKind.live, 'Live');
    } catch (e) {
      _setStatus(StatusKind.error, _truncate(_errMsg(e)));
    }
    _nextTickAt = DateTime.now().millisecondsSinceEpoch + priceInterval * 1000;
  }

  /// On fast ticks only reprice what's worth repricing: visible widgets plus
  /// the highest-value holdings, capped.
  List<String> _mintsForTick() {
    final set = <String>{};
    for (final t in _lastList) {
      if (!_hidden.contains(t.id)) set.add(t.mint);
    }
    final byValue = [..._lastList]..sort((a, b) => b.value.compareTo(a.value));
    for (final t in byValue) {
      if (set.length >= _priceTickCap) break;
      set.add(t.mint);
    }
    if (set.isEmpty) {
      for (final b in _balances.take(_priceTickCap)) {
        set.add(b.mint);
      }
    }
    return set.toList();
  }

  // ---------------------------------------------------------------------------
  // Data shaping
  // ---------------------------------------------------------------------------
  List<TokenRow> _enrich() {
    return _balances.map((b) {
      final m = _meta[b.mint];
      final p = _prices[b.mint];
      final symbol = b.isNative
          ? 'SOL'
          : (m?.symbol ??
              '${b.mint.substring(0, 4)}…${b.mint.substring(b.mint.length - 4)}');
      final name = b.isNative ? 'Solana' : (m?.name ?? 'Unknown token');
      final price = p?.usdPrice;
      final value = price != null ? b.uiAmount * price : 0.0;
      return TokenRow(
        id: b.id,
        mint: b.mint,
        isNative: b.isNative,
        symbol: symbol,
        name: name,
        icon: m?.icon,
        amount: b.uiAmount,
        price: price,
        change: p?.priceChange24h,
        value: value,
      );
    }).toList();
  }

  List<TokenRow> _sortList(List<TokenRow> list) {
    final arr = [...list];
    switch (sort) {
      case SortMode.name:
        arr.sort((a, b) => a.symbol.toLowerCase().compareTo(b.symbol.toLowerCase()));
        break;
      case SortMode.change:
        arr.sort((a, b) => (b.change ?? -1e9).compareTo(a.change ?? -1e9));
        break;
      case SortMode.value:
        arr.sort((a, b) => b.value.compareTo(a.value));
        break;
    }
    return arr;
  }

  void _pushPoint(List<Point> arr, double x, double y) {
    arr.add(Point(x, y));
    if (arr.length > _maxPoints) {
      arr.removeRange(0, arr.length - _maxPoints);
    }
  }

  void _applyData({required bool append}) {
    final list = _enrich();
    final total = list.fold(0.0, (s, t) => s + t.value);

    // First prices for a fresh wallet: keep only top holdings as widgets.
    if (!_hiddenInit && _prices.isNotEmpty) {
      final ranked = [...list]..sort((a, b) => b.value.compareTo(a.value));
      final keep = ranked
          .where((t) => t.value > 0)
          .take(_defaultMaxWidgets)
          .map((t) => t.id)
          .toSet();
      for (final t in list) {
        if (!keep.contains(t.id)) _hidden.add(t.id);
      }
      _hiddenInit = true;
      _saveHidden();
    }

    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    if (append) {
      _pushPoint(_historyTotal, now, total);
      for (final t in list) {
        final arr = _historyById.putIfAbsent(t.id, () => []);
        _pushPoint(arr, now, t.value);
      }
      _persistHistory();
    }

    _lastUpdatedMs = DateTime.now().millisecondsSinceEpoch;
    _lastList = list;
    _reconcileOrder();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // User actions
  // ---------------------------------------------------------------------------
  void setSort(SortMode mode) {
    sort = mode;
    _prefs.setString(_kSort, _sortToString(mode));
    _order = []; // re-sort the sidebar in the newly chosen order
    _reconcileOrder();
    notifyListeners();
  }

  void toggleHidden(String id, bool hide) {
    if (hide) {
      _hidden.add(id);
    } else {
      _hidden.remove(id);
    }
    _saveHidden();
    _reconcileOrder();
    notifyListeners();
  }

  void saveSettings(
      {required String rpc, required int priceInt, required int balInt}) {
    rpcUrl = rpc.trim();
    priceInterval = priceInt.clamp(5, 600);
    balanceInterval = balInt.clamp(30, 3600);
    _prefs.setString(_kRpc, rpcUrl);
    _prefs.setString(_kPriceInt, priceInterval.toString());
    _prefs.setString(_kBalInt, balanceInterval.toString());
    if (address.isNotEmpty) {
      refreshBalances();
      _startTimers();
    }
  }

  void clearData() {
    if (address.isNotEmpty) {
      _prefs.remove(_kHidden(address));
      _prefs.remove(_kHistory(address));
    }
    for (final k in [_kAddress, _kRpc, _kPriceInt, _kBalInt, _kSort]) {
      _prefs.remove(k);
    }
    _clearTimers();
    address = '';
    rpcUrl = '';
    _lastList = [];
    _order = [];
    selectedId = portfolioId;
    _balances = [];
    _prices.clear();
    _meta.clear();
    _historyTotal.clear();
    _historyById.clear();
    _setStatus(StatusKind.idle, 'Idle');
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------
  void _saveHidden() {
    _prefs.setString(_kHidden(address), jsonEncode(_hidden.toList()));
  }

  void _persistHistory() {
    if (_histTimer != null) return;
    _histTimer = Timer(const Duration(seconds: 4), () {
      _histTimer = null;
      final slim = {
        'total': _tail(_historyTotal).map((p) => {'x': p.x, 'y': p.y}).toList(),
        'byId': {
          for (final e in _historyById.entries)
            e.key: _tail(e.value).map((p) => {'x': p.x, 'y': p.y}).toList()
        },
      };
      _prefs.setString(_kHistory(address), jsonEncode(slim));
    });
  }

  List<Point> _tail(List<Point> arr) =>
      arr.length <= _persistPoints ? arr : arr.sublist(arr.length - _persistPoints);

  // ---------------------------------------------------------------------------
  void _setStatus(StatusKind kind, String text) {
    statusKind = kind;
    statusText = text;
    notifyListeners();
  }

  static String _errMsg(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  static String _truncate(String s) =>
      s.length > 48 ? '${s.substring(0, 45)}…' : s;

  @override
  void dispose() {
    _clearTimers();
    _histTimer?.cancel();
    _svc.dispose();
    super.dispose();
  }
}
