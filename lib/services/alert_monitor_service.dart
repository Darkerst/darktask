import 'dart:async';

import '../core/logging/app_logger.dart';
import '../core/models/battery_sample.dart';
import '../core/models/disk_sample.dart';
import '../core/models/gpu_sample.dart';
import '../core/models/network_sample.dart';
import 'benchmark_service.dart';
import 'sensors/system_sensor_service.dart';
import 'settings_service.dart';
import 'tray_service.dart';

const _logSource = 'AlertMonitorService';

/// Background threshold watcher for the tray feature's alerts: CPU
/// package temperature, low disk space, high RAM usage, high GPU
/// temperature, high combined network throughput, high swap/pagefile
/// usage, low battery, and a single CPU core pegged at load. Deliberately
/// its own timer, independent of whatever the currently-visible
/// screen's own poll interval is set to (including "Uit"/paused) — see
/// `_HomeShellState._buildScreen` in app.dart, which mounts only the
/// active screen, so a screen-owned Timer stops the moment you
/// navigate away from it. This one is started once from `main()`,
/// against the same shared `SystemSensorService` instance every screen
/// already reads from, and keeps running for the app's whole
/// lifetime — including while the window is hidden to the tray, since
/// hiding the OS window (see TrayService) never touches the Dart
/// isolate or its timers.
///
/// Edge-triggered with hysteresis, not a plain "still over threshold →
/// notify again": each condition tracks whether it's currently
/// "active", and only fires a new notification on the transition from
/// not-active to active. It only re-arms once the reading drops back
/// below (threshold − [_hysteresisC]/[_hysteresisPercent]), not the
/// instant it dips under the threshold itself — without that gap, a
/// temperature or free-space reading hovering right at the line would
/// fire a fresh notification on every single poll.
class AlertMonitorService {
  AlertMonitorService._();
  static final AlertMonitorService instance = AlertMonitorService._();

  static const _pollInterval = Duration(seconds: 20);
  static const _hysteresisC = 5.0;
  static const _hysteresisPercent = 5.0;

  /// Relative (not absolute) re-arm gap for the network-throughput
  /// alert — see [networkAlertMBps]'s doc in AppSettings for why a
  /// fixed MB/s gap doesn't work across the whole allowed threshold
  /// range.
  static const _hysteresisFraction = 0.2;

  Timer? _timer;
  SystemSensorService? _sensors;

  bool _cpuTempActive = false;
  final Set<String> _activeDiskAlerts = {};
  bool _memoryAlertActive = false;
  final Set<String> _activeGpuTempAlerts = {};
  bool _networkAlertActive = false;
  bool _swapAlertActive = false;
  bool _batteryAlertActive = false;
  final Set<int> _activePerCoreCpuAlerts = {};

