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

  static final _addressRe = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');

  final http.Client _client = http.Client();

  // In-process metadata cache (mint -> meta), mirrors main.js metaCache.
  final Map<String, TokenMeta?> _metaCache = {};

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
      throw Exception('HTTP ${res.statusCode} from $url');
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
  Future<T> _withRetry<T>(Future<T> Function() fn, {int attempts = 3}) async {
    Object? lastErr;
    for (var i = 0; i < attempts; i++) {
      try {
        return await fn();
      } catch (e) {
        lastErr = e;
        if (_transient.hasMatch(e.toString()) && i < attempts - 1) {
          await Future.delayed(Duration(milliseconds: 700 * (i + 1)));
          continue;
        }
        rethrow;
      }
    }
    throw lastErr!;
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

  void dispose() => _client.close();
}

class _Agg {
  final String mint;
  final int decimals;
  double uiAmount = 0;
  _Agg({required this.mint, required this.decimals});
}
