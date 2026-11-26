import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/power_freq_sample.dart';
import 'sensors/windows/libre_hardware_monitor.dart';
import 'sensors/windows/powershell_session.dart';

const _logSource = 'PowerFreqService';

class PowerFreqService {
  // Lazily created, Windows-only — a separate PowerShell session/LHM
  // instance from WindowsSensorService's own, rather than threading a
  // shared reference across services. This screen is visited far less
  // often than Summary/Performance, so the modest duplicated cost (a
  // second powershell.exe, a second Add-Type of the same already-
  // downloaded DLL) only happens when someone actually opens it —
  // simpler to reason about than cross-service dependency injection
  // for a screen this infrequently used.
  // Static, not instance fields — deliberately. A new PowerFreqScreen
  // (and so a new PowerFreqService()) is created every time this
  // screen is navigated to, since that's how its State object's
  // lifecycle works; if these were instance fields, every single
  // revisit would pay LibreHardwareMonitor's full Add-Type + Open()
  // startup cost again, which is exactly what was observed happening
  // in testing (repeated "LibreHardwareMonitorLib geladen" log lines
  // spread across a session, one per visit). Static fields persist
  // for the whole app's lifetime regardless of how many
  // PowerFreqService objects get created and discarded, so the
  // underlying PowerShell session and LHM bridge are only ever set up
  // once per app run, the same guarantee WindowsSensorService's own
  // (app-lifetime-owned) bridge already has.
  static PowerShellSession? _windowsShell;
  static LibreHardwareMonitorBridge? _windowsLhm;

  Future<PowerFreqSample> read() =>
      Platform.isWindows ? _readWindows() : _readLinux();