  /// Starts the background poll, if not already running. Takes the
  /// same [sensors] instance `main()` created and handed to
  /// `DarkTaskApp` — reusing it (rather than constructing a second
  /// `WindowsSensorService`/`LinuxSensorService`) avoids spinning up a
  /// second PowerShell/LibreHardwareMonitor session or a second
  /// `intel_gpu_top` process just for this.
  void start(SystemSensorService sensors) {
    if (_timer != null) return;
    _sensors = sensors;
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
    AppLogger.instance.info(
      _logSource,
      'Achtergrondcontrole gestart (elke ${_pollInterval.inSeconds}s) voor CPU-temperatuur-, '
      'schijfruimte-, geheugen-, GPU-temperatuur-, netwerk-, swap-, batterij- en '
      'per-kern-CPU-meldingen — vuurt alleen als die alerts in Settings zijn ingeschakeld.',
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    final sensors = _sensors;
    if (sensors == null) return;

    // Skip this poll entirely while a CPU/memory/crypto benchmark test
    // is running anywhere in the app. Those tests deliberately peg
    // every (or half) CPU core, and on Windows a maxed-out CPU can
    // starve the single shared PowerShell helper session of scheduling
    // time badly enough that any sensor read queued behind it — this
    // poll's included — piles up and comes back stale or null for a
    // long stretch. Since every command in that shared session's queue
    // waits for the ones ahead of it, this poll joining the queue
    // doesn't just make its own checks late, it makes every other
    // screen's sensor reads wait longer too, for as long as the
    // backlog takes to drain. Reported as the app "stagnating" often
    // during the CPU test specifically, on Windows — see
    // BenchmarkService.isCpuHeavyTestRunning's doc. A 20s alert cadence
    // isn't time-critical enough to insist on firing mid-benchmark, so
    // simply not adding to that queue avoids the pile-up instead of
    // trying to out-wait it.
    if (BenchmarkService.isCpuHeavyTestRunning) return;

    final settings = SettingsService.instance.current;

    // CPU package temperature and per-core load are both read off one
    // readCpu() call when either alert is enabled, rather than each
    // doing its own round-trip against the shared sensor service.
    if (settings.cpuTempAlertEnabled || settings.perCoreCpuAlertEnabled) {
      try {
        final cpu = await sensors.readCpu();
        if (settings.cpuTempAlertEnabled) _checkCpuTemp(cpu.temperatureC, settings.cpuTempAlertC);
        if (settings.perCoreCpuAlertEnabled) {
          _checkPerCoreCpu(cpu.perCoreLoadPercent, settings.perCoreCpuAlertPercent);
        }
      } catch (e) {
        AppLogger.instance.error(_logSource, 'CPU check failed: $e');
      }
    }
    if (!settings.cpuTempAlertEnabled) _cpuTempActive = false; // re-arm silently if turned off mid-run
    if (!settings.perCoreCpuAlertEnabled) _activePerCoreCpuAlerts.clear();

    if (settings.diskSpaceAlertEnabled) {
      try {
        final disks = await sensors.readDisks();
        _checkDiskSpace(disks, settings.diskSpaceAlertFreePercent);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Disk space check failed: $e');
      }
    } else {
      _activeDiskAlerts.clear();
    }

    // Same one-read-shared-by-two-checks pattern as CPU above — RAM
    // and swap/pagefile usage both come off one readMemory() call.
    if (settings.memoryAlertEnabled || settings.swapAlertEnabled) {
      try {
        final memory = await sensors.readMemory();
        if (settings.memoryAlertEnabled) _checkMemory(memory.usedPercent, settings.memoryAlertPercent);
        if (settings.swapAlertEnabled) _checkSwap(memory.swapUsedPercent, settings.swapAlertPercent);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Memory check failed: $e');
      }
    }
    if (!settings.memoryAlertEnabled) _memoryAlertActive = false;
    if (!settings.swapAlertEnabled) _swapAlertActive = false;

    if (settings.gpuTempAlertEnabled) {
      try {
        final gpus = await sensors.readGpus();
        _checkGpuTemp(gpus, settings.gpuTempAlertC);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'GPU temp check failed: $e');
      }
    } else {
      _activeGpuTempAlerts.clear();
    }

    if (settings.networkAlertEnabled) {
      try {
        final networks = await sensors.readNetwork();
        _checkNetwork(networks, settings.networkAlertMBps);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Network check failed: $e');
      }
    } else {
      _networkAlertActive = false;
    }

    if (settings.batteryAlertEnabled) {
      try {
        final battery = await sensors.readBattery();
        _checkBattery(battery, settings.batteryAlertPercent);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Battery check failed: $e');
      }
    } else {
      _batteryAlertActive = false;
    }
  }

