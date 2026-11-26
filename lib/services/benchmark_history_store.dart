import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/logging/app_logger.dart';
import '../core/models/benchmark_models.dart';

const _logSource = 'BenchmarkHistoryStore';

/// Persists completed benchmark runs to disk so they survive closing
/// the app — [BenchmarkService]'s own `_sessionHistory` only lives for
/// as long as the app is open, which is fine for "compare against the
/// run I just did a minute ago" but useless for "did that dust-out
/// actually help" or handing a customer a before/after comparison.
///
/// Follows the exact same singleton/load-once/best-effort-save pattern
/// as [SettingsService]: one small JSON file under the platform's
/// application support directory, no cloud sync, nothing leaves this
/// machine. [load] must be awaited once at startup (see `main.dart`),
/// same as SettingsService, so the history is already populated by
/// the time any screen asks for it.
class BenchmarkHistoryStore {
  BenchmarkHistoryStore._();
  static final BenchmarkHistoryStore instance = BenchmarkHistoryStore._();

  /// Caps the file size and the amount a really long-running install
  /// accumulates — old entries roll off the front once this is
  /// exceeded, newest always kept. 300 runs is generous (years of
  /// occasional use) without the file growing unbounded.
  static const int _maxEntries = 300;

  List<BenchmarkResult> _entries = [];
  bool _loaded = false;
  String? _filePath;

  /// All persisted runs, oldest first. Unmodifiable — callers filter
  /// via [forType] rather than mutating this directly.
  List<BenchmarkResult> get entries => List.unmodifiable(_entries);

  List<BenchmarkResult> forType(BenchmarkType type, BenchmarkIntensity intensity) => _entries
      .where((r) => r.type == type && r.intensity == intensity)
      .toList(growable: false);

  /// Human-readable path shown in the UI so it's always clear exactly
  /// where this data lives on disk — no hidden state, same reasoning
  /// as SettingsService.filePath.
  String? get filePath => _filePath;

  bool get isLoaded => _loaded;

  Future<File> _historyFile() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final path = '${dir.path}/benchmark_history.json';
    _filePath = path;
    return File(path);
  }

  /// Loads history from disk, if a file exists yet. Safe to call more
  /// than once. Never throws — a missing, empty, or corrupted file all
  /// just mean "no history yet" rather than a startup failure.
  Future<void> load() async {
    try {
      final file = await _historyFile();
      if (!await file.exists()) {
        _loaded = true;
        return; // no file yet — first run
      }
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is List) {
        _entries = decoded
            .whereType<Map<String, dynamic>>()
            .map(BenchmarkResult.fromJson)
            .whereType<BenchmarkResult>()
            .toList();
      }
      _loaded = true;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Kon benchmarkgeschiedenis niet laden, begint leeg: $e');
      _entries = [];
      _loaded = true;
    }
  }

  /// Appends one completed run and saves immediately. Best-effort —
  /// same reasoning as SettingsService.update: a failed save is logged,
  /// never thrown, since losing one history entry is far less harmful
  /// than crashing the benchmark screen over a disk write error.
  Future<void> add(BenchmarkResult result) async {
    _entries.add(result);
    if (_entries.length > _maxEntries) {
      _entries = _entries.sublist(_entries.length - _maxEntries);
    }
    await _save();
  }

  /// Clears all persisted history (a "wis geschiedenis" action in the
  /// UI) — e.g. before handing a machine to a new owner.
  Future<void> clear() async {
    _entries = [];
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _historyFile();
      final list = _entries.map((r) => r.toJson()).toList();
      await file.writeAsString(jsonEncode(list));
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Kon benchmarkgeschiedenis niet opslaan: $e');
    }
  }

  /// One CSV row per run, oldest first — for handing to a customer or
  /// comparing across machines in a spreadsheet. Deliberately plain
  /// CSV (no external package) since this app already writes its own
  /// log export the same way (see LogViewerScreen._saveToFile).
  String toCsv() {
    final buffer = StringBuffer();
    buffer.writeln(
      'timestamp,type,intensity,score,summary,peakTemperatureC,throttleDetected,aborted,abortReason,actualDurationSeconds',
    );
    for (final r in _entries) {
      final fields = [
        r.timestamp.toIso8601String(),
        r.type.name,
        r.intensity.name,
        r.score?.toStringAsFixed(2) ?? '',
        r.summaryLine,
        r.peakTemperatureC?.toStringAsFixed(1) ?? '',
        r.throttleDetected.toString(),
        r.aborted.toString(),
        r.abortReason ?? '',
        (r.actualDuration.inMilliseconds / 1000).toStringAsFixed(1),
      ];
      buffer.writeln(fields.map(_csvEscape).join(','));
    }
    return buffer.toString();
  }

  String _csvEscape(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }
}
