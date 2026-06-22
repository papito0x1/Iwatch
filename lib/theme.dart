import 'package:flutter/material.dart';

/// Ubuntu / Yaru palette. No Solana colours — Ubuntu Orange is the accent,
/// aubergine the secondary brand tone, on Yaru-dark neutral surfaces so the
/// app sits naturally next to Files, Settings and Resources.
class AppColors {
  // neutral surfaces (Yaru dark)
  static const windowBg = Color(0xFF1E1E1E); // detail / content background
  static const paneBg = Color(0xFF242424); // sidebar
  static const card = Color(0xFF303030); // boxed lists / chart cards
  static const cardHi = Color(0xFF383838); // hover / selected tile
  static const border = Color(0x14FFFFFF); // rgba(255,255,255,0.08)
  static const borderStrong = Color(0x26FFFFFF);
  static const divider = Color(0x12FFFFFF);

  // text
  static const text = Color(0xFFFFFFFF);
  static const text2 = Color(0xFFDEDEDE);
  static const muted = Color(0xFFADACAA); // Yaru warm grey
  static const muted2 = Color(0xFF8E8E8A);

  // brand
  static const orange = Color(0xFFE95420); // Ubuntu Orange
  static const orangeHi = Color(0xFFF4602E);
  static const aubergine = Color(0xFF77216F);

  // semantic (portfolio up / down)
  static const up = Color(0xFF2EC27E);
  static const down = Color(0xFFED333B);
  static const warn = Color(0xFFE5A50A);

  // trading chart (near-black panel, TradingView/jup.ag style)
  static const chartBg = Color(0xFF0E0F14);
  static const chartGrid = Color(0x0DFFFFFF); // faint grid lines
  static const chartAxis = Color(0xFF6E6E78); // axis label grey

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [orange, aubergine],
  );
}

/// Dark theme derived from Yaru, recoloured to the Ubuntu accent.
ThemeData buildTheme(ThemeData yaruDark) {
  final base = yaruDark;
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.windowBg,
    canvasColor: AppColors.windowBg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.orange,
      secondary: AppColors.aubergine,
      surface: AppColors.card,
      onSurface: AppColors.text,
      error: AppColors.down,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.divider,
    iconTheme: const IconThemeData(color: AppColors.muted),
  );
}