  void _checkCpuTemp(double? temperatureC, double thresholdC) {
    if (temperatureC == null) return; // "Niet beschikbaar" on this machine — nothing to alert on
    if (!_cpuTempActive && temperatureC >= thresholdC) {
      _cpuTempActive = true;
      unawaited(TrayService.instance.showNotification(
        title: 'CPU-temperatuur hoog',
        body: 'De CPU is ${temperatureC.toStringAsFixed(0)}°C, boven de ingestelde grens van '
            '${thresholdC.toStringAsFixed(0)}°C.',
      ));
    } else if (_cpuTempActive && temperatureC <= thresholdC - _hysteresisC) {
      _cpuTempActive = false;
    }
  }

  void _checkDiskSpace(List<DiskSample> disks, double thresholdPercent) {
    final seenThisPoll = <String>{};
    for (final disk in disks) {
      final freePercent = 100 - disk.usedPercent;
      final key = disk.mountPoint;
      seenThisPoll.add(key);
      final active = _activeDiskAlerts.contains(key);
      if (!active && freePercent < thresholdPercent) {
        _activeDiskAlerts.add(key);
        unawaited(TrayService.instance.showNotification(
          title: 'Weinig schijfruimte',
          body: '$key heeft nog ${freePercent.toStringAsFixed(1)}% vrij '
              '(grens: ${thresholdPercent.toStringAsFixed(0)}%).',
        ));
      } else if (active && freePercent > thresholdPercent + _hysteresisPercent) {
        _activeDiskAlerts.remove(key);
      }
    }
    // A mount point that's disappeared since the last poll (drive
    // unplugged, unmounted) can't still be "active" — drop it so a
    // freshly reconnected disk with the same mount point starts clean
    // rather than silently inheriting stale alert state.
    _activeDiskAlerts.removeWhere((key) => !seenThisPoll.contains(key));
  }

  void _checkMemory(double usedPercent, double thresholdPercent) {
    if (!_memoryAlertActive && usedPercent >= thresholdPercent) {
      _memoryAlertActive = true;
      unawaited(TrayService.instance.showNotification(
        title: 'Geheugengebruik hoog',
        body: 'Het RAM-gebruik is ${usedPercent.toStringAsFixed(0)}%, boven de ingestelde grens van '
            '${thresholdPercent.toStringAsFixed(0)}%.',
      ));
    } else if (_memoryAlertActive && usedPercent <= thresholdPercent - _hysteresisPercent) {
      _memoryAlertActive = false;
    }
  }

  void _checkGpuTemp(List<GpuSample> gpus, double thresholdC) {
    final seenThisPoll = <String>{};
    for (final gpu in gpus) {
      final temperatureC = gpu.temperatureC;
      if (temperatureC == null) continue; // "Niet beschikbaar" for this GPU — nothing to alert on
      final key = gpu.id;
      seenThisPoll.add(key);
      final active = _activeGpuTempAlerts.contains(key);
      if (!active && temperatureC >= thresholdC) {
        _activeGpuTempAlerts.add(key);
        unawaited(TrayService.instance.showNotification(
          title: 'GPU-temperatuur hoog',
          body: '${gpu.name} is ${temperatureC.toStringAsFixed(0)}°C, boven de ingestelde grens van '
              '${thresholdC.toStringAsFixed(0)}°C.',
        ));
      } else if (active && temperatureC <= thresholdC - _hysteresisC) {
        _activeGpuTempAlerts.remove(key);
      }
    }
    // Same "disappeared since last poll" cleanup as _checkDiskSpace —
    // a GPU that's gone (or whose temperature reading dropped out)
    // can't still be "active".
    _activeGpuTempAlerts.removeWhere((key) => !seenThisPoll.contains(key));
  }

  void _checkSwap(double swapUsedPercent, double thresholdPercent) {
    if (!_swapAlertActive && swapUsedPercent >= thresholdPercent) {
      _swapAlertActive = true;
      unawaited(TrayService.instance.showNotification(
        title: 'Swap-gebruik hoog',
        body: 'Het swap-/pagefile-gebruik is ${swapUsedPercent.toStringAsFixed(0)}%, boven de ingestelde '
            'grens van ${thresholdPercent.toStringAsFixed(0)}%.',
      ));
    } else if (_swapAlertActive && swapUsedPercent <= thresholdPercent - _hysteresisPercent) {
      _swapAlertActive = false;
    }
  }

