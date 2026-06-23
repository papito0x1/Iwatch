import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/balance_graph.dart';
import '../models/models.dart';
import '../services/price_feed.dart';
import '../services/solana_service.dart';

enum StatusKind { idle, loading, live, error }

enum SortMode { value, change, name }

/// Central application state — a port of the renderer.js state machine.
///
/// Holds balances/prices/metadata, the per-wallet price history, polling
/// timers, persistence and all derived values the UI renders.
class WalletModel extends ChangeNotifier {
  WalletModel(this._svc, this._prefs) {
    _feed.onPrice = _onLivePrice;
  }

  final SolanaService _svc;
  final SharedPreferences _prefs;

  /// Live, push-based price overlay (Coinbase WS) for holdings that map to a
  /// listed market. Jupiter polling below remains the source of truth for the
  /// long tail and 24h change; live prices override the headline value/charts.
  final CoinbasePriceFeed _feed = CoinbasePriceFeed();

  // ---- tuning constants (mirror renderer.js) --------------------------------
  static const _persistPoints = 360;
  static const _defaultMaxWidgets = 12;
  static const _priceTickCap = 80;
  static const _metaCap = 80;

  // Balance graphs (the portfolio area chart + per-token "Holdings value" card,
  // plus the sidebar sparklines) are reconstructed from candle data so they show
  // a real window of history instead of only what's been collected live since
  // the wallet was added. The sidebar sparklines always show the 24h
  // ([BalanceRange.d1]) series; the *main* chart's window is user-selectable
  // (1D / 1W / 1M). The candlestick price charts are a separate series and are
  // deliberately untouched by this.
  static const manageLimit = 60;
  static const _wsol = SolanaService.wsolMint;

  // ---- persisted settings ---------------------------------------------------
  String address = '';
  String rpcUrl = '';
  int priceInterval = 6;
  int balanceInterval = 90;
  SortMode sort = SortMode.value;

  // ---- live data ------------------------------------------------------------
  List<Balance> _balances = [];
  final Map<String, TokenMeta?> _meta = {};
  final Map<String, PriceInfo> _prices = {};
  // The 24h ([BalanceRange.d1]) series — drives the sidebar sparklines and the
  // main chart when its range is 1D.
  final List<Point> _historyTotal = [];
  final Map<String, List<Point>> _historyById = {};
  // Longer windows for the *main* balance chart only (1W / 1M), reconstructed
  // lazily when first selected and cached until holdings change.
  final Map<BalanceRange, List<Point>> _balTotalRange = {};
  final Map<BalanceRange, Map<String, List<Point>>> _balIdRange = {};
  // Which window the main balance chart is showing, and which ranges are
  // currently being (re)built — so we can skip re-fetching and show a spinner.
  BalanceRange balanceRange = BalanceRange.d1;
  final Set<BalanceRange> _balLoading = {};
  // Which tokens have real candle data per window — so a rate-limited retry only
  // re-fetches the ones that fell back, and a complete window stops fetching.
  final Map<BalanceRange, Set<String>> _balReal = {};
  bool _rebuildingAll = false;
  // Lets us skip reconstruction when holdings/visibility are unchanged.
  String _balancesSig = '';
  Set<String> _hidden = {};
  bool _hiddenInit = false;
  List<TokenRow> _lastList = [];

  // ---- price chart (OHLCV) --------------------------------------------------
  // Keyed by tokenId so the chart survives reselection and range changes are
  // cheap; a request token prevents stale loads from overwriting a newer one.
  final Map<String, List<Candle>> _chartById = {};
  final Map<String, ChartRange> _rangeById = {};
  final Set<String> _chartLoading = {};
  final Map<String, String?> _chartError = {};
  // Monotonic token source plus the current token per tokenId, so a stale load
  // is discarded without one token's request cancelling another's.
  int _chartSeq = 0;
  final Map<String, int> _chartReqToken = {};

