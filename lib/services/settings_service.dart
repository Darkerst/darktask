import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/logging/app_logger.dart';
import '../core/models/app_settings.dart';

const _logSource = 'SettingsService';

/// App-wide settings singleton, following the same pattern as
/// [AppLogger]: one shared instance, read via [SettingsService.instance]
/// from anywhere that needs a setting's current value.
///
/// Persists to a small JSON file under the platform's application
/// support directory (e.g. `~/.local/share/darktask/settings.json` on
/// Linux) — no cloud sync, no telemetry, same "everything stays on this
/// machine" approach as the sensor services. [load] must be awaited
/// once at startup (see `main.dart`) before the first frame, so the UI
/// never flashes defaults and then jumps to the saved values.
///
/// Extends [ChangeNotifier] so screens that need to react live to a
/// setting changing (e.g. a poll timer picking up a new interval
/// without needing the screen to be rebuilt) can call
/// `SettingsService.instance.addListener(...)` directly, the same way
/// they'd listen to any other Flutter-idiomatic notifier.
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  AppSettings _current = AppSettings.defaults;
  AppSettings get current => _current;

  bool _loaded = false;
  String? _filePath;

  Future<File> _settingsFile() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final path = '${dir.path}/settings.json';
    _filePath = path;
    return File(path);
  }

  /// Human-readable path shown in the Settings screen so it's always
  /// clear exactly where this data lives on disk — no hidden state.
  String? get filePath => _filePath;

  /// Loads settings from disk, if a settings file exists yet. Safe to
  /// call more than once (e.g. a manual "reload" action); each call
  /// re-reads from disk and notifies listeners if anything changed.
  Future<void> load() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) {
        _loaded = true;
        return; // no file yet — first run, defaults stand
      }
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        _current = AppSettings.fromJson(decoded);
      }
      _loaded = true;
      notifyListeners();
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to load settings, using defaults: $e');
      _current = AppSettings.defaults;
      _loaded = true;
    }
  }

  /// Applies [transform] to the current settings, persists the result,
  /// and notifies listeners — the single path every settings change
  /// goes through, so "changed in memory" and "saved to disk" can never
  /// drift apart.
  Future<void> update(AppSettings Function(AppSettings current) transform) async {
    final next = transform(_current);
    _current = next;
    notifyListeners(); // apply immediately; persistence below is best-effort
    try {
      final file = await _settingsFile();
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(next.toJson()));
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to save settings: $e');
    }
  }

  Future<void> resetToDefaults() => update((_) => AppSettings.defaults);

  bool get isLoaded => _loaded;
}