  void _checkNetwork(List<NetworkSample> networks, double thresholdMBps) {
    // Summed across every interface readNetwork() returns — a genuine
    // traffic spike shows up regardless of which adapter it's on
    // (Wi-Fi vs. a USB Ethernet dongle vs. a VPN's virtual adapter),
    // same reasoning as summing disk activity across physical drives
    // elsewhere in this app rather than watching just the first one.
    final totalBytesPerSec = networks.fold<double>(0, (sum, n) => sum + n.rxBytesPerSec + n.txBytesPerSec);
    final totalMBps = totalBytesPerSec / (1024 * 1024);
    if (!_networkAlertActive && totalMBps >= thresholdMBps) {
      _networkAlertActive = true;
      unawaited(TrayService.instance.showNotification(
        title: 'Netwerkpiek gedetecteerd',
        body: 'Het netwerkverkeer is ${totalMBps.toStringAsFixed(1)} MB/s, boven de ingestelde grens van '
            '${thresholdMBps.toStringAsFixed(1)} MB/s.',
      ));
    } else if (_networkAlertActive && totalMBps <= thresholdMBps * (1 - _hysteresisFraction)) {
      _networkAlertActive = false;
    }
  }

  void _checkBattery(BatterySample battery, double thresholdPercent) {
    final percent = battery.capacityPercent;
    if (!battery.present || percent == null) return; // desktop with no battery, or reading unavailable
    // Only alerts while actually discharging — a laptop plugged in and
    // charging back up through the same percentage it just alerted at
    // is the expected, temporary state right after being plugged in,
    // not something to notify about again. Re-arms silently the moment
    // charging starts, so unplugging later at a still-low percentage
    // notifies again rather than staying silently "already alerted".
    final isDischarging = battery.status?.toLowerCase() == 'discharging';
    if (!isDischarging) {
      _batteryAlertActive = false;
      return;
    }
    if (!_batteryAlertActive && percent <= thresholdPercent) {
      _batteryAlertActive = true;
      unawaited(TrayService.instance.showNotification(
        title: 'Batterij bijna leeg',
        body: 'De batterij staat op $percent%, onder de ingestelde grens van '
            '${thresholdPercent.toStringAsFixed(0)}%.',
      ));
    } else if (_batteryAlertActive && percent >= thresholdPercent + _hysteresisPercent) {
      _batteryAlertActive = false;
    }
  }

  void _checkPerCoreCpu(List<double> perCoreLoadPercent, double thresholdPercent) {
    final seenThisPoll = <int>{};
    for (var i = 0; i < perCoreLoadPercent.length; i++) {
      final load = perCoreLoadPercent[i];
      seenThisPoll.add(i);
      final active = _activePerCoreCpuAlerts.contains(i);
      if (!active && load >= thresholdPercent) {
        _activePerCoreCpuAlerts.add(i);
        unawaited(TrayService.instance.showNotification(
          title: 'CPU-kern zwaar belast',
          body: 'Kern ${i + 1} draait op ${load.toStringAsFixed(0)}%, boven de ingestelde grens van '
              '${thresholdPercent.toStringAsFixed(0)}%.',
        ));
      } else if (active && load <= thresholdPercent - _hysteresisPercent) {
        _activePerCoreCpuAlerts.remove(i);
      }
    }
    // Same "disappeared since last poll" cleanup as _checkDiskSpace —
    // if the reported core count ever shrinks (shouldn't happen
    // mid-session, but costs nothing to handle), a stale index can't
    // stay "active" forever.
    _activePerCoreCpuAlerts.removeWhere((i) => !seenThisPoll.contains(i));
  }
}
