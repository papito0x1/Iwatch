import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A single live price update from the Coinbase feed.
class LivePrice {
  final String product; // e.g. 'SOL-USD'
  final double price;
  const LivePrice(this.product, this.price);
}

/// Real-time USD price feed backed by Coinbase's keyless WebSocket.
///
/// Why Coinbase (vs. the Jupiter REST poll the rest of the app uses): Jupiter
/// has no public WebSocket — its price API is REST-only, so the best it can do
/// is a poll every few seconds. Coinbase exposes a free, no-auth `ticker`
/// channel on `wss://ws-feed.exchange.coinbase.com` that *pushes* a new price on
/// every trade (sub-second), which is as live as a price gets without a paid
/// market-data plan.
///
/// Coverage is the catch: Coinbase only lists majors. Many Solana tokens *are*
/// listed (SOL, BONK, WIF, JTO, PYTH, RAY, ORCA, RENDER, W, HNT, …) but the long
/// tail of SPL tokens is not — those keep flowing through the Jupiter poll. So
/// this feed is an *overlay*: it streams live prices for whatever holdings map
/// to an online Coinbase `<SYMBOL>-USD` product, and the model lets those values
/// override the slower Jupiter quotes while keeping Jupiter as the source of
/// truth for everything else (and for 24h change).
///
/// The feed is deliberately "dumb": it owns only the socket, the set of online
/// products, and the subscription set. Mapping mints ↔ products and deciding
/// which prices to trust lives in the model, so this stays reusable and testable.
class CoinbasePriceFeed {
  CoinbasePriceFeed({this.onPrice});

  static const _wsUrl = 'wss://ws-feed.exchange.coinbase.com';
  static const _productsUrl = 'https://api.exchange.coinbase.com/products';

  /// Curated, spoof-proof mint → Coinbase base symbol map.
  ///
  /// Keyed by the real mainnet mint address so a scam token that merely *names*
  /// itself "SOL" can never inherit the real SOL price. Holdings outside this
  /// list can still stream live, but only after the model corroborates the
  /// Coinbase price against Jupiter's (see WalletModel), which neutralises
  /// symbol spoofing for the long tail too.
  static const trustedMints = <String, String>{
    // SOL (native / wSOL mint)
    'So11111111111111111111111111111111111111112': 'SOL',
    // Wormhole wBTC — drives the live Bitcoin reference chart.
    '3NZ9JMVBmGAqocybic2c7LQCJScmgsAZ6vQqTDzcqmJh': 'BTC',
    // Wormhole wETH
    '7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs': 'ETH',
    'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263': 'BONK',
    'EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm': 'WIF',
    'jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL': 'JTO',
    'HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3': 'PYTH',
    '4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R': 'RAY',
    'orcaEKTdK7LKz57vaAYr9QeNsVEPfiu6QeMU1kektZE': 'ORCA',
    'rndrizKT3MK1iimdxRdWabcF7Zg7AR5T4nud4EkHBof': 'RENDER',
    '85VBFQZC9TZkfaptBWjvUw7YbZjy52A6mjtPGjstQAmQ': 'W',
    'hntyVP6YFm1Hg25TN9WGLqM12b8TQmcknKrdu1oxWux': 'HNT',
    'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v': 'USDC',
    'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB': 'USDT',
  };

  /// Invoked on every received ticker (already throttled by Coinbase's feed, but
  /// the model coalesces these into batched UI updates).
  void Function(LivePrice)? onPrice;

  final HttpClient _http = HttpClient();

  WebSocket? _ws;
  bool _started = false;
  bool _disposed = false;

  /// Online `<BASE>-USD` products Coinbase actually serves (filled once at start).
  Set<String> _online = {};
  bool _haveOnline = false;

  /// Products the model wants; intersected with [_online] before subscribing.
  Set<String> _desired = {};
  Set<String> _subscribed = {};

  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  /// Fetch the online-product universe (once) and open the socket. Safe to call
  /// repeatedly; only the first call does work.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _loadOnlineProducts();
    await _connect();
  }

  /// Set the products to stream, derived from the wallet's holdings. Invalid /
  /// unlisted products are dropped silently. Diffs against the current
  /// subscription so a holdings refresh doesn't churn the whole socket.
  void setProducts(Set<String> products) {
    _desired = products;
    _resubscribe();
  }

  /// True once we know [product] is a real, online Coinbase USD market.
  bool hasProduct(String product) => _online.contains(product);

  bool get isReady => _haveOnline;

  Future<void> _loadOnlineProducts() async {
    try {
      final req = await _http.getUrl(Uri.parse(_productsUrl));
      final res = await req.close().timeout(const Duration(seconds: 12));
      final body = await res.transform(utf8.decoder).join();
      final list = jsonDecode(body);
      if (list is List) {
        final set = <String>{};
        for (final p in list) {
          if (p is! Map) continue;
          if (p['quote_currency'] != 'USD') continue;
          if (p['status'] != 'online') continue;
          final id = p['id'];
          if (id is String) set.add(id);
        }
        _online = set;
      }
    } catch (_) {
      // Leave _online empty — we simply won't subscribe to anything and the app
      // falls back entirely to the Jupiter poll. Retried on the next connect.
    }
    _haveOnline = _online.isNotEmpty;
  }

  Future<void> _connect() async {
    if (_disposed) return;
    try {
      final ws = await WebSocket.connect(_wsUrl)
          .timeout(const Duration(seconds: 15));
      if (_disposed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _reconnectAttempts = 0;
      _subscribed = {}; // fresh socket has no subscriptions
      _resubscribe();
      ws.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final dynamic msg;
    try {
      msg = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    final type = msg['type'];
    // 'ticker' carries every trade; 'snapshot'/'l2update' aren't subscribed.
    if (type != 'ticker') return;
    final product = msg['product_id'];
    final priceRaw = msg['price'];
    if (product is! String) return;
    final price = priceRaw is num
        ? priceRaw.toDouble()
        : (priceRaw is String ? double.tryParse(priceRaw) : null);
    if (price == null || price <= 0) return;
    onPrice?.call(LivePrice(product, price));
  }

  void _onClosed() {
    _ws = null;
    _subscribed = {};
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    // Exponential backoff capped at 30s so a flaky network doesn't hammer.
    final delay = Duration(
        seconds: (1 << _reconnectAttempts.clamp(0, 5)).clamp(1, 30));
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () async {
      if (!_haveOnline) await _loadOnlineProducts();
      await _connect();
    });
  }

  /// Reconcile the live subscription with [_desired] ∩ [_online].
  void _resubscribe() {
    final ws = _ws;
    if (ws == null) return;
    final target = _desired.where(_online.contains).toSet();
    final toAdd = target.difference(_subscribed);
    final toRemove = _subscribed.difference(target);

    if (toRemove.isNotEmpty) {
      ws.add(jsonEncode({
        'type': 'unsubscribe',
        'product_ids': toRemove.toList(),
        'channels': ['ticker'],
      }));
    }
    if (toAdd.isNotEmpty) {
      ws.add(jsonEncode({
        'type': 'subscribe',
        'product_ids': toAdd.toList(),
        'channels': ['ticker'],
      }));
    }
    _subscribed = target;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _ws?.close();
    _ws = null;
    _http.close(force: true);
  }
}
