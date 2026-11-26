import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/cpu_detail_info.dart';
import '../../core/models/cpu_sample.dart';

const _logSource = 'LinuxSensorService';

/// CPU-related reads: instantaneous load (via /proc/stat diffing),
/// average clock speed, temperature (hwmon or lm-sensors), RAPL package
/// power, static `lscpu`-derived details, and system-wide thread count.
///
/// Split out of the former single `LinuxSensorService` god-file — see
/// `linux_sensor_service.dart` for how the domain mixins are composed.
mixin CpuSensorMixin {
  List<int>? _prevCpuTotals;
  List<List<int>>? _prevPerCoreTotals;

  /// Reads current CPU load by diffing two /proc/stat snapshots.
  /// On the very first call there is no previous snapshot, so it returns
  /// a zeroed sample; callers should discard the first reading.
  Future<CpuSample> readCpu() async {
    try {
      final lines = await File('/proc/stat').readAsLines();
      final coreLines = lines.where((l) => RegExp(r'^cpu\d+ ').hasMatch(l)).toList();
      final overallLine = lines.firstWhere((l) => l.startsWith('cpu '));

      final overallTotals = _parseStatLine(overallLine);
      final perCoreTotals = coreLines.map(_parseStatLine).toList();

      double overallLoad = 0;
      double systemLoad = 0;
      if (_prevCpuTotals != null) {
        overallLoad = _computeLoad(_prevCpuTotals!, overallTotals);
        systemLoad = _computeSystemLoad(_prevCpuTotals!, overallTotals);
      }

      final perCoreLoad = <double>[];
      if (_prevPerCoreTotals != null &&
          _prevPerCoreTotals!.length == perCoreTotals.length) {
        for (var i = 0; i < perCoreTotals.length; i++) {
          perCoreLoad.add(_computeLoad(_prevPerCoreTotals![i], perCoreTotals[i]));
        }
      } else {
        perCoreLoad.addAll(List.filled(perCoreTotals.length, 0));
      }

      _prevCpuTotals = overallTotals;
      _prevPerCoreTotals = perCoreTotals;

      final clockMHz = await _readAverageClockMHz();
      final tempC = await _readCpuTemperature();

      return CpuSample(
        timestamp: DateTime.now(),
        overallLoadPercent: overallLoad,
        systemLoadPercent: systemLoad,
        perCoreLoadPercent: perCoreLoad,
        clockMHz: clockMHz,
        temperatureC: tempC,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read CPU stats: $e\n$st');
      return CpuSample.empty();
    }
  }

  List<int> _parseStatLine(String line) {
    // Format: cpu  user nice system idle iowait irq softirq steal guest guest_nice
    final parts = line.trim().split(RegExp(r'\s+')).skip(1);
    return parts.map((p) => int.tryParse(p) ?? 0).toList();
  }

  double _computeLoad(List<int> prev, List<int> curr) {
    final prevIdle = prev.length > 3 ? prev[3] + (prev.length > 4 ? prev[4] : 0) : 0;
    final currIdle = curr.length > 3 ? curr[3] + (curr.length > 4 ? curr[4] : 0) : 0;

    final prevTotal = prev.fold<int>(0, (a, b) => a + b);
    final currTotal = curr.fold<int>(0, (a, b) => a + b);

    final totalDelta = currTotal - prevTotal;
    final idleDelta = currIdle - prevIdle;

    if (totalDelta <= 0) return 0;
    final load = (1 - (idleDelta / totalDelta)) * 100;
    return load.clamp(0, 100).toDouble();
  }

  /// Time spent in kernel/system mode specifically (the "Kernel" line
  /// on the summary chart) — /proc/stat field index 2, same total-delta
  /// denominator as the overall load calculation above.
  double _computeSystemLoad(List<int> prev, List<int> curr) {
    if (prev.length <= 2 || curr.length <= 2) return 0;

    final prevTotal = prev.fold<int>(0, (a, b) => a + b);
    final currTotal = curr.fold<int>(0, (a, b) => a + b);
    final totalDelta = currTotal - prevTotal;
    if (totalDelta <= 0) return 0;

    final systemDelta = curr[2] - prev[2];
    final load = (systemDelta / totalDelta) * 100;
    return load.clamp(0, 100).toDouble();
  }

  Future<double?> _readAverageClockMHz() async {
    try {
      final content = await File('/proc/cpuinfo').readAsString();
      final matches = RegExp(r'cpu MHz\s*:\s*([\d.]+)').allMatches(content);
      if (matches.isEmpty) return null;
      final values = matches
          .map((m) => double.tryParse(m.group(1) ?? '') ?? 0)
          .where((v) => v > 0)
          .toList();
      if (values.isEmpty) return null;
      return values.reduce((a, b) => a + b) / values.length;
    } catch (_) {
      return null;
    }
  }

  /// Public, side-effect-free CPU temperature read — same underlying
  /// hwmon/lm-sensors lookup as the one folded into [readCpu], but
  /// callable on its own. Exists so [GpuSensorMixin] can use it as a
  /// fallback for integrated GPUs that share a die with the CPU (most
  /// Intel iGPUs) and therefore have no separate GPU-specific thermal
  /// sensor exposed by the kernel — without needing to go through
  /// [readCpu] itself, which also diffs /proc/stat for load and would
  /// be the wrong thing to call just to get a temperature.
  Future<double?> readCpuTemperatureOnly() => _readCpuTemperature();

  Future<double?> _readCpuTemperature() async {
    // Try common hwmon paths first (no external process needed).
    try {
      final hwmonDir = Directory('/sys/class/hwmon');
      if (await hwmonDir.exists()) {
        await for (final entry in hwmonDir.list()) {
          final nameFile = File('${entry.path}/name');
          if (!await nameFile.exists()) continue;
          final name = (await nameFile.readAsString()).trim();
          if (name == 'coretemp' || name == 'k10temp' || name == 'zenpower') {
            final tempFile = File('${entry.path}/temp1_input');
            if (await tempFile.exists()) {
              final raw = int.tryParse((await tempFile.readAsString()).trim());
              if (raw != null) return raw / 1000.0;
            }
          }
        }
      }
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'hwmon temperature read failed: $e');
    }

    // Fall back to `sensors -j` (lm-sensors) if hwmon didn't yield anything.
    try {
      final result = await Process.run('sensors', ['-j']);
      if (result.exitCode == 0) {
        // Lightweight scan for the first "temp1_input"-style value rather
        // than a full JSON parse, to avoid pulling in extra dependencies
        // just for this fallback path.
        final match = RegExp(r'"temp\d_input":\s*([\d.]+)').firstMatch(result.stdout as String);
        if (match != null) return double.tryParse(match.group(1) ?? '');
      }
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'lm-sensors not available: $e');
    }
    return null;
  }

  int? _prevRaplEnergyUj;
  DateTime? _prevRaplTime;

  /// Reads average CPU package power draw since the last call, via the
  /// kernel's RAPL powercap interface (Intel-specific; returns null —
  /// not a fabricated number — on AMD or if RAPL isn't exposed, e.g. in
  /// some VMs or older kernels).
  Future<double?> readCpuPowerWatts() async {
    try {
      final file = File('/sys/class/powercap/intel-rapl:0/energy_uj');
      if (!await file.exists()) return null;
      final raw = int.tryParse((await file.readAsString()).trim());
      if (raw == null) return null;

      final now = DateTime.now();
      double? watts;
      if (_prevRaplEnergyUj != null && _prevRaplTime != null) {
        final elapsedSec = now.difference(_prevRaplTime!).inMicroseconds / 1e6;
        if (elapsedSec > 0) {
          var deltaUj = raw - _prevRaplEnergyUj!;
          if (deltaUj < 0) deltaUj = 0; // counter wrapped around its max
          watts = (deltaUj / 1e6) / elapsedSec;
        }
      }
      _prevRaplEnergyUj = raw;
      _prevRaplTime = now;
      return watts;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'RAPL power read failed: $e');
      return null;
    }
  }

  /// Detailed CPU info for the Performance > CPU detail panel — reads
  /// `lscpu` once plus a couple of sysfs files (governor, scaling
  /// driver, base frequency). Meant to be called when that panel opens
  /// or on manual refresh, not every 1s poll.
  Future<CpuDetailInfo> readCpuDetails() async {
    try {
      // lscpu's field labels are locale-dependent — on a system set to
      // Dutch (or any non-English locale), "CPU(s):", "Socket(s):",
      // "Core(s) per socket:" and "Virtualization:" get translated,
      // and every regex below would silently fail to match, showing
      // "onbekend" for fields that are actually available. Forcing
      // LC_ALL=C for just this one process call keeps output in
      // English regardless of the user's system language, without
      // affecting the rest of the app (which stays in Dutch).
      final result = await Process.run('lscpu', [], environment: {'LC_ALL': 'C'});
      if (result.exitCode != 0) return CpuDetailInfo.unknown();
      final output = result.stdout as String;

      int? parseIntField(String label) {
        final match = RegExp('$label:\\s*(\\d+)').firstMatch(output);
        return match != null ? int.tryParse(match.group(1)!) : null;
      }

      final coresPerSocket = parseIntField('Core\\(s\\) per socket');
      final sockets = parseIntField('Socket\\(s\\)');
      final logicalProcessors = parseIntField('CPU\\(s\\)');
      final physicalCores =
          (coresPerSocket != null && sockets != null) ? coresPerSocket * sockets : null;

      final virtMatch = RegExp(r'Virtualization:\s*(\S+)').firstMatch(output);
      final virtualizationSupport = virtMatch?.group(1);

      // lscpu prints a "Hypervisor vendor:" line only when running
      // inside a VM — its mere presence is the signal, not its value.
      final isVirtualMachine = output.contains('Hypervisor vendor:');

      String? governor;
      String? frequencyDriver;
      double? baseSpeedMHz;
      try {
        governor = (await File('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor')
                .readAsString())
            .trim();
      } catch (_) {}
      try {
        frequencyDriver = (await File('/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver')
                .readAsString())
            .trim();
      } catch (_) {}
      try {
        // Only exposed by some drivers (e.g. intel_pstate) — left null
        // (shown as "onbekend" in the UI) rather than guessed when
        // it isn't available, same as everywhere else in this file.
        final baseFreqKHz = int.tryParse((await File(
                '/sys/devices/system/cpu/cpu0/cpufreq/base_frequency')
            .readAsString())
            .trim());
        if (baseFreqKHz != null) baseSpeedMHz = baseFreqKHz / 1000;
      } catch (_) {}

      return CpuDetailInfo(
        baseSpeedMHz: baseSpeedMHz,
        physicalCores: physicalCores,
        sockets: sockets,
        logicalProcessors: logicalProcessors,
        virtualizationSupport: virtualizationSupport,
        isVirtualMachine: isVirtualMachine,
        frequencyDriver: frequencyDriver,
        governor: governor,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read CPU details: $e');
      return CpuDetailInfo.unknown();
    }
  }

  /// Total thread count system-wide, via `ps -eo nlwp` (NLWP = number
  /// of light-weight processes/threads for each process), summed. A
  /// single cheap `ps` call rather than reading every process's
  /// /proc/<pid>/status individually.
  Future<int?> readThreadCount() async {
    try {
      final result = await Process.run('ps', ['-eo', 'nlwp', '--no-headers']);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).split('\n');
      var total = 0;
      for (final line in lines) {
        final n = int.tryParse(line.trim());
        if (n != null) total += n;
      }
      return total;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read thread count: $e');
      return null;
    }
  }
}