  // ---- live price overlay (Coinbase WS) -------------------------------------
  // Coinbase product (e.g. 'SOL-USD') -> the mints whose price it drives. One
  // product can back several mints (rare), so this is a list.
  final Map<String, List<String>> _productToMints = {};
  // Pending live prices, coalesced and flushed on a timer so a busy market
  // (BTC can push many ticks/sec) costs at most a few rebuilds per second.
  final Map<String, double> _livePending = {};
  Timer? _liveFlush;
  static const _liveFlushInterval = Duration(milliseconds: 300);
  // A non-trusted (symbol-mapped) mint's live price is only applied when it sits
  // within this ratio of Jupiter's last quote — a cheap guard against a scam
  // token spoofing a major's symbol to inherit its price.
  static const _corroborateLo = 0.7;
  static const _corroborateHi = 1.43;

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

  Timer? _priceTimer;
  Timer? _balanceTimer;
  Timer? _histTimer;
  Timer? _chartTimer;

  /// How often the charts poll for fresh candles. Kept short for a near-live
  /// last bar; each poll is one tiny request (last few candles only) per chart
  /// — selected token + BTC — so it stays under GeckoTerminal's keyless rate
  /// limit (~30 req/min → ~12 req/min at this cadence).
  static const _chartLiveInterval = Duration(seconds: 10);

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

  /// Series for the *main* portfolio "Total value" chart at the selected
  /// [balanceRange]. (Sidebar sparklines stay on the 24h series via
  /// [totalHistory].)
  List<Point> mainTotalSeries() => balanceRange == BalanceRange.d1
      ? _historyTotal
      : (_balTotalRange[balanceRange] ?? const []);

  /// Series for a token's *main* "Holdings value" chart at the selected
  /// [balanceRange]. (Its sidebar sparkline stays on the 24h series via
  /// [historyFor].)
  List<Point> mainTokenSeries(String id) => balanceRange == BalanceRange.d1
      ? historyFor(id)
      : (_balIdRange[balanceRange]?[id] ?? const []);

  /// Whether the currently-shown main-chart window is still being reconstructed.
  bool get balanceRangeLoading => _balLoading.contains(balanceRange);

  /// Switch the main balance chart's window. Shows whatever is already built
  /// (from a prefetch or a previous session, kept current by live ticks)
  /// immediately, and only reconstructs a window we don't have yet — so it no
  /// longer sits on "Collecting live history…".
  void setBalanceRange(BalanceRange r) {
    if (balanceRange == r) return;
    balanceRange = r;
    notifyListeners();
    if (r != BalanceRange.d1 && !_rangeComplete(r)) _reconstructRange(r);
  }

  /// Chart candles for a token at its currently-selected range.
  List<Candle> chartFor(String id) => _chartById[id] ?? const [];

  ChartRange chartRangeFor(String id) => _rangeById[id] ?? ChartRange.h1;

  bool chartLoadingFor(String id) => _chartLoading.contains(id);

  String? chartErrorFor(String id) => _chartError[id];

  /// Load (or reload) OHLCV candles for a token at [range]. A request sequence
  /// guards against an older fetch landing after a newer one (e.g. rapid range
  /// switches). No-op if already cached for this id+range.
  Future<void> loadChart(String id, ChartRange range) async {
    final mint = rowById(id)?.mint ?? (id == 'SOL' ? SolanaService.wsolMint : id);
    if (mint.isEmpty) return;

    if (_chartById[id] != null && _rangeById[id] == range) return;
    final token = ++_chartSeq;
    _chartReqToken[id] = token;
    _rangeById[id] = range;
    _chartLoading.add(id);
    _chartError[id] = null;
    notifyListeners();

    try {
      final candles = await _svc.getCandles(mint: mint, range: range);
      if (_chartReqToken[id] != token) return; // superseded by a newer load
      _chartById[id] = candles;
      _chartError[id] = candles.length < 2 ? 'No chart data available.' : null;
    } catch (e) {
      if (_chartReqToken[id] != token) return;
      _chartError[id] = _truncate(_errMsg(e));
    } finally {
      if (_chartReqToken[id] == token) {
        _chartLoading.remove(id);
        notifyListeners();
      }
    }
  }

  /// Refresh the chart for [id] at its current range, bypassing the cache.
  Future<void> refreshChart(String id) async {
    _chartById.remove(id);
    _rangeById.remove(id); // force a full reload (picks up pool fix too)
    await loadChart(id, ChartRange.h1);
  }

