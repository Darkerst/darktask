import 'package:flutter/material.dart';

import '../models/app_settings.dart';

extension AppThemeModeX on AppThemeMode {
  /// Maps to Flutter's own ThemeMode, which MaterialApp uses to decide
  /// whether to render `theme` (light), `darkTheme` (dark), or follow
  /// the OS (system) — including live-switching if the OS theme changes
  /// while the app is running, with no restart needed.
  ThemeMode get flutterThemeMode {
    switch (this) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  String get label {
    switch (this) {
      case AppThemeMode.system:
        return 'Systeem';
      case AppThemeMode.light:
        return 'Licht';
      case AppThemeMode.dark:
        return 'Donker';
    }
  }
}

/// Builds a full ThemeData for the given brightness and accent seed
/// color. Both light and dark themes are generated from the same
/// [ColorScheme.fromSeed] call (just with a different `brightness`), so
/// switching modes never leaves half the app dark-themed and half
/// light-themed — every screen already reads its colors from
/// `Theme.of(context).colorScheme.*` rather than hardcoded literals,
/// with the sole deliberate exception of metric identity colors (CPU,
/// memory, ...), which come from the separate Colors-tab palette system
/// and are designed to read clearly against either brightness.
ThemeData buildAppTheme({required Brightness brightness, required Color seedColor}) {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    useMaterial3: true,
    // Slightly deeper than colorScheme.surface for the dark theme —
    // matches DarkTask's original look (a near-black, not a lighter
    // Material-default dark grey) rather than the seed-derived
    // surface, which reads a bit lighter than intended when the accent
    // color changes. The light theme uses the seed-derived surface
    // directly since there's no equivalent "original look" to match.
    scaffoldBackgroundColor: brightness == Brightness.dark ? const Color(0xFF121212) : scheme.surface,
  );
}
