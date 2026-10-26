import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart' show defaultSettingsValues;
import 'studio_home.dart';
import 'utils/wiimm_tools.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('version', 'v1.0.0');
  await prefs.setString('profile', '');
  await prefs.setBool('download_already_check', false);

  // Seed the same settings used by CTDM's proven pack-building backend.
  for (final entry in defaultSettingsValues.entries) {
    if (prefs.containsKey(entry.key)) continue;
    if (entry.value is bool) {
      await prefs.setBool(entry.key, entry.value as bool);
    } else {
      await prefs.setString(entry.key, entry.value.toString());
    }
  }

  // Check the copies bundled inside the app, but don't block the UI if a
  // packaging problem exists; the builder can show the actionable error.
  try {
    final result = await Process.run(
      resolveWiimmTool('wlect'),
      ['--version'],
      runInShell: false,
    );
    await prefs.setBool('szs', result.exitCode == 0);
  } on Object {
    await prefs.setBool('szs', false);
  }
  try {
    final result = await Process.run(
      resolveWiimmTool('wit'),
      ['--version'],
      runInShell: false,
    );
    await prefs.setBool('wit', result.exitCode == 0);
  } on Object {
    await prefs.setBool('wit', false);
  }

  runApp(const MKWDistributionMakerApp());
}

class MKWDistributionMakerApp extends StatelessWidget {
  const MKWDistributionMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF101216);
    const surface = Color(0xFF1A1D24);
    const red = Color(0xFFE8494F);
    const gold = Color(0xFFFFC857);

    return MaterialApp(
      title: 'MKW Distribution Maker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: red,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFF2B303A)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: red,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const StudioHome(gold: gold),
    );
  }
}