  Future<PowerFreqSample> _readLinux() async {
    try {
      final coreDirs = await _listCpuCoreDirs();

      final perCoreFreq = <double?>[];
      for (final dir in coreDirs) {
        perCoreFreq.add(await _readFreqKHzAsMHz('$dir/cpufreq/scaling_cur_freq'));
      }

      double? minFreq;
      double? maxFreq;
      String? governor;
      List<String> availableGovernors = const [];
      String? frequencyDriver;

      if (coreDirs.isNotEmpty) {
        final cpu0 = coreDirs.first;
        minFreq = await _readFreqKHzAsMHz('$cpu0/cpufreq/scaling_min_freq');
        maxFreq = await _readFreqKHzAsMHz('$cpu0/cpufreq/scaling_max_freq');
        governor = await _readTrimmed('$cpu0/cpufreq/scaling_governor');
        frequencyDriver = await _readTrimmed('$cpu0/cpufreq/scaling_driver');
        final availableRaw = await _readTrimmed('$cpu0/cpufreq/scaling_available_governors');
        if (availableRaw != null) {
          availableGovernors = availableRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
        }
      }

      final turboEnabled = await _readTurboStatus();
      final battery = await _readBatteryInfo();

      return PowerFreqSample(
        perCoreFrequencyMHz: perCoreFreq,
        minFreqMHz: minFreq,
        maxFreqMHz: maxFreq,
        governor: governor,
        availableGovernors: availableGovernors,
        turboEnabled: turboEnabled,
        frequencyDriver: frequencyDriver,
        hasBattery: battery.hasBattery,
        batteryPercent: battery.percent,
        batteryStatus: battery.status,
        acOnline: battery.acOnline,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read power/freq info: $e\n$st');
      return const PowerFreqSample();
    }
  }

  /// Windows has no cpufreq subsystem, so several of this screen's
  /// concepts have no exact equivalent here — handled honestly rather
  /// than guessed at:
  ///
  /// - **Per-core frequency**: available, via LibreHardwareMonitor's
  ///   per-core Clock sensors (the same data already visible in this
  ///   app's CPU sensor dumps, just not previously extracted
  ///   per-core).
  /// - **Max frequency**: `Win32_Processor.MaxClockSpeed` — the CPU's
  ///   rated maximum, a reasonable stand-in for Linux's
  ///   `scaling_max_freq`, though it isn't the same *kind* of value
  ///   (a fixed hardware spec vs. an OS-adjustable scaling boundary).
  /// - **Governor**: Windows' closest conceptual equivalent is the
  ///   active **Power Plan** (Balanced/High performance/Power saver),
  ///   which also influences CPU frequency-scaling behavior — but a
  ///   Power Plan controls much more than a governor does (sleep
  ///   timers, display timeout, etc.), so this is labeled as a
  ///   distinct concept in the UI, not presented as if it were a
  ///   genuine governor.
  /// - **Frequency driver, min frequency, turbo status, available
  ///   governors**: genuinely have no stock-Windows equivalent this
  ///   app can read without additional vendor-specific tools — left
  ///   null/empty rather than fabricated.
  // Power plan and battery status virtually never change second to
  // second — caching them briefly means most polls skip two of the
  // four PowerShell/process round-trips _readWindows() would
  // otherwise do every single tick, directly reducing how much load
  // each poll puts on the shared PowerShellSession queue.
  String? _cachedPowerPlanName;
  ({bool hasBattery, double? percent, String? status, bool? acOnline})? _cachedBatteryInfo;
  DateTime? _slowFieldsCacheTime;
  static const _slowFieldsCacheTtl = Duration(seconds: 5);

  Future<PowerFreqSample> _readWindows() async {
    try {
      _windowsShell ??= PowerShellSession();
      _windowsLhm ??= LibreHardwareMonitorBridge(_windowsShell!);

      final perCoreFreq = await _windowsLhm!.readPerCoreClocksMHz();

      final maxFreqResult = await _windowsShell!.run(
        '(Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed | ConvertTo-Json -Compress',
      );
      final maxFreq = maxFreqResult != null ? double.tryParse(maxFreqResult.trim()) : null;

      final cacheAge =
          _slowFieldsCacheTime != null ? DateTime.now().difference(_slowFieldsCacheTime!) : null;
      final cacheIsFresh = cacheAge != null && cacheAge < _slowFieldsCacheTtl;

      String? powerPlanName;
      ({bool hasBattery, double? percent, String? status, bool? acOnline}) battery;

      if (cacheIsFresh) {
        powerPlanName = _cachedPowerPlanName;
        battery = _cachedBatteryInfo!;
      } else {
        // "(Balanced)" / "(Hoge prestaties)" etc. — the display name is
        // the part in parentheses; the GUID before it isn't useful to
        // show here.
        try {
          final schemeResult = await Process.run('powercfg', ['/getactivescheme']);
          if (schemeResult.exitCode == 0) {
            final match = RegExp(r'\(([^)]+)\)').firstMatch(schemeResult.stdout as String);
            powerPlanName = match?.group(1);
          }
        } catch (e) {
          AppLogger.instance.debug(_logSource, 'powercfg /getactivescheme failed: $e');
        }

        battery = await _readBatteryInfoWindows();

        _cachedPowerPlanName = powerPlanName;
        _cachedBatteryInfo = battery;
        _slowFieldsCacheTime = DateTime.now();
      }

      return PowerFreqSample(
        perCoreFrequencyMHz: perCoreFreq,
        maxFreqMHz: maxFreq,
        // Prefixed so the UI's existing "Governor" label reads
        // honestly rather than implying a real governor exists here —
        // see this method's doc comment for the full reasoning.
        governor: powerPlanName != null ? 'Energieschema: $powerPlanName' : null,
        hasBattery: battery.hasBattery,
        batteryPercent: battery.percent,
        batteryStatus: battery.status,
        acOnline: battery.acOnline,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read power/freq info (Windows): $e\n$st');
      return const PowerFreqSample();
    }
  }

  /// Windows equivalent of _readBatteryInfo — GetSystemPowerStatus via
  /// the same NativeBatteryReader logic would be preferable for
  /// consistency, but that class lives under sensors/windows and is
  /// tightly scoped to WindowsSensorService's own field; a plain
  /// Win32_Battery query here keeps this service self-contained
  /// without threading another cross-service dependency through it.
  Future<({bool hasBattery, double? percent, String? status, bool? acOnline})> _readBatteryInfoWindows() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-CimInstance Win32_Battery | Select-Object EstimatedChargeRemaining, BatteryStatus | ConvertTo-Json -Compress',
      ]);
      if (result.exitCode != 0) return (hasBattery: false, percent: null, status: null, acOnline: null);
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return (hasBattery: false, percent: null, status: null, acOnline: null);

      final decoded = jsonDecode(output);
      final row = decoded is List ? (decoded.isEmpty ? null : decoded.first) : decoded;
      if (row == null) return (hasBattery: false, percent: null, status: null, acOnline: null);

      final map = row as Map<String, dynamic>;
      final statusCode = (map['BatteryStatus'] as num?)?.toInt();
      final percent = (map['EstimatedChargeRemaining'] as num?)?.toDouble();

      // Same Win32_Battery.BatteryStatus code mapping as
      // WindowsSensorService.readBattery: 1=Discharging, 2=AC/On-line,
      // 3=Fully Charged, 6-9=various charging states.
      String? status;
      switch (statusCode) {
        case 1:
          status = 'Discharging';
        case 2:
          status = 'AC';
        case 3:
          status = 'Full';
        case 6:
        case 7:
        case 8:
        case 9:
          status = 'Charging';
      }

