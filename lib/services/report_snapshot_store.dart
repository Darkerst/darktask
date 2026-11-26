import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/logging/app_logger.dart';

const _logSource = 'ReportSnapshotStore';

/// A minimal record of the key "Live overzicht" figures from one
/// generated report — CPU/GPU temperature+load, memory used%, per-disk
/// used%, battery level — saved to disk each time [ReportService]
/// builds a report. The only purpose is letting the *next* report show
/// a genuine "+3°C t.o.v. vorige rapportage" trend line instead of a
/// fabricated-looking comparison: this app never invents a baseline it
/// doesn't actually have (same "no fabricated verdicts" philosophy as
/// the rest of the sensor code), so the very first report ever
/// generated on a machine has nothing to compare against and simply
/// shows no trend lines at all.
class ReportSnapshot {
  final DateTime generatedAt;
  final double? cpuTemperatureC;
  final double? cpuLoadPercent;

  /// Keyed by GpuSample.id (stable across reads), not array index or
  /// name, so a multi-GPU system still compares the same physical card
  /// across two reports even if enumeration order ever changes.
  final Map<String, double> gpuTemperaturesC;
  final Map<String, double> gpuLoadPercent;

  final double memoryUsedPercent;

  /// Keyed by DiskSample.device — stable identity, unlike mountPoint.
  final Map<String, double> diskUsedPercent;

  final int? batteryCapacityPercent;
  final double? batteryHealthPercent;

  const ReportSnapshot({
    required this.generatedAt,
    this.cpuTemperatureC,
    this.cpuLoadPercent,
    this.gpuTemperaturesC = const {},
    this.gpuLoadPercent = const {},
    required this.memoryUsedPercent,
    this.diskUsedPercent = const {},
    this.batteryCapacityPercent,
    this.batteryHealthPercent,
  });

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'cpuTemperatureC': cpuTemperatureC,
        'cpuLoadPercent': cpuLoadPercent,
        'gpuTemperaturesC': gpuTemperaturesC,
        'gpuLoadPercent': gpuLoadPercent,
        'memoryUsedPercent': memoryUsedPercent,
        'diskUsedPercent': diskUsedPercent,
        'batteryCapacityPercent': batteryCapacityPercent,
        'batteryHealthPercent': batteryHealthPercent,
      };

  static ReportSnapshot? fromJson(Map<String, dynamic> json) {
    try {
      Map<String, double> doubleMap(dynamic raw) {
        if (raw is! Map) return const {};
        return raw.map((k, v) => MapEntry(k as String, (v as num).toDouble()));
      }

      return ReportSnapshot(
        generatedAt: DateTime.parse(json['generatedAt'] as String),
        cpuTemperatureC: (json['cpuTemperatureC'] as num?)?.toDouble(),
        cpuLoadPercent: (json['cpuLoadPercent'] as num?)?.toDouble(),
        gpuTemperaturesC: doubleMap(json['gpuTemperaturesC']),
        gpuLoadPercent: doubleMap(json['gpuLoadPercent']),
        memoryUsedPercent: (json['memoryUsedPercent'] as num?)?.toDouble() ?? 0,
        diskUsedPercent: doubleMap(json['diskUsedPercent']),
        batteryCapacityPercent: (json['batteryCapacityPercent'] as num?)?.toInt(),
        batteryHealthPercent: (json['batteryHealthPercent'] as num?)?.toDouble(),
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon opgeslagen rapportmomentopname niet lezen: $e');
      return null;
    }
  }
}

/// One small JSON file holding just the MOST RECENT report snapshot —
/// not a history (BenchmarkHistoryStore already covers "history" for
/// benchmark runs; this only ever needs "the one before this one" to
/// compute a single trend). Same best-effort, never-throws philosophy
/// as BenchmarkHistoryStore/SettingsService: a missing, corrupt, or
/// unwritable file just means "no previous data" or "trend not saved
/// this time", never a crash or a failed report export.
class ReportSnapshotStore {
  const ReportSnapshotStore();

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/report_last_snapshot.json');
  }

  /// The previous report's snapshot, or null when this is the first
  /// report ever generated on this machine (or the file is missing/
  /// corrupted — treated identically to "no previous data").
  Future<ReportSnapshot?> readPrevious() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) return ReportSnapshot.fromJson(decoded);
      return null;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon vorige rapportmomentopname niet lezen: $e');
      return null;
    }
  }

  Future<void> save(ReportSnapshot snapshot) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(snapshot.toJson()));
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Kon rapportmomentopname niet opslaan: $e');
    }
  }
}
