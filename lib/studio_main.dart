import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'studio_home.dart';

void main() {
  runZonedGuarded<void>(() {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _recordStartupError(
        details.exception,
        details.stack ?? StackTrace.current,
      );
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _recordStartupError(error, stack);
      return true;
    };

    // Render immediately. Preferences and tool checks happen after the first
    // frame so a plugin or subprocess failure cannot block initial UI startup.
    runApp(const MKWDistributionMakerApp());
  }, (Object error, StackTrace stack) {
    _recordStartupError(error, stack);
  });
}

void _recordStartupError(Object error, StackTrace stack) {
  try {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    final logDirectory = Directory(
      '$home/Library/Logs/MKW Distribution Maker',
    );
    logDirectory.createSync(recursive: true);
    final file = File(logDirectory.path + '/startup.log');
    file.writeAsStringSync(
      '[' +
          DateTime.now().toIso8601String() +
          '] ' +
          error.toString() +
          '\n' +
          stack.toString() +
          '\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // Error reporting must never cause a second startup failure.
  }
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
