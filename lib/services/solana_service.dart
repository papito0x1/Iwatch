import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// Port of the Electron `main.js` backend: talks to Solana JSON-RPC for
/// balances and to Jupiter for prices + token metadata.
///
/// Running natively there is no CORS and no need for an IPC bridge — these
/// requests run straight from the Dart isolate.
class SolanaService {
  static const defaultRpc = 'https://api.mainnet-beta.solana.com';
  static const tokenProgram = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
  static const token2022Program = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
  static const wsolMint = 'So11111111111111111111111111111111111111112';

  static const _jupSearch = 'https://lite-api.jup.ag/tokens/v2/search';
  static const _jupPrice = 'https://lite-api.jup.ag/price/v3';
  static const _geckoBase = 'https://api.geckoterminal.com/api/v2';

  static final _addressRe = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');

  final http.Client _client = http.Client();

  // In-process metadata cache (mint -> meta), mirrors main.js metaCache.
  final Map<String, TokenMeta?> _metaCache = {};

  // Chart pools: mint -> GeckoTerminal pool address (highest-volume pool).
  final Map<String, String> _poolCache = {};

  // ---- small helpers --------------------------------------------------------

  Future<dynamic> _fetchJson(String url,
      {Map<String, String>? headers,
      Object? body,
      String method = 'GET',
      Duration timeout = const Duration(seconds: 20)}) async {
    final uri = Uri.parse(url);
    final future = method == 'POST'
        ? _client.post(uri, headers: headers, body: body)
        : _client.get(uri, headers: headers);
    final res = await future.timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // Read body for a friendlier error when the server explains itself.
      final body = res.body.length < 200 ? res.body : '';
      throw Exception('HTTP ${res.statusCode}${body.isNotEmpty ? ': $body' : ''}');
    }
    return jsonDecode(res.body);
  }

  static List<List<T>> _chunk<T>(List<T> arr, int size) {
    final out = <List<T>>[];
    for (var i = 0; i < arr.length; i += size) {
      out.add(arr.sublist(i, i + size > arr.length ? arr.length : i + size));
    }
    return out;
  }

  static final _transient = RegExp(
      r'\b429\b|HTTP 5\d\d|too many|rate|timeout|aborted|fetch failed',
      caseSensitive: false);

  /// Retry transient throttling / 5xx with a short backoff.
  ///
  /// HTTP 429 (rate-limit) gets a slightly longer pause than other transient
  /// errors, but kept short enough that the UI never appears to hang — we lean
  /// on making few requests instead of waiting out long cooldowns.
  Future<T> _withRetry<T>(Future<T> Function() fn, {int attempts = 3}) async {
    Object? lastErr;
    for (var i = 0; i < attempts; i++) {
      try {
        return await fn();
      } catch (e) {
        lastErr = e;
        final msg = e.toString();
        if (_transient.hasMatch(msg) && i < attempts - 1) {
          final isRateLimit = msg.contains('429');
          await Future.delayed(Duration(
              milliseconds: isRateLimit ? 4000 : (600 * (i + 1))));
          continue;
        }
      }
    }
    throw _friendly(lastErr!);
  }

  /// Turn raw HTTP/network errors into short user-facing messages.
  static Exception _friendly(Object e) {
    final s = e.toString();
    if (s.contains('429')) {
      return Exception(
          'Rate-limited by the chart provider. Try again in a moment.');
    }
    if (RegExp(r'HTTP 5\d\d').hasMatch(s)) {
      return Exception('Chart server is temporarily unavailable.');
    }
    if (s.contains('No liquidity pool')) return Exception(s);
    return Exception('Could not load chart data.');
  }

  /// Single (non-batched) Solana JSON-RPC call — public RPCs throttle batches
  /// far more aggressively, so sequential singles are more reliable.
  Future<dynamic> _rpc(String url, String method, List<dynamic> params) async {
    final data = await _fetchJson(
      url,
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
    );
    if (data is Map && data['error'] != null) {
      throw Exception(data['error']['message'] ?? 'RPC error');
    }
    return data is Map ? data['result'] : null;
  }

  // ---- balances (heavier, on-chain) -----------------------------------------

  Future<BalancesResult> getBalances(
      {required String address, String? rpcUrl}) async {
    final addr = address.trim();
    if (!_addressRe.hasMatch(addr)) {
      throw Exception('That does not look like a valid Solana address.');
    }
    final url = (rpcUrl != null && rpcUrl.trim().isNotEmpty)
        ? rpcUrl.trim()
        : defaultRpc;

    dynamic balance, std, t22;
    try {
      balance = await _withRetry(() => _rpc(url, 'getBalance', [addr]));
      std = await _withRetry(() => _rpc(url, 'getTokenAccountsByOwner', [
            addr,
            {'programId': tokenProgram},
            {'encoding': 'jsonParsed'}
          ]));
      t22 = await _withRetry(() => _rpc(url, 'getTokenAccountsByOwner', [
            addr,
            {'programId': token2022Program},
            {'encoding': 'jsonParsed'}
          ]));
    } catch (e) {
      final msg = e.toString();
      if (RegExp(r'\b429\b|too many|rate', caseSensitive: false).hasMatch(msg) &&
          !(rpcUrl != null && rpcUrl.trim().isNotEmpty)) {
        throw Exception(
            'Public RPC is rate-limited (429). Add a custom RPC in Settings.');
      }
      rethrow;
    }

    // Aggregate SPL token accounts by mint.
    final map = <String, _Agg>{};
    final accounts = [
      ...((std?['value'] as List?) ?? []),
      ...((t22?['value'] as List?) ?? []),
    ];
    for (final acc in accounts) {
      final info = acc?['account']?['data']?['parsed']?['info'];
      if (info == null) continue;
      final ta = info['tokenAmount'];
      final ui = (ta?['uiAmount'] as num?)?.toDouble() ?? 0;
      if (ui <= 0) continue;
      final mint = info['mint'] as String;
      final prev = map[mint] ??
          _Agg(mint: mint, decimals: (ta['decimals'] as num).toInt());
      prev.uiAmount += ui;
      map[mint] = prev;
    }

    final tokens = <Balance>[];
    final lamports = (balance?['value'] as num?)?.toDouble() ?? 0;
    tokens.add(Balance(
      id: 'SOL',
      mint: wsolMint,
      isNative: true,
      decimals: 9,
      uiAmount: lamports / 1e9,
    ));
    for (final t in map.values) {
      tokens.add(Balance(
        id: t.mint,
        mint: t.mint,
        isNative: false,
        decimals: t.decimals,
        uiAmount: t.uiAmount,
      ));
    }

    return BalancesResult(
        asOf: DateTime.now().millisecondsSinceEpoch, address: addr, tokens: tokens);
  }

  // ---- prices (light, frequent) ---------------------------------------------

  Future<Map<String, PriceInfo>> getPrices(List<String> mints) async {
    final unique = {...mints.where((m) => m.isNotEmpty)}.toList();
    final out = <String, PriceInfo>{};
    final groups = _chunk(unique, 50);
    for (var i = 0; i < groups.length; i++) {
      try {
        final data =
            await _fetchJson('$_jupPrice?ids=${groups[i].join(',')}');
        if (data is Map) {
          data.forEach((mint, info) {
            if (info is Map && info['usdPrice'] is num) {
              out[mint as String] = PriceInfo(
                usdPrice: (info['usdPrice'] as num).toDouble(),
                priceChange24h: info['priceChange24h'] is num
                    ? (info['priceChange24h'] as num).toDouble()
                    : null,
              );
            }
          });
        }
      } catch (_) {
        // Leave missing mints unpriced.
      }
      if (i < groups.length - 1) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
    return out;
  }

  // ---- token metadata (cached) ----------------------------------------------

  Future<Map<String, TokenMeta?>> getMeta(List<String> mints) async {
    final unique = {...mints.where((m) => m.isNotEmpty)}.toList();
    final missing = unique.where((m) => !_metaCache.containsKey(m)).toList();

    final groups = _chunk(missing, 50);
    for (var gi = 0; gi < groups.length; gi++) {
      final group = groups[gi];
      try {
        final data = await _fetchJson('$_jupSearch?query=${group.join(',')}');
        final list = data is List ? data : const [];
        for (final t in list) {
          final id = t?['id'];
          if (id is! String) continue;
          _metaCache[id] = TokenMeta.fromJson(Map<String, dynamic>.from(t));
        }
      } catch (_) {
        // ignore; unresolved mints fall back to truncated address in the UI
      }
      if (gi < groups.length - 1) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }

    final out = <String, TokenMeta?>{};
    for (final m in unique) {
      out[m] = _metaCache[m];
    }
    return out;
  }

  // ---- price chart (OHLCV, keyless via GeckoTerminal) -----------------------

  /// Well-known stablecoin tickers GeckoTerminal uses as quote tokens.
  static const _stableTickers = {'USDC', 'USDT', 'USDD', 'DAI', 'USD'};

  /// Resolve a GeckoTerminal pool address for a mint.
  ///
  /// Prefers the highest-volume pool whose quote token is a stablecoin (USDC,
  /// USDT, …) so the OHLCV values are in USD. Falls back to the #1 pool by
  /// raw volume if no stable-quoted pool exists on page 1.
  Future<String> _resolvePool(String mint) async {
    final normalized = mint == wsolMint || mint == 'SOL' ? wsolMint : mint;
    final cached = _poolCache[normalized];
    if (cached != null) return cached;

    final data = await _withRetry(() => _fetchJson(
      '$_geckoBase/networks/solana/tokens/$normalized/pools?page=1',
      timeout: const Duration(seconds: 15),
    ));
    final list = data is Map ? (data['data'] as List?) : null;
    if (list == null || list.isEmpty) {
      throw Exception('No liquidity pool found for this token.');
    }

    // Strategy: among stable-quoted pools (USDC/USDT), prefer the oldest one —
    // it has the deepest history. High-volume-but-new pools give only days of
    // data. If no stable pool exists, fall back to the highest-volume pool.
    String? bestId;
    String? bestCreated;
    String? fallbackId;
    double fallbackVol = -1;

    for (final p in list) {
      final attrs = p is Map ? p['attributes'] : null;
      if (attrs is! Map) continue;
      final id = (p['id'] as String?)?.split('_').last;
      if (id == null) continue;
      final created = (attrs['pool_created_at'] as String?) ?? '';

      // A pool is "stable-quoted" if the quote token price is ≈1 USD or the
      // pair name ends with a stable ticker.
      final name = (attrs['name'] as String?) ?? '';
      final quoteUsdRaw = attrs['quote_token_price_usd'];
      final quoteUsd = quoteUsdRaw is num
          ? quoteUsdRaw.toDouble()
          : quoteUsdRaw is String
              ? double.tryParse(quoteUsdRaw)
              : null;
      final quoteTicker = name.split('/').last.trim().toUpperCase();
      final isStable = _stableTickers.contains(quoteTicker) ||
          (quoteUsd != null && quoteUsd > 0.5 && quoteUsd < 1.5);

      // Fallback: track highest-volume pool overall.
      final volRaw = attrs['volume_usd'] is Map
          ? attrs['volume_usd']['h24']
          : null;
      final vol = volRaw == null
          ? 0.0
          : volRaw is num
              ? volRaw.toDouble()
              : (double.tryParse('$volRaw') ?? 0.0);
      if (vol > fallbackVol) {
        fallbackVol = vol;
        fallbackId = id;
      }

      // Prefer the oldest stable pool (lexicographic on ISO date works).
      if (isStable && (bestCreated == null || created.compareTo(bestCreated) < 0)) {
        bestCreated = created;
        bestId = id;
      }
    }
    final chosen = bestId ?? fallbackId;
    if (chosen == null) {
      throw Exception('No liquidity pool found for this token.');
    }
    _poolCache[normalized] = chosen;
    return chosen;
  }

  /// Fetch OHLCV candles for a token over a given chart range.
  ///
  /// Returns candles oldest-first, newest last. Paginates backwards via
  /// `before_timestamp` to collect up to ~6 months of history.
  Future<List<Candle>> getCandles(
      {required String mint, required ChartRange range}) async {
    final pool = await _resolvePool(mint);
    final sixMonthsAgo =
        DateTime.now().subtract(const Duration(days: 180)).millisecondsSinceEpoch;

    // GeckoTerminal's keyless OHLCV endpoint caps `limit` at 1000 and rate-limits
    // hard (~30 req/min). One request of up to 1000 candles is plenty for the
    // chart and keeps us to a single call per load (pool lookup is cached), so a
    // few range/token switches don't trip the limiter.
    final bucketSec = _bucketSeconds(range);
    final totalBuckets = (DateTime.now().millisecondsSinceEpoch ~/ 1000 -
            sixMonthsAgo ~/ 1000) ~/
        bucketSec;
    final want = totalBuckets.clamp(200, 1000);
    final perPage = 1000;

    var all = <Candle>[];
    int? beforeTs;
    var pages = 0;

    // Paginate until we have enough or run out of data.
    while (all.length < want) {
      pages++;
      final remaining = want - all.length;
      final limit = remaining < perPage ? remaining : perPage;
      var url =
          '$_geckoBase/networks/solana/pools/$pool/ohlcv/${range.timeframe}'
          '?aggregate=${range.aggregate}&limit=$limit';
      if (beforeTs != null) url += '&before_timestamp=$beforeTs';

      final data = await _withRetry(() => _fetchJson(url,
          timeout: const Duration(seconds: 15)));
      final list = data is Map
          ? (data['data']?['attributes']?['ohlcv_list'] as List?)
          : null;
      if (list == null || list.isEmpty) break;

      final page = list
          .whereType<List>()
          .map((r) => Candle.fromGeckoRow(r))
          .toList();

      // Don't go beyond 6 months ago.
      final cutoff = page.lastWhere(
          (c) => c.time * 1000 >= sixMonthsAgo,
          orElse: () => page.first);
      final trimmed = page.where((c) => c.time * 1000 >= sixMonthsAgo).toList();
      all.insertAll(0, trimmed); // prepend older candles

      if (cutoff.time * 1000 <= sixMonthsAgo) break; // reached the window
      // GeckoTerminal returns each page newest-first, so the oldest row is last;
      // page from there to walk further back in time.
      final nextBefore = page.last.time;
      if (beforeTs != null && nextBefore >= beforeTs) break; // not progressing
      beforeTs = nextBefore;
      if (pages >= 12) break; // hard safety cap
      await Future.delayed(const Duration(milliseconds: 200)); // be polite
    }

    // GeckoTerminal returns candles newest-first; the chart expects oldest-first
    // (left = oldest, right = newest). Sort ascending and drop duplicate
    // timestamps that can appear at page boundaries.
    all.sort((a, b) => a.time.compareTo(b.time));
    final deduped = <Candle>[];
    for (final c in all) {
      if (deduped.isEmpty || deduped.last.time != c.time) deduped.add(c);
    }
    return deduped;
  }

  /// Fetch just the most recent [count] candles for a token (single small
  /// request) — used for live chart updates. Returns them oldest-first.
  Future<List<Candle>> getRecentCandles(
      {required String mint,
      required ChartRange range,
      int count = 4}) async {
    final pool = await _resolvePool(mint);
    final url =
        '$_geckoBase/networks/solana/pools/$pool/ohlcv/${range.timeframe}'
        '?aggregate=${range.aggregate}&limit=$count';
    final data =
        await _withRetry(() => _fetchJson(url, timeout: const Duration(seconds: 12)));
    final list = data is Map
        ? (data['data']?['attributes']?['ohlcv_list'] as List?)
        : null;
    if (list == null || list.isEmpty) return const [];
    final candles = list
        .whereType<List>()
        .map((r) => Candle.fromGeckoRow(r))
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return candles;
  }

  /// Duration of one candle bucket in seconds.
  static int _bucketSeconds(ChartRange r) => switch (r) {
        ChartRange.m5 => 5 * 60,
        ChartRange.m15 => 15 * 60,
        ChartRange.h1 => 3600,
        ChartRange.h4 => 4 * 3600,
        ChartRange.d1 => 86400,
      };

  void dispose() => _client.close();
}

class _Agg {
  final String mint;
  final int decimals;
  double uiAmount = 0;
  _Agg({required this.mint, required this.decimals});
}