  /// Live tick: silently top up the *selected* token's chart — and the BTC
  /// reference chart shown beside it — with the latest few candles so the last
  /// bar tracks the market in near real time. Updates in place (no spinner, no
  /// error clobber) and preserves the user's zoom/pan.
  Future<void> _tickChart() async {
    // Advance any chart whose candle period has elapsed before fetching, so the
    // next candle prints right at the boundary instead of only when Gecko's
    // data catches up.
    _rolloverLoadedCharts();
    final id = selectedId;
    // The BTC chart ticks alongside the selected token's chart; both are small
    // single requests, so we run them concurrently and stay well under
    // GeckoTerminal's keyless rate limit.
    final futures = <Future<void>>[];
    if (id != portfolioId) futures.add(_tickOne(id));
    futures.add(_tickOne(SolanaService.btcMint));
    await Future.wait(futures);
  }

  /// Top up a single token's chart with the latest few candles. No-op if there
  /// is nothing loaded yet, a full load is running, or the token was switched
  /// away from while we fetched. Silent on transient failures.
  Future<void> _tickOne(String id) async {
    final existing = _chartById[id];
    if (existing == null || existing.isEmpty) return; // initial load handles it
    if (_chartLoading.contains(id)) return; // a full load is already running
    final range = _rangeById[id];
    if (range == null) return;
    final mint = id == SolanaService.btcMint
        ? SolanaService.btcMint
        : (rowById(id)?.mint ?? (id == 'SOL' ? SolanaService.wsolMint : id));
    if (mint.isEmpty) return;

    try {
      final recent =
          await _svc.getRecentCandles(mint: mint, range: range, count: 4);
      if (recent.isEmpty) return;
      // Bail if the user moved on (different token/range) while we fetched.
      if (_rangeById[id] != range) return;
      final cur = _chartById[id];
      if (cur == null || cur.isEmpty) return;

      // Merge by timestamp: replaces the in-progress last bar, appends new ones.
      final byTime = {for (final c in cur) c.time: c};
      var changed = false;
      for (final c in recent) {
        final prev = byTime[c.time];
        if (prev == null ||
            prev.close != c.close ||
            prev.high != c.high ||
            prev.low != c.low ||
            prev.volume != c.volume) {
          byTime[c.time] = c;
          changed = true;
        }
      }
      if (!changed) return;
      final merged = byTime.values.toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      _chartById[id] = merged;
      notifyListeners();
    } catch (_) {
      // Silent: keep the existing candles on a transient failure.
    }
  }

  void setChartRange(String id, ChartRange range) {
    if (_rangeById[id] == range) return;
    loadChart(id, range);
  }

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
    priceInterval = _clampInt(_prefs.getString(_kPriceInt), 5, 600, 6);
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
    _balTotalRange.clear();
    _balIdRange.clear();
    _balLoading.clear();
    _balReal.clear();
    balanceRange = BalanceRange.d1;
    _balancesSig = '';
    _chartById.clear();
    _rangeById.clear();
    _chartLoading.clear();
    _chartError.clear();
    _chartSeq++; // invalidate any in-flight loads
    _chartReqToken.clear();
    _productToMints.clear();
    _livePending.clear();
    _lastList = [];
    _order = [];
    selectedId = portfolioId;
    address = addr;

    _prefs.setString(_kAddress, addr);

    // Open the live price socket; subscriptions are filled once holdings load.
    _feed.start();

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
        void load(Map<String, dynamic>? m, List<Point> total,
            Map<String, List<Point>> byId) {
          total
            ..clear()
            ..addAll(_pointsFromJson(m?['total']));
          byId.clear();
          (m?['byId'] as Map<String, dynamic>? ?? const {})
              .forEach((k, v) => byId[k] = _pointsFromJson(v));
        }