      return (hasBattery: statusCode != null, percent: percent, status: status, acOnline: status == 'AC');
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read battery info (Windows): $e');
      return (hasBattery: false, percent: null, status: null, acOnline: null);
    }
  }

  Future<List<String>> _listCpuCoreDirs() async {
    try {
      final sysCpuDir = Directory('/sys/devices/system/cpu');
      if (!await sysCpuDir.exists()) return [];
      final entries = await sysCpuDir.list().toList();
      final coreDirs = entries
          .whereType<Directory>()
          .map((d) => d.path)
          .where((p) => RegExp(r'/cpu\d+$').hasMatch(p))
          .toList();
      // Numeric sort (cpu2 before cpu10), not lexical.
      coreDirs.sort((a, b) {
        final na = int.parse(RegExp(r'\d+$').firstMatch(a)!.group(0)!);
        final nb = int.parse(RegExp(r'\d+$').firstMatch(b)!.group(0)!);
        return na.compareTo(nb);
      });
      return coreDirs;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to list CPU core dirs: $e');
      return [];
    }
  }

  Future<double?> _readFreqKHzAsMHz(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final khz = int.tryParse((await file.readAsString()).trim());
      return khz != null ? khz / 1000 : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readTrimmed(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final content = (await file.readAsString()).trim();
      return content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  /// Turbo/boost status. Two different sysfs conventions depending on
  /// the driver: intel_pstate uses an inverted "no_turbo" flag, while
  /// the generic cpufreq subsystem (amd_pstate, acpi-cpufreq, etc.)
  /// uses a direct "boost" flag. Tries both; returns null if neither
  /// is present (e.g. a CPU/driver with no boost concept).
  Future<bool?> _readTurboStatus() async {
    final noTurbo = await _readTrimmed('/sys/devices/system/cpu/intel_pstate/no_turbo');
    if (noTurbo != null) return noTurbo == '0'; // no_turbo=0 means turbo IS enabled

    final boost = await _readTrimmed('/sys/devices/system/cpu/cpufreq/boost');
    if (boost != null) return boost == '1';

    return null;
  }

  Future<({bool hasBattery, double? percent, String? status, bool? acOnline})> _readBatteryInfo() async {
    try {
      final powerSupplyDir = Directory('/sys/class/power_supply');
      if (!await powerSupplyDir.exists()) {
        return (hasBattery: false, percent: null, status: null, acOnline: null);
      }
      final entries = await powerSupplyDir.list().toList();

      double? percent;
      String? status;
      bool? acOnline;
      var hasBattery = false;

      for (final entry in entries) {
        final name = entry.path.split('/').last;
        final typeContent = await _readTrimmed('${entry.path}/type');

        if (typeContent == 'Battery') {
          hasBattery = true;
          final capacity = await _readTrimmed('${entry.path}/capacity');
          if (capacity != null) percent = double.tryParse(capacity);
          status = await _readTrimmed('${entry.path}/status');
        } else if (typeContent == 'Mains' || name.startsWith('A')) {
          final online = await _readTrimmed('${entry.path}/online');
          if (online != null) acOnline = online == '1';
        }
      }

      return (hasBattery: hasBattery, percent: percent, status: status, acOnline: acOnline);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read battery info: $e');
      return (hasBattery: false, percent: null, status: null, acOnline: null);
    }
  }

  /// Sets the scaling governor on every core via pkexec — writes the
  /// same governor to each core's scaling_governor file with a small
  /// shell loop, since pkexec runs a single command and can't itself
  /// glob/loop over multiple sysfs files.
  Future<bool> setGovernor(String governor) async {
    AppLogger.instance.info(_logSource, 'Setting governor to "$governor" via pkexec');
    try {
      // Dart interpolates $governor below with the parameter value;
      // \$f stays literal (escaped), becoming the shell loop variable.
      final script =
          'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo $governor > "\$f"; done';
      final result = await Process.run('pkexec', ['sh', '-c', script]);
      final success = result.exitCode == 0;
      AppLogger.instance.info(
        _logSource,
        success ? 'Governor set to $governor' : 'Failed to set governor (exit ${result.exitCode}): ${result.stderr}',
      );
      return success;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'pkexec call failed while setting governor: $e');
      return false;
    }
  }

  /// Toggles turbo/boost via pkexec, writing to whichever sysfs path
  /// the driver actually exposes (see _readTurboStatus).
  Future<bool> setTurboEnabled(bool enabled) async {
    AppLogger.instance.info(_logSource, '${enabled ? 'Enabling' : 'Disabling'} turbo via pkexec');
    try {
      final hasIntelPstate = await File('/sys/devices/system/cpu/intel_pstate/no_turbo').exists();
      final path = hasIntelPstate
          ? '/sys/devices/system/cpu/intel_pstate/no_turbo'
          : '/sys/devices/system/cpu/cpufreq/boost';
      // intel_pstate's no_turbo is inverted relative to "enabled".
      final valueToWrite = hasIntelPstate ? (enabled ? '0' : '1') : (enabled ? '1' : '0');

      final result = await Process.run('pkexec', ['sh', '-c', 'echo $valueToWrite > $path']);
      final success = result.exitCode == 0;
      AppLogger.instance.info(
        _logSource,
        success ? 'Turbo ${enabled ? 'enabled' : 'disabled'}' : 'Failed to set turbo (exit ${result.exitCode})',
      );
      return success;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'pkexec call failed while setting turbo: $e');
      return false;
    }
  }
}
