// apps/mobile/lib/main.dart
import 'package:flutter/material.dart';

import 'services/discovery.dart';
import 'services/mobile_settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await MobileSettings.load();
  final discovery = DesktopDiscovery()..start();
  runApp(LocalRollMobileApp(settings: settings, discovery: discovery));
}

class LocalRollMobileApp extends StatelessWidget {
  const LocalRollMobileApp({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6B5E);
    return MaterialApp(
      title: 'LocalRoll',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: HomePage(settings: settings, discovery: discovery),
    );
  }
}
