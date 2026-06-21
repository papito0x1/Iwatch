import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yaru/yaru.dart';

import 'screens/home.dart';
import 'services/solana_service.dart';
import 'state/wallet_model.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide the GTK header bar so we can draw the native Yaru title bar ourselves.
  await YaruWindowTitleBar.ensureInitialized();

  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    size: Size(1320, 880),
    minimumSize: Size(900, 600),
    title: 'Iwatch',
    backgroundColor: AppColors.windowBg,
  );
  windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.maximize(); // open widescreen, filling the monitor
  });

  final prefs = await SharedPreferences.getInstance();
  final model = WalletModel(SolanaService(), prefs)..boot();

  runApp(IwatchApp(model: model));
}

class IwatchApp extends StatelessWidget {
  const IwatchApp({super.key, required this.model});

  final WalletModel model;

  @override
  Widget build(BuildContext context) {
    return YaruTheme(
      builder: (context, yaru, child) {
        final dark = buildTheme(yaru.darkTheme);
        return ChangeNotifierProvider.value(
          value: model,
          child: MaterialApp(
            title: 'Iwatch',
            debugShowCheckedModeBanner: false,
            theme: dark,
            darkTheme: dark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen(),
          ),
        );
      },
    );
  }
}