        if (h.containsKey('total')) {
          // Legacy single-window (24h-only) format.
          load(h, _historyTotal, _historyById);
        } else {
          load(h[BalanceRange.d1.name] as Map<String, dynamic>?, _historyTotal,
              _historyById);
          for (final r in [BalanceRange.w1, BalanceRange.m1]) {
            final m = h[r.name] as Map<String, dynamic>?;
            if (m == null) continue;
            final total = <Point>[];
            final byId = <String, List<Point>>{};
            load(m, total, byId);
            _balTotalRange[r] = total;
            _balIdRange[r] = byId;
          }
        }
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
    _chartTimer?.cancel();
    _priceTimer = null;
    _balanceTimer = null;
    _chartTimer = null;
  }

  void _startTimers() {
    _clearTimers();
    _priceTimer =
        Timer.periodic(Duration(seconds: priceInterval), (_) => tickPrices());
    _balanceTimer = Timer.periodic(
        Duration(seconds: balanceInterval), (_) => refreshBalances());
    _chartTimer = Timer.periodic(_chartLiveInterval, (_) => _tickChart());
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
      _maybeReconstructHistory();
      _syncFeed();
      _setStatus(StatusKind.live, 'Live');
    } catch (e) {
      _setStatus(StatusKind.error, _truncate(_errMsg(e)));
    }
  }

  // ---------------------------------------------------------------------------
  // Live price overlay (Coinbase WebSocket)
  // ---------------------------------------------------------------------------

  /// (Re)build the live subscription set from the current holdings.
  ///
  /// A holding streams live if its symbol maps to an online Coinbase `<SYM>-USD`
  /// market — either via the curated trusted-mint table or its Jupiter symbol.
  /// The BTC reference market is always included so the wBTC chart ticks live
  /// even for wallets that hold no BTC.
  void _syncFeed() {
    // Build candidate products from holdings. We don't filter against the
    // online-product set here — the feed does that at subscribe time, which also
    // avoids a first-load race where the product list hasn't downloaded yet.
    // Products that don't exist on Coinbase simply never push a tick.
    final map = <String, List<String>>{};
    void add(String mint, String symbol) {
      final product = '${symbol.toUpperCase()}-USD';
      (map[product] ??= []).add(mint);
    }

    for (final b in _balances) {
      final symbol =
          CoinbasePriceFeed.trustedMints[b.mint] ?? _meta[b.mint]?.symbol;
      if (symbol != null && symbol.isNotEmpty) add(b.mint, symbol);
    }
    // The BTC chart's mint is never a balance — wire it up explicitly.
    add(SolanaService.btcMint, 'BTC');

    _productToMints
      ..clear()
      ..addAll(map);
    _feed.setProducts(map.keys.toSet());
  }

  /// A live tick arrived. Buffer it and schedule a coalesced flush so a flood of
  /// ticks turns into at most a few rebuilds per second.
  void _onLivePrice(LivePrice p) {
    _livePending[p.product] = p.price;
    _liveFlush ??= Timer(_liveFlushInterval, _flushLive);
  }

  void _flushLive() {
    _liveFlush = null;
    if (_livePending.isEmpty || address.isEmpty) return;
    final pending = Map<String, double>.from(_livePending);
    _livePending.clear();

    var changed = false;
    for (final entry in pending.entries) {
      final mints = _productToMints[entry.key];
      if (mints == null) continue;
      for (final mint in mints) {
        if (_applyLivePrice(mint, entry.value)) changed = true;
      }
    }
    // Recompute holdings/total from the refreshed prices (no history append —
    // the sparkline keeps growing on the poll cadence, not per live tick).
    if (changed) _applyData(append: false);
  }

  /// Apply a live USD [price] to [mint]. Returns whether anything changed.
  ///
  /// Curated trusted mints are applied directly. A symbol-mapped mint is only
  /// applied when Jupiter already has a corroborating quote within
  /// [_corroborateLo]–[_corroborateHi], so a spoofed symbol can't hijack a
  /// major's price. Also live-ticks the forming candle of any matching chart.
  bool _applyLivePrice(String mint, double price) {
    final existing = _prices[mint];
    final trusted = CoinbasePriceFeed.trustedMints.containsKey(mint);
    if (!trusted) {
      final jup = existing?.usdPrice;
      if (jup == null || jup <= 0) return false; // nothing to corroborate against
      final ratio = price / jup;
      if (ratio < _corroborateLo || ratio > _corroborateHi) return false;
    }
    final tickedChart = _tickChartLastCandle(mint, price);
    if (existing != null && existing.usdPrice == price) return tickedChart;
    _prices[mint] = PriceInfo(
      usdPrice: price,
      priceChange24h: existing?.priceChange24h,
    );
    return true;
  }

  /// Apply a live [price] to any chart driven by [mint]: open a fresh candle if
  /// the clock has crossed into a new bucket, otherwise refine the forming one.
  ///
  /// The 6-month history and earlier candles' open times are untouched, so the
  /// chart's series identity is preserved and it keeps following the live edge
  /// between the slower GeckoTerminal polls. Returns whether a chart was updated.
  bool _tickChartLastCandle(String mint, double price) {
    // Chart ids that this mint backs: the mint itself, plus 'SOL' for wSOL.
    final ids = <String>[];
    if (_chartById.containsKey(mint)) ids.add(mint);
    if (mint == _wsol && _chartById.containsKey('SOL')) ids.add('SOL');

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var updated = false;
    for (final id in ids) {
      final list = _chartById[id];
      if (list == null || list.isEmpty) continue;
      if (_rolloverOrRefine(id, list, nowSec, price)) updated = true;
    }
    return updated;
  }

  /// Advance loaded charts that have crossed into a new candle bucket, even when
  /// no live trade has arrived — so a token without a Coinbase market still
  /// prints a new candle the moment its timeframe elapses (e.g. every 5 min on
  /// the 5m range), seeded flat from the last close. Runs on the chart timer;
  /// GeckoTerminal fills the real OHLC on its next poll, and a WS price refines
  /// it sooner for listed markets.
  void _rolloverLoadedCharts() {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var changed = false;
    // Snapshot keys: _rolloverOrRefine replaces map values as it goes.
    for (final id in _chartById.keys.toList()) {
      final list = _chartById[id];
      if (list == null || list.isEmpty) continue;
      // price: null → seed/refine flat from the last close (no live trade).
      if (_rolloverOrRefine(id, list, nowSec, null)) changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Advance one chart [id] with an optional live [price] at [nowSec] via the
  /// pure [advanceCandles]. Writes the new series (same first.time, so the chart
  /// repaints as the same series) and returns whether anything changed.
  bool _rolloverOrRefine(String id, List<Candle> list, int nowSec, double? price) {
    final range = _rangeById[id];
    if (range == null) return false;
    final next = advanceCandles(list, nowSec, range.bucketSeconds, price);
    if (next == null) return false;
    _chartById[id] = next;
    return true;
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

  /// Roll a balance-graph [arr] forward for the current [value] at [nowSec] on
  /// [range]'s bucket; a no-op on a null/empty series (reconstruction seeds it).
  void _advance(List<Point>? arr, int nowSec, double value, BalanceRange range) {
    if (arr == null) return;
    advanceBalancePoint(arr, nowSec, value, range.bucketSec, range.windowSec);
  }

  /// Rebuild the balance graphs whenever the holdings or which tokens are shown
  /// actually change; a cheap no-op otherwise so routine polls don't re-fetch.
  /// Rebuilds (and prefetches) every window so a later 1W/1M switch is instant.
  void _maybeReconstructHistory() {
    final mints = _balances.map((b) => '${b.mint}:${b.uiAmount}').toList()
      ..sort();
    final hidden = (_hidden.toList()..sort()).join('|');
    final sig = '${mints.join(',')}#$hidden';
    if (sig == _balancesSig) {
      // Holdings unchanged — top up any window that still has tokens on a
      // fallback curve (rate-limited last time). Complete windows are kept
      // current by live ticks, so they don't re-fetch.
      _refreshIncompleteRanges();
      return;
    }
    _balancesSig = sig;
    _balReal.clear(); // holdings changed — every token must be re-fetched
    _rebuildAllRanges();
  }

  /// Whether [range] has real candle data for every visible token.
  bool _rangeComplete(BalanceRange range) {
    final real = _balReal[range];
    if (real == null) return false;
    return _lastList
        .where((t) => !_hidden.contains(t.id))
        .every((t) => real.contains(t.id));
  }

  /// Retry any window still missing real data for some token — re-fetches only
  /// the tokens that fell back, until every visible holding is real.
  Future<void> _refreshIncompleteRanges() async {
    if (_rebuildingAll) return;
    _rebuildingAll = true;
    final reqAddr = address;
    try {
      for (final r in BalanceRange.values) {
        if (address != reqAddr) return;
        if (!_rangeComplete(r)) await _reconstructRange(r);
      }
    } finally {
      _rebuildingAll = false;
    }
  }

  /// Rebuild every balance window from candles, sequentially so we don't burst
  /// the chart provider's keyless rate limit: the 24h series first (it drives the
  /// sidebar sparklines and the default chart), then the 1W and 1M windows so a
  /// later switch is already cached. Previously-shown or persisted series stay on
  /// screen until each rebuild overwrites them — no "collecting" flash.
  Future<void> _rebuildAllRanges() async {
    if (_rebuildingAll) return;
    _rebuildingAll = true;
    final reqAddr = address;
    try {
      for (final r in BalanceRange.values) {
        if (address != reqAddr) return;
        // A range that aborts (rate limit) is left missing; the next balance
        // poll retries it via _buildMissingRanges().
        await _reconstructRange(r);
      }
    } finally {
      _rebuildingAll = false;
    }
  }

  /// Reconstruct the portfolio value curve and per-token holdings curves over
  /// [range] from OHLCV candles: value(t) = balance × close(t), summed across the
  /// holdings — a real window of history on load instead of only what's been
  /// collected live since the wallet was added.
  ///
  /// Bounded to the visible widget tokens (the meaningful holdings) so we stay
  /// under the chart provider's keyless rate limit; the remaining dust holdings
  /// are folded into the total at their current value as a flat baseline, and a
  /// pool-less token falls back to a flat line. Only the value series are touched
  /// here — the candlestick charts are independent and left alone.
  ///
  /// Note: this prices the *current* holdings at past candle closes, so right
  /// after a large swap the historical shape reflects today's balances, not what
  /// was actually held then (the standard "today's holdings over the window"
  /// view — we don't keep per-bucket balance history).
  ///
  /// Per-token and incremental: each token that fetches commits its real curve;
  /// a token whose fetch throws (rate limit / network) keeps its *previous* curve
  /// (re-aligned to the new grid), or a flat placeholder only if we've never had
  /// data for it — never a flat line over a good one. A token already known-real
  /// is re-aligned without re-fetching. The window always commits what it has, so
  /// a many-token wallet under a rate limit no longer sits forever on "Collecting
  /// live history…"; tokens that fell back are retried on the next balance poll
  /// until every visible holding is real. Returns whether the window is complete.
  Future<bool> _reconstructRange(BalanceRange range) async {
    if (_balLoading.contains(range) || _lastList.isEmpty) return false;
    _balLoading.add(range);
    notifyListeners();
    final reqAddr = address;
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final grid = balanceGrid(range, nowSec);

      // Biggest holdings first so the chart's magnitude is right after the very
      // first fetch even on a huge wallet.
      final visible = _lastList.where((t) => !_hidden.contains(t.id)).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final existing =
          range == BalanceRange.d1 ? _historyById : (_balIdRange[range] ?? {});
      final real = _balReal.putIfAbsent(range, () => <String>{});
      final byId = <String, List<Point>>{};
      var complete = true;

      // Fold the non-visible (dust) holdings in at their current value so the
      // total's magnitude stays right without a request per token.
      final baseline = _lastList
          .where((t) => _hidden.contains(t.id))
          .fold(0.0, (s, t) => s + t.value);

      // Commit whatever's built so far — called after each fetched token so the
      // chart fills in progressively instead of waiting on the whole sweep.
      void commit() {
        final total = [
          for (var i = 0; i < grid.length; i++)
            Point(
                grid[i] * 1000.0,
                baseline +
                    visible.fold(0.0, (s, t) => s + (byId[t.id]?[i].y ?? 0)))
        ];
        if (range == BalanceRange.d1) {
          // The 24h series is shared with the sidebar sparklines.
          _historyById
            ..clear()
            ..addAll(byId);
          _historyTotal
            ..clear()
            ..addAll(total);
        } else {
          _balIdRange[range] = Map.of(byId);
          _balTotalRange[range] = total;
        }
        notifyListeners();
      }

      for (final t in visible) {
        if (address != reqAddr) return false; // wallet switched mid-flight
        // Already have real candle data for this token — just re-align it onto
        // the new grid, no fetch (keeps us well under the rate limit).
        if (real.contains(t.id) && existing[t.id] != null) {
          byId[t.id] = reuseSeriesOnGrid(grid, existing[t.id]!, t.value);
          continue;
        }
        final mint = t.isNative ? SolanaService.wsolMint : t.mint;
        try {
          final candles = await _svc.getRecentCandles(
              mint: mint, range: range.candle, count: range.buckets);
          byId[t.id] = balanceSeriesOnGrid(grid, candles, t.value);
          real.add(t.id);
          commit(); // progressive: show the chart as each holding lands
          await Future.delayed(const Duration(milliseconds: 350)); // ease limit
        } catch (_) {
          // Rate-limited / network: keep this token's prior curve if we have one
          // (re-aligned), else a flat placeholder. Retry it next poll.
          complete = false;
          final prev = existing[t.id];
          byId[t.id] = (prev != null && prev.length >= 2)
              ? reuseSeriesOnGrid(grid, prev, t.value)
              : balanceSeriesOnGrid(grid, const [], t.value);
        }
      }
      if (address != reqAddr) return false;
      real.removeWhere((id) => !visible.any((t) => t.id == id));
      commit(); // final commit folds in any fallbacks
      _persistHistory(); // persists every cached window
      return complete;
    } finally {
      _balLoading.remove(range);
      notifyListeners();
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

    // Roll the balance-graph series forward on their bucket: a fresh value
    // refines the forming bucket, and once the clock crosses into a new one a
    // fresh bucket opens (trimming anything past the window). The series are
    // seeded by _reconstructRange() from candle data; an empty series is left
    // untouched until that lands. `append` only gates the (debounced) persist —
    // the rollover is identical on a poll or a live tick.
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _advance(_historyTotal, nowSec, total, BalanceRange.d1);
    for (final t in list) {
      _advance(_historyById[t.id], nowSec, t.value, BalanceRange.d1);
    }
    // Keep every built 1W/1M window live too — not just the one on screen — so
    // switching to it shows current data without a re-fetch. Reconstruction only
    // seeds/refreshes on holdings change; day-to-day the windows roll forward
    // entirely on live ticks (this is the "live only moves the next bucket"
    // behaviour — history is never rewritten).
    for (final r in [BalanceRange.w1, BalanceRange.m1]) {
      _advance(_balTotalRange[r], nowSec, total, r);
      final byId = _balIdRange[r];
      if (byId != null) {
        for (final t in list) {
          _advance(byId[t.id], nowSec, t.value, r);
        }
      }
    }
    if (append) _persistHistory();

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
    _maybeReconstructHistory();
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
    _balTotalRange.clear();
    _balIdRange.clear();
    _balLoading.clear();
    _balReal.clear();
    balanceRange = BalanceRange.d1;
    _balancesSig = '';
    _chartById.clear();
    _rangeById.clear();
    _chartLoading.clear();
    _chartError.clear();
    _chartSeq++; // invalidate any in-flight loads
    _chartReqToken.clear();
    _productToMints.clear();
    _livePending.clear();
    _liveFlush?.cancel();
    _liveFlush = null;
    _feed.setProducts({}); // drop all live subscriptions
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
      Map<String, dynamic> enc(
              List<Point> total, Map<String, List<Point>> byId) =>
          {
            'total': _tail(total).map((p) => {'x': p.x, 'y': p.y}).toList(),
            'byId': {
              for (final e in byId.entries)
                e.key: _tail(e.value).map((p) => {'x': p.x, 'y': p.y}).toList()
            },
          };
      // One entry per cached window, keyed by range name; restored on next load
      // so 1W/1M show instantly instead of re-fetching from scratch.
      final slim = <String, dynamic>{
        BalanceRange.d1.name: enc(_historyTotal, _historyById),
        for (final r in [BalanceRange.w1, BalanceRange.m1])
          if (_balTotalRange[r] != null)
            r.name: enc(_balTotalRange[r]!, _balIdRange[r] ?? const {}),
      };
      _prefs.setString(_kHistory(address), jsonEncode(slim));
    });
  }

  List<Point> _tail(List<Point> arr) =>
      arr.length <= _persistPoints ? arr : arr.sublist(arr.length - _persistPoints);

  // ---------------------------------------------------------------------------
  void _setStatus(StatusKind kind, String text) {
    // Skip the rebuild when nothing changed — e.g. a steady 'Live' price tick
    // that already called _applyData would otherwise notify a second time.
    if (statusKind == kind && statusText == text) return;
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
    _liveFlush?.cancel();
    _feed.dispose();
    _svc.dispose();
    super.dispose();
  }
}
