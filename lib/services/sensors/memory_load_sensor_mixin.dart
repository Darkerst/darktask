import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/load_sample.dart';
import '../../core/models/memory_sample.dart';

const _logSource = 'LinuxSensorService';

/// Memory and system-load reads: /proc/meminfo and /proc/loadavg.
///
/// Split out of the former single `LinuxSensorService` god-file — see
/// `linux_sensor_service.dart` for how the domain mixins are composed.
mixin MemoryLoadSensorMixin {
  /// Reads /proc/loadavg: 1/5/15-minute load averages plus a
  /// "runnable/total" task count that's conveniently in the same file
  /// (format: "1.71 1.84 1.78 1/1297 12345").
  Future<LoadSample> readLoad() async {
    try {
      final content = await File('/proc/loadavg').readAsString();
      final parts = content.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) return LoadSample.empty();

      final load1 = double.tryParse(parts[0]) ?? 0;
      final load5 = double.tryParse(parts[1]) ?? 0;
      final load15 = double.tryParse(parts[2]) ?? 0;

      final taskParts = parts[3].split('/');
      final running = taskParts.isNotEmpty ? int.tryParse(taskParts[0]) ?? 0 : 0;
      final total = taskParts.length > 1 ? int.tryParse(taskParts[1]) ?? 0 : 0;

      return LoadSample(
        load1: load1,
        load5: load5,
        load15: load15,
        runningTasks: running,
        totalTasks: total,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read /proc/loadavg: $e');
      return LoadSample.empty();
    }
  }

  /// Reads memory info from /proc/meminfo.
  Future<MemorySample> readMemory() async {
    try {
      final lines = await File('/proc/meminfo').readAsLines();
      final map = <String, int>{};
      for (final line in lines) {
        final match = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
        if (match != null) {
          map[match.group(1)!] = int.parse(match.group(2)!);
        }
      }

      final total = map['MemTotal'] ?? 0;
      final available = map['MemAvailable'] ?? 0;
      final cached = map['Cached'] ?? 0;
      final used = total - available;
      final swapTotal = map['SwapTotal'] ?? 0;
      final swapFree = map['SwapFree'] ?? 0;
      final swapUsed = swapTotal - swapFree;

      return MemorySample(
        timestamp: DateTime.now(),
        totalKiB: total,
        usedKiB: used,
        availableKiB: available,
        cachedKiB: cached,
        swapTotalKiB: swapTotal,
        swapUsedKiB: swapUsed,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read memory stats: $e\n$st');
      return MemorySample.empty();
    }
  }
}
