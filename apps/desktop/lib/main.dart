// apps/desktop/lib/main.dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_services.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final services = await AppServices.create();
  runApp(LocalRollApp(services: services));
}

class LocalRollApp extends StatelessWidget {
  const LocalRollApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6B5E);
    return MaterialApp(
      title: 'LocalRoll',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: HomeShell(services: services),
    );
  }
}
