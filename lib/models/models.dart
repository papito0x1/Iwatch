// Data models for the Solana Wallet Tracker.

/// A raw on-chain balance entry (SOL or an SPL / Token-2022 mint).
class Balance {
  final String id; // 'SOL' for native, otherwise the mint
  final String mint;
  final bool isNative;
  final int decimals;
  final double uiAmount;

  const Balance({
    required this.id,
    required this.mint,
    required this.isNative,
    required this.decimals,
    required this.uiAmount,
  });
}

/// Token metadata from Jupiter's token search (symbol / name / icon).
class TokenMeta {
  final String? symbol;
  final String? name;
  final String? icon;
  final int? decimals;

  const TokenMeta({this.symbol, this.name, this.icon, this.decimals});

  factory TokenMeta.fromJson(Map<String, dynamic> j) => TokenMeta(
        symbol: j['symbol'] as String?,
        name: j['name'] as String?,
        icon: j['icon'] as String?,
        decimals: j['decimals'] is num ? (j['decimals'] as num).toInt() : null,
      );
}

/// A live USD price plus 24h change for a mint.
class PriceInfo {
  final double usdPrice;
  final double? priceChange24h;

  const PriceInfo({required this.usdPrice, this.priceChange24h});
}

/// A single time-series point (x = epoch ms, y = value).
class Point {
  final double x;
  final double y;
  const Point(this.x, this.y);
}

/// A fully enriched token row ready for the UI (balance + meta + price + value).
class TokenRow {
  final String id;
  final String mint;
  final bool isNative;
  final String symbol;
  final String name;
  final String? icon;
  final double amount;
  final double? price;
  final double? change;
  final double value;

  const TokenRow({
    required this.id,
    required this.mint,
    required this.isNative,
    required this.symbol,
    required this.name,
    required this.icon,
    required this.amount,
    required this.price,
    required this.change,
    required this.value,
  });
}

/// Result of a balances fetch.
class BalancesResult {
  final int asOf;
  final String address;
  final List<Balance> tokens;
  const BalancesResult(
      {required this.asOf, required this.address, required this.tokens});
}
