import 'package:flutter/material.dart';

import '../models/app_settings.dart';

/// Maps [AppAccentTheme] presets to actual seed colors and a human
/// label. Kept in its own small file (rather than inline in app.dart or
/// settings_screen.dart) since both of those need it: app.dart to
/// build the MaterialApp's theme, and the Settings screen to render the
/// color picker — putting it in either one would make the other import
/// it circularly.
extension AppAccentThemeColor on AppAccentTheme {
  Color get seedColor {
    switch (this) {
      case AppAccentTheme.cyan:
        return Colors.cyan;
      case AppAccentTheme.green:
        return Colors.greenAccent;
      case AppAccentTheme.amber:
        return Colors.amber;
      case AppAccentTheme.blue:
        return Colors.lightBlueAccent;
      case AppAccentTheme.mono:
        return Colors.blueGrey;
    }
  }

  String get label {
    switch (this) {
      case AppAccentTheme.cyan:
        return 'Cyan (standaard)';
      case AppAccentTheme.green:
        return 'Classic Green';
      case AppAccentTheme.amber:
        return 'Amber';
      case AppAccentTheme.blue:
        return 'Blue';
      case AppAccentTheme.mono:
        return 'Monochrome';
    }
  }
}
