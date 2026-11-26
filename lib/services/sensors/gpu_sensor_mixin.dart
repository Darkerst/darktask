import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/gpu_diagnostic.dart';
import '../../core/models/gpu_sample.dart';
import 'cpu_sensor_mixin.dart';

const _logSource = 'LinuxSensorService';

/// GPU-related reads: stats for every GPU present, regardless of
/// vendor — NVIDIA via `nvidia-smi` (richest data), and AMD/Intel via a
/// generic `/sys/class/drm` scan that needs no extra tools installed.
/// Also owns the two Intel-GPU-load fallback mechanisms (kernel fdinfo
/// counters, then a persistent `intel_gpu_top` process) and the
/// in-app permission-fix / tool-install actions those can offer.
///
/// Split out of the former single `LinuxSensorService` god-file — see
/// `linux_sensor_service.dart` for how the domain mixins are composed.
///
/// Depends on [CpuSensorMixin] for its GPU-temperature-unavailable
/// fallback: most integrated Intel GPUs share a die with the CPU and
/// have no separate thermal sensor exposed by the kernel, so this falls
/// back to the CPU package temperature (clearly flagged as such via
/// [GpuSample.temperatureIsSharedWithCpu], never silently substituted).
/// The composing class must mix in [CpuSensorMixin] before this one.
mixin GpuSensorMixin on CpuSensorMixin {
  // Dedup flags so expected, unchanging conditions (no NVIDIA GPU present,
  // sysfs scan result) are logged once instead of flooding the log every
  // poll — a poll runs every second, so without this the log becomes
  // unusable within minutes.
  bool _nvidiaAbsenceLogged = false;
  bool _sysfsSummaryLogged = false;
  Set<String> _lastKnownSysfsGpuIds = {};
  bool _intelGpuTopStatusLogged = false;

  // Keyed by GPU id (e.g. "card1"). The UI reads this to decide whether
  // to offer an in-app "fix permissions" / "install tool" button.
  final Map<String, GpuDiagnostic> _gpuDiagnostics = {};
  Map<String, GpuDiagnostic> get gpuDiagnostics => Map.unmodifiable(_gpuDiagnostics);
  final Map<String, DateTime> _lastIntelToolAttempt = {};
  static const _intelToolRetryInterval = Duration(seconds: 10);

  // Persistent intel_gpu_top process state: started once and kept
  // running for as long as the app does, rather than spawned and killed
  // every poll (see _readIntelGpuBusyViaTool for why).
  Process? _intelGpuTopProcess;
  bool _intelGpuTopStarting = false;
  String? _intelGpuTopGpuId;
  final StringBuffer _intelGpuTopBuffer = StringBuffer();
  double? _cachedIntelGpuBusy;

  // fdinfo-based reader state (kernel per-process GPU engine counters —
  // see _readIntelGpuBusyViaFdinfo). Keyed by gpuId since a system could
  // have more than one Intel GPU.
  final Map<String, String?> _pciAddressCache = {};
  final Map<String, Map<String, int>> _prevFdinfoBusyNs = {};
  final Map<String, DateTime> _prevFdinfoSampleTime = {};
  int _fdinfoNoMatchStreak = 0;

  /// Reads stats for every GPU present on the system, regardless of
  /// vendor: NVIDIA via `nvidia-smi` (richest data — separate VRAM,
  /// power draw), and AMD/Intel (integrated or discrete) via a generic
  /// `/sys/class/drm` scan that needs no extra tools installed. Returns
  /// an empty list, never a single "unavailable" placeholder, so the UI
  /// can decide how to represent "no GPU found" itself.
  Future<List<GpuSample>> readGpus() async {
    final results = <GpuSample>[];

    results.addAll(await _readNvidiaGpus());
    results.addAll(await _readSysfsGpus());

    return results;
  }

  /// Per-process GPU load, keyed by PID — a byproduct of the same
  /// kernel fdinfo scan [readGpus] already does for Intel iGPU load
  /// (see [_readIntelGpuBusyViaFdinfo]'s class doc), not a separate
  /// scan of its own. Calling [readGpus] first ensures that scan has
  /// actually run recently (it's internally rate-limited to once per
  /// [_fdinfoScanInterval], same as the aggregate reading), then this
  /// just reads back what it already computed.
  ///
  /// Only ever populated for GPUs the fdinfo mechanism covers — on
  /// this app's tested hardware, integrated Intel GPUs specifically.
  /// NVIDIA (via nvidia-smi) and AMD have no per-process breakdown
  /// wired up here; returns an empty map on any machine without a
  /// covered GPU, never throws.
  Future<Map<int, double>> readPerProcessGpuLoad() async {
    await readGpus();
    final merged = <int, double>{};
    for (final perGpuMap in _lastFdinfoPerPidPercent.values) {
      for (final entry in perGpuMap.entries) {
        merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
      }
    }
    return merged;
  }

  Future<List<GpuSample>> _readNvidiaGpus() async {
    try {
      final result = await Process.run('nvidia-smi', [
        '--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.current.graphics',
        '--format=csv,noheader,nounits',
      ]);

      if (result.exitCode != 0) {
        _logNvidiaAbsenceOnce('nvidia-smi exited with code ${result.exitCode}');
        return [];
      }

      final lines = (result.stdout as String).trim().split('\n').where((l) => l.trim().isNotEmpty);
      final samples = <GpuSample>[];

      for (final line in lines) {
        final parts = line.split(',').map((p) => p.trim()).toList();
        if (parts.length < 7) continue;

        samples.add(GpuSample(
          id: 'nvidia${parts[0]}',
          timestamp: DateTime.now(),
          name: parts[1],
          vendor: GpuVendor.nvidia,
          loadPercent: double.tryParse(parts[2]),
          memoryUsedMiB: double.tryParse(parts[3]),
          memoryTotalMiB: double.tryParse(parts[4]),
          temperatureC: double.tryParse(parts[5]),
          powerDrawWatts: double.tryParse(parts[6]),
          // Already in MHz from nvidia-smi — only present on drivers
          // new enough to support this query field, hence the length
          // guard so older drivers (7 fields) keep working unchanged.
          clockMHz: parts.length > 7 ? double.tryParse(parts[7]) : null,
        ));
      }
      return samples;
    } catch (e) {
      // nvidia-smi not installed at all — expected on machines with no
      // NVIDIA GPU, like an Intel-only OptiPlex 3080.
      _logNvidiaAbsenceOnce('nvidia-smi not installed: $e');
      return [];
    }
  }

  void _logNvidiaAbsenceOnce(String reason) {
    if (_nvidiaAbsenceLogged) return;
    _nvidiaAbsenceLogged = true;
    AppLogger.instance.info(
      _logSource,
      'No NVIDIA GPU detected ($reason). This message will not repeat every poll.',
    );
  }

  /// Scans /sys/class/drm/card* for AMD and Intel GPUs. NVIDIA cards are
  /// skipped here since nvidia-smi already covers them with richer data
  /// (proprietary driver sysfs nodes are inconsistent across versions).
  Future<List<GpuSample>> _readSysfsGpus() async {
    final samples = <GpuSample>[];
    try {
      final drmDir = Directory('/sys/class/drm');
      if (!await drmDir.exists()) return samples;

      final allEntries = await drmDir.list().toList();
      final cardDirs = allEntries.where((e) {
        final baseName = e.path.split('/').last;
        return RegExp(r'^card\d+$').hasMatch(baseName);
      });

      for (final entry in cardDirs) {
        final devicePath = '${entry.path}/device';
        final vendorFile = File('$devicePath/vendor');
        if (!await vendorFile.exists()) continue;

        final vendorId = (await vendorFile.readAsString()).trim().toLowerCase();
        GpuVendor vendor;
        if (vendorId == '0x1002') {
          vendor = GpuVendor.amd;
        } else if (vendorId == '0x8086') {
          vendor = GpuVendor.intel;
        } else if (vendorId == '0x10de') {
          continue; // NVIDIA — already handled via nvidia-smi above.
        } else {
          continue; // Unknown vendor ID, skip rather than guess.
        }

        final cardName = entry.path.split('/').last;
        final driverName = await _readDriverName(devicePath);
        final label = vendor == GpuVendor.amd
            ? 'AMD GPU${driverName != null ? ' ($driverName)' : ''}'
            : 'Intel GPU${driverName != null ? ' ($driverName)' : ''}';

        var loadPercent = await _readIntFile('$devicePath/gpu_busy_percent');
        double? loadPercentFromTool;
        if (loadPercent == null && vendor == GpuVendor.intel) {
          // Preferred path: the kernel's own per-process fdinfo GPU-engine
          // counters (drm-engine-render, etc. under /proc/<pid>/fdinfo/).
          // This needs i915 fdinfo support (kernel 5.19+) but, unlike
          // intel_gpu_top, requires no special capability or perf-event
          // permission at all for busy% — it's the same mechanism nvtop
          // and Frigate's current GPU-stats collector use. Try this
          // before falling back to the external tool.
          loadPercentFromTool = await _readIntelGpuBusyViaFdinfo(devicePath, cardName);

          if (loadPercentFromTool == null) {
            // Falls back to the persistent intel_gpu_top process for
            // older kernels without fdinfo support. This is best-effort:
            // the tool needs the intel-gpu-tools package and sometimes
            // elevated perf-event permissions, so failure here is
            // expected on plenty of systems and just means "no load
            // reading", not an error.
            loadPercentFromTool = await _readIntelGpuBusyViaTool(cardName);
          }
        }
        var tempC = await _readHwmonTemp(devicePath);
        var tempSharedWithCpu = false;
        if (tempC == null && vendor == GpuVendor.intel) {
          // Most integrated Intel GPUs share a die with the CPU and
          // have no thermal sensor of their own exposed via hwmon — the
          // package temperature the kernel does expose (via coretemp)
          // covers the whole die, GPU included. Using it here is
          // honest, not a guess: it's a real, relevant reading, just
          // not GPU-exclusive — hence the explicit flag rather than
          // presenting it as an independently-measured GPU value.
          tempC = await readCpuTemperatureOnly();
          tempSharedWithCpu = tempC != null;
        }
        final powerW = await _readHwmonPower(devicePath);
        final clockMHz = await _readGpuClockMHz(devicePath, vendor);

        // VRAM is only meaningful for discrete AMD cards — integrated
        // GPUs (both AMD APUs and Intel) share system RAM and generally
        // don't expose these nodes.
        final vramUsed = await _readIntFile('$devicePath/mem_info_vram_used');
        final vramTotal = await _readIntFile('$devicePath/mem_info_vram_total');

        samples.add(GpuSample(
          id: cardName,
          timestamp: DateTime.now(),
          name: label,
          vendor: vendor,
          loadPercent: loadPercent?.toDouble() ?? loadPercentFromTool,
          memoryUsedMiB: vramUsed != null ? vramUsed / 1048576 : null,
          memoryTotalMiB: vramTotal != null ? vramTotal / 1048576 : null,
          temperatureC: tempC,
          temperatureIsSharedWithCpu: tempSharedWithCpu,
          powerDrawWatts: powerW,
          clockMHz: clockMHz,
        ));
      }

      _logSysfsSummaryOnChange(samples);
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to scan /sys/class/drm: $e\n$st');
    }
    return samples;
  }

  /// Logs what the sysfs scan found, but only the first time and again
  /// whenever the set of detected GPUs actually changes (e.g. a card
  /// dis/reappears) — not on every one-second poll.
  void _logSysfsSummaryOnChange(List<GpuSample> samples) {
    final currentIds = samples.map((s) => s.id).toSet();
    if (_sysfsSummaryLogged && currentIds.length == _lastKnownSysfsGpuIds.length &&
        currentIds.containsAll(_lastKnownSysfsGpuIds)) {
      return;
    }
    _sysfsSummaryLogged = true;
    _lastKnownSysfsGpuIds = currentIds;

    if (samples.isEmpty) {
      AppLogger.instance.info(
        _logSource,
        'sysfs GPU scan found no AMD/Intel devices under /sys/class/drm.',
      );
      return;
    }

    for (final s in samples) {
      final loadStatus = s.loadPercent != null
          ? '${s.loadPercent!.toStringAsFixed(0)}%'
          : 'unavailable (no gpu_busy_percent on this kernel/driver)';
      final tempStatus = s.temperatureC == null
          ? 'n/a'
          : '${s.temperatureC!.toStringAsFixed(0)}°C${s.temperatureIsSharedWithCpu ? ' (shared with CPU package — no separate GPU sensor)' : ''}';
      AppLogger.instance.info(
        _logSource,
        'sysfs GPU detected: ${s.name} (id=${s.id}, load=$loadStatus, temp=$tempStatus)',
      );
    }
  }

  Future<String?> _readDriverName(String devicePath) async {
    try {
      final ueventFile = File('$devicePath/uevent');
      if (!await ueventFile.exists()) return null;
      final content = await ueventFile.readAsString();
      final match = RegExp(r'DRIVER=(\w+)').firstMatch(content);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _readIntFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return int.tryParse((await file.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  /// Looks for a temperature reading under the GPU device's own hwmon
  /// node (device/hwmon/hwmon*/temp1_input), in millidegrees Celsius.
  Future<double?> _readHwmonTemp(String devicePath) async {
    final raw = await _findHwmonValue(devicePath, 'temp1_input');
    return raw != null ? raw / 1000.0 : null;
  }

  /// Looks for a power draw reading (power1_average preferred, falls
  /// back to power1_input), in microwatts.
  Future<double?> _readHwmonPower(String devicePath) async {
    var raw = await _findHwmonValue(devicePath, 'power1_average');
    raw ??= await _findHwmonValue(devicePath, 'power1_input');
    return raw != null ? raw / 1000000.0 : null;
  }

  /// Current GPU clock — read differently per vendor since neither
  /// exposes it through hwmon the way temperature/power are:
  ///
  /// - Intel: `gt_cur_freq_mhz` is a plain single integer, already in
  ///   MHz — the simplest of the two.
  /// - AMD: `pp_dpm_sclk` lists every clock the card *can* run at, one
  ///   per line (e.g. "0: 300MHz", "1: 1500MHz *"), with the currently
  ///   active one marked by a trailing "*" — this reads that marked
  ///   line specifically, not just the first or last, since GPUs
  ///   dynamically clock between these states under load.
  Future<double?> _readGpuClockMHz(String devicePath, GpuVendor vendor) async {
    try {
      if (vendor == GpuVendor.intel) {
        final file = File('$devicePath/gt_cur_freq_mhz');
        if (!await file.exists()) return null;
        final content = (await file.readAsString()).trim();
        return double.tryParse(content);
      }
      if (vendor == GpuVendor.amd) {
        final file = File('$devicePath/pp_dpm_sclk');
        if (!await file.exists()) return null;
        final lines = (await file.readAsLines());
        for (final line in lines) {
          if (!line.trim().endsWith('*')) continue;
          final match = RegExp(r'(\d+)\s*MHz').firstMatch(line);
          if (match != null) return double.tryParse(match.group(1)!);
        }
        return null;
      }
      return null;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read GPU clock for $devicePath: $e');
      return null;
    }
  }

  Future<int?> _findHwmonValue(String devicePath, String fileName) async {
    try {
      final hwmonDir = Directory('$devicePath/hwmon');
      if (!await hwmonDir.exists()) return null;
      await for (final entry in hwmonDir.list()) {
        final file = File('${entry.path}/$fileName');
        if (await file.exists()) {
          return int.tryParse((await file.readAsString()).trim());
        }
      }
    } catch (_) {
      // fall through
    }
    return null;
  }

  /// Reads Intel GPU load via the kernel's own per-process fdinfo GPU
  /// engine counters — no external tool, no CAP_PERFMON, no perf-event
  /// permission needed for busy% (only total-VRAM queries need that,
  /// which we don't use here). This is the same technique nvtop and
  /// Frigate's current GPU-stats collector use.
  ///
  /// Mechanism: every process with an open DRM file descriptor has a
  /// /proc/<pid>/fdinfo/<fd> file containing cumulative nanosecond
  /// counters per GPU engine (drm-engine-render, etc.), tagged with
  /// which PCI device they belong to (drm-pdev). We scan all processes'
  /// fdinfo entries, sum the render-engine counter across every fd that
  /// belongs to our target GPU, and diff that sum against the previous
  /// poll's sum to get busy time over the elapsed wall-clock interval —
  /// the same diffing approach as the CPU load reader.
  /// Requires i915 fdinfo support (kernel 5.19+); returns null on older
  /// kernels or if nothing could be read, so the caller can fall back.
  final Map<String, double> _lastFdinfoBusyResult = {};
  final Map<String, Map<int, double>> _lastFdinfoPerPidPercent = {};
  final Map<String, DateTime> _lastFdinfoScanTime = {};
  static const _fdinfoScanInterval = Duration(seconds: 2);

  Future<double?> _readIntelGpuBusyViaFdinfo(String devicePath, String gpuId) async {
    // Scanning every process's fdinfo (hundreds of processes, thousands
    // of files on a typical desktop) is comparatively expensive — doing
    // it on every single 1s poll adds up and can make each poll take
    // longer than the interval itself. Reuse the last computed value in
    // between scans instead of redoing the full walk every second; the
    // GPU-load number doesn't need sub-2-second resolution to be useful
    // on a dashboard anyway.
    final lastScan = _lastFdinfoScanTime[gpuId];
    if (lastScan != null && DateTime.now().difference(lastScan) < _fdinfoScanInterval) {
      return _lastFdinfoBusyResult[gpuId];
    }

    try {
      final pciAddress = _pciAddressCache.putIfAbsent(
        gpuId,
        () => null, // filled in below on first real lookup
      );
      final resolvedPci = pciAddress ?? await _resolvePciAddress(devicePath);
      if (resolvedPci == null) {
        _logFdinfoStatusOnce(
          'kon PCI-adres van $gpuId niet bepalen uit $devicePath/uevent — fdinfo-methode overgeslagen.',
        );
        return null;
      }
      _pciAddressCache[gpuId] = resolvedPci;
      _lastFdinfoScanTime[gpuId] = DateTime.now();

      final now = DateTime.now();
      final currentBusy = <String, int>{};
      var sawAnyFdinfo = false;
      final observedPciAddresses = <String>{};

      final procDir = Directory('/proc');
      List<FileSystemEntity> pidDirs;
      try {
        pidDirs = await procDir.list().toList();
      } catch (e) {
        AppLogger.instance.debug(_logSource, 'Cannot list /proc: $e');
        return null;
      }

      final pidPaths = pidDirs
          .map((e) => e.path)
          .where((path) => int.tryParse(path.split('/').last) != null)
          .toList();
      final scannedPids = pidPaths.length;

      // Phase 1: list every process's fdinfo directory concurrently
      // (bounded, so we don't open hundreds of directory handles at
      // once) instead of one process at a time — this was the biggest
      // single cost, since it's ~350 independent, awaitable I/O calls
      // that don't need to wait on each other.
      final fdinfoListings = await _mapConcurrent<String, List<String>>(
        pidPaths,
        (pidPath) async {
          try {
            final entries = await Directory('$pidPath/fdinfo').list().toList();
            return entries.map((e) => e.path).toList();
          } catch (_) {
            // Process gone, or (more commonly) we don't have permission
            // to read another user's fdinfo — expected and fine. We
            // still get every process running as our own user, which
            // covers the desktop compositor, browsers, ffmpeg, etc.
            return const <String>[];
          }
        },
        concurrency: 32,
      );

      // Flatten to a single (pid, fdPath) list for phase 2.
      final fdEntries = <MapEntry<String, String>>[];
      for (var i = 0; i < pidPaths.length; i++) {
        final pidStr = pidPaths[i].split('/').last;
        for (final fdPath in fdinfoListings[i] ?? const <String>[]) {
          fdEntries.add(MapEntry(pidStr, fdPath));
        }
      }

      // Phase 2: read every fdinfo file's contents concurrently. This is
      // the bulk of the work (thousands of small file reads), so this
      // is where parallelizing matters most.
      final fdContents = await _mapConcurrent<MapEntry<String, String>, String>(
        fdEntries,
        (entry) async {
          try {
            return await File(entry.value).readAsString();
          } catch (_) {
            return ''; // fd closed between listing and reading — race, ignore
          }
        },
        concurrency: 64,
      );

      var readableFdinfoFiles = 0;
      var drmFdinfoFiles = 0;

      for (var i = 0; i < fdEntries.length; i++) {
        final content = fdContents[i];
        if (content == null || content.isEmpty) continue;
        readableFdinfoFiles++;

        // Extract the PCI address with a whitespace-tolerant regex
        // rather than an exact "drm-pdev: <value>" substring — the
        // kernel formats this field with variable spacing/tabs for
        // column alignment, so a literal single-space match can
        // silently miss every real entry.
        final pdevMatch = RegExp(r'drm-pdev:\s*(\S+)').firstMatch(content);
        if (pdevMatch == null) continue; // not a DRM fd at all
        drmFdinfoFiles++;
        final observedPci = pdevMatch.group(1)!;
        observedPciAddresses.add(observedPci);
        if (observedPci != resolvedPci) continue; // a different GPU

        sawAnyFdinfo = true;
        final match = RegExp(r'drm-engine-render:\s*(\d+)\s*ns').firstMatch(content);
        if (match == null) continue;
        final busyNs = int.tryParse(match.group(1) ?? '');
        if (busyNs == null) continue;

        final pidStr = fdEntries[i].key;
        final fdName = fdEntries[i].value.split('/').last;
        currentBusy['$pidStr:$fdName'] = busyNs;
      }

      if (!sawAnyFdinfo) {
        // Either the kernel doesn't expose drm-pdev/engine counters at
        // all (pre-5.19 i915), or we simply couldn't read any process
        // that currently has the GPU open (permission, or nothing using
        // it at this instant). Log exactly what we did find so this is
        // diagnosable instead of a silent, permanent null — and count
        // attempts so a single unlucky poll doesn't disable fdinfo
        // forever, but repeated failure does.
        _fdinfoNoMatchStreak++;
        if (_fdinfoNoMatchStreak >= 3) {
          _logFdinfoStatusOnce(
            'geen enkele drm-pdev-match voor $gpuId (verwacht PCI $resolvedPci) na '
            '$_fdinfoNoMatchStreak pogingen — $scannedPids processen gescand, '
            '$readableFdinfoFiles leesbare fdinfo-bestanden, waarvan $drmFdinfoFiles '
            'DRM-fd\'s. Daadwerkelijk gevonden PCI-adressen: '
            '${observedPciAddresses.isEmpty ? '(geen)' : observedPciAddresses.join(', ')}. '
            'Valt terug op intel_gpu_top.',
          );
          return null; // let the caller fall back to intel_gpu_top
        }
        final prevMap = _prevFdinfoBusyNs[gpuId];
        if (prevMap == null) return null;
      } else {
        _fdinfoNoMatchStreak = 0;
      }

      var totalBusyNs = 0;
      final perPidBusyNs = <int, int>{};
      final prevBusy = _prevFdinfoBusyNs[gpuId];
      if (prevBusy != null) {
        for (final entry in currentBusy.entries) {
          final prevNs = prevBusy[entry.key];
          // A missing or larger previous value means this fd is new
          // (context just opened) or the counter reset — treat as no
          // contribution for this interval rather than guessing.
          if (prevNs != null && entry.value >= prevNs) {
            final deltaNs = entry.value - prevNs;
            totalBusyNs += deltaNs;
            // Key format is "pidStr:fdName" (see currentBusy above) —
            // split off just the PID for the per-process breakdown,
            // summing across every fd that PID has open on this GPU
            // (a process can hold more than one DRM context).
            final pid = int.tryParse(entry.key.split(':').first);
            if (pid != null) {
              perPidBusyNs[pid] = (perPidBusyNs[pid] ?? 0) + deltaNs;
            }
          }
        }
      }

      final prevTime = _prevFdinfoSampleTime[gpuId];
      _prevFdinfoBusyNs[gpuId] = currentBusy;
      _prevFdinfoSampleTime[gpuId] = now;

      if (prevTime == null) return null; // first sample — no delta yet, try again next poll

      final elapsedNs = now.difference(prevTime).inMicroseconds * 1000;
      if (elapsedNs <= 0) return null;

      final percent = (totalBusyNs / elapsedNs) * 100;
      final clamped = percent.clamp(0, 100).toDouble();

      final perPidPercent = <int, double>{};
      for (final entry in perPidBusyNs.entries) {
        perPidPercent[entry.key] = ((entry.value / elapsedNs) * 100).clamp(0, 100).toDouble();
      }
      _lastFdinfoPerPidPercent[gpuId] = perPidPercent;

      _gpuDiagnostics[gpuId] = GpuDiagnostic.ok;
      _lastFdinfoBusyResult[gpuId] = clamped;
      _logFdinfoStatusOnce('providing GPU load readings for $gpuId (no special permissions needed)');
      return clamped;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'fdinfo GPU read failed: $e');
      return null;
    }
  }

  /// Runs `action` over `items` with at most `concurrency` calls in
  /// flight at once, instead of either fully sequential (slow for many
  /// small I/O-bound calls) or fully unbounded (risks opening thousands
  /// of file handles at once). Used by the fdinfo scanner, where
  /// hundreds of directory listings and thousands of file reads used to
  /// run one at a time and dominated the scan's wall-clock time.
  Future<List<T?>> _mapConcurrent<S, T>(
    List<S> items,
    Future<T> Function(S item) action, {
    required int concurrency,
  }) async {
    if (items.isEmpty) return const [];
    final results = List<T?>.filled(items.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final i = nextIndex;
        if (i >= items.length) return;
        nextIndex++; // safe: no `await` between read and increment above
        try {
          results[i] = await action(items[i]);
        } catch (_) {
          results[i] = null;
        }
      }
    }

    final workerCount = concurrency < items.length ? concurrency : items.length;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results;
  }

  Future<String?> _resolvePciAddress(String devicePath) async {
    try {
      final ueventFile = File('$devicePath/uevent');
      if (!await ueventFile.exists()) return null;
      final content = await ueventFile.readAsString();
      final match = RegExp(r'PCI_SLOT_NAME=(\S+)').firstMatch(content);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  bool _fdinfoStatusLogged = false;
  void _logFdinfoStatusOnce(String status) {
    if (_fdinfoStatusLogged) return;
    _fdinfoStatusLogged = true;
    AppLogger.instance.info(_logSource, 'fdinfo: $status');
  }

  /// Best-effort Intel GPU load reading via `intel_gpu_top`, used only
  /// when sysfs's gpu_busy_percent isn't available. Requires the
  /// `intel-gpu-tools` package and sometimes elevated perf-event
  /// permissions — if either is missing, this quietly returns null
  /// (logged once, not treated as an error).
  Future<double?> _readIntelGpuBusyViaTool(String gpuId) async {
    // Once we know the tool is broken/missing, don't keep trying to
    // (re)start it on every 1s poll. Retry only every
    // _intelToolRetryInterval, or immediately after a successful in-app
    // fix (which resets this).
    final existing = _gpuDiagnostics[gpuId];
    if (existing != null && existing.kind != GpuDiagnosticKind.ok) {
      final lastAttempt = _lastIntelToolAttempt[gpuId];
      if (lastAttempt != null &&
          DateTime.now().difference(lastAttempt) < _intelToolRetryInterval) {
        return null;
      }
    }

    if (_intelGpuTopProcess == null && !_intelGpuTopStarting) {
      _lastIntelToolAttempt[gpuId] = DateTime.now();
      await _startPersistentIntelGpuTop(gpuId);
    }

    // Whether this call started the process or one is already running
    // from an earlier poll, the answer is whatever the background
    // stream listener has parsed most recently — there's no
    // spawn-and-wait here, matching how a continuous monitor like this
    // is meant to be used (this is the same approach Netdata's intelgpu
    // collector uses: one long-lived process, streamed, not
    // spawn/kill/parse per sample).
    return _cachedIntelGpuBusy;
  }

  /// Starts `intel_gpu_top` as a long-lived background process (no
  /// `timeout`, no spawn-per-poll) and streams its JSON samples as they
  /// arrive. This avoids the truncated-JSON problem entirely, since we
  /// never kill the process mid-write — we just keep reading its
  /// continuous output for as long as the app runs.
  Future<void> _startPersistentIntelGpuTop(String gpuId) async {
    _intelGpuTopStarting = true;
    _intelGpuTopGpuId = gpuId;
    try {
      final process = await Process.start(
        'intel_gpu_top',
        ['-J', '-o', '-', '-s', '1000'],
      );
      _intelGpuTopProcess = process;
      _intelGpuTopBuffer.clear();

      process.stdout.transform(const SystemEncoding().decoder).listen(
        _handleIntelGpuTopChunk,
        onError: (Object e) {
          AppLogger.instance.debug(_logSource, 'intel_gpu_top stdout stream error: $e');
        },
      );

      final stderrBuffer = StringBuffer();
      process.stderr.transform(const SystemEncoding().decoder).listen(
        stderrBuffer.write,
      );

      // If the process exits on its own (crash, permission denied,
      // killed elsewhere), record why and clear state so the next poll
      // tries again (subject to the throttle above) instead of quietly
      // going stale.
      unawaited(process.exitCode.then((code) {
        final stderrText = stderrBuffer.toString().trim();
        final isPermissionIssue = code == -6 || stderrText.toLowerCase().contains('permission');
        _gpuDiagnostics[gpuId] = isPermissionIssue
            ? GpuDiagnostic(
                kind: GpuDiagnosticKind.permissionDenied,
                message: 'intel_gpu_top kan geen perf-events openen zonder '
                    'verhoogde rechten (exit $code${stderrText.isNotEmpty ? ', stderr: $stderrText' : ''}).',
              )
            : GpuDiagnostic(
                kind: GpuDiagnosticKind.unknown,
                message: 'intel_gpu_top is gestopt '
                    '(exit $code${stderrText.isNotEmpty ? ', stderr: $stderrText' : ''}).',
              );
        _logIntelGpuTopStatusOnce(_gpuDiagnostics[gpuId]!.message);
        _intelGpuTopProcess = null;
        _cachedIntelGpuBusy = null;
      }));

      _intelGpuTopStarting = false;
    } catch (e) {
      _intelGpuTopStarting = false;
      final missing = e is ProcessException;
      _gpuDiagnostics[gpuId] = missing
          ? const GpuDiagnostic(
              kind: GpuDiagnosticKind.toolMissing,
              message: 'intel_gpu_top is niet geïnstalleerd (pakket intel-gpu-tools).',
            )
          : GpuDiagnostic(kind: GpuDiagnosticKind.unknown, message: 'intel_gpu_top-fout: $e');
      _logIntelGpuTopStatusOnce(_gpuDiagnostics[gpuId]!.message);
    }
  }

  /// Feeds one chunk of the continuous stdout stream into the buffer and
  /// extracts every complete top-level `{...}` object it can find via
  /// brace counting — intel_gpu_top's JSON output is effectively "[" once
  /// at the start, then comma-separated objects forever (it only closes
  /// the array on a clean exit, which never happens here since we keep
  /// it running). Complete objects are consumed from the buffer; any
  /// trailing partial object is kept for the next chunk.
  void _handleIntelGpuTopChunk(String chunk) {
    _intelGpuTopBuffer.write(chunk);
    final text = _intelGpuTopBuffer.toString();
    final codeUnits = text.codeUnits;
    const openBrace = 0x7B; // {
    const closeBrace = 0x7D; // }

    var depth = 0;
    var objectStart = -1;
    var consumedUntil = 0;

    for (var i = 0; i < codeUnits.length; i++) {
      final cu = codeUnits[i];
      if (cu == openBrace) {
        if (depth == 0) objectStart = i;
        depth++;
      } else if (cu == closeBrace) {
        depth--;
        if (depth == 0 && objectStart != -1) {
          _tryApplyIntelGpuTopSample(text.substring(objectStart, i + 1));
          consumedUntil = i + 1;
          objectStart = -1;
        }
      }
    }

    if (consumedUntil > 0) {
      final remainder = text.substring(consumedUntil);
      _intelGpuTopBuffer
        ..clear()
        ..write(remainder);
    }
    // Guard against an unbounded buffer if something upstream never
    // produces a balanced object (shouldn't happen, but don't let a
    // parsing edge case leak memory over a long-running session).
    if (_intelGpuTopBuffer.length > 1 << 20) {
      _intelGpuTopBuffer.clear();
    }
  }

  void _tryApplyIntelGpuTopSample(String objectJson) {
    try {
      final decoded = jsonDecode(objectJson) as Map<String, dynamic>;
      final engines = decoded['engines'] as Map<String, dynamic>?;
      final render = engines?['Render/3D/0'] as Map<String, dynamic>?;
      final busyRaw = render?['busy'];
      if (busyRaw == null) return;
      final parsed = double.tryParse(busyRaw.toString());
      if (parsed == null) return;

      _cachedIntelGpuBusy = parsed;
      final gpuId = _intelGpuTopGpuId;
      if (gpuId != null) {
        _gpuDiagnostics[gpuId] = GpuDiagnostic.ok;
        _logIntelGpuTopStatusOnce('providing GPU load readings');
      }
    } catch (_) {
      // Tolerate an occasional malformed fragment rather than taking
      // down the stream listener over it.
    }
  }

  void _logIntelGpuTopStatusOnce(String status) {
    if (_intelGpuTopStatusLogged) return;
    _intelGpuTopStatusLogged = true;
    AppLogger.instance.info(_logSource, 'intel_gpu_top: $status');
  }

  /// Stops the background intel_gpu_top process, if running. Call this
  /// when the owning widget/service is disposed so the subprocess
  /// doesn't outlive the app.
  void disposeIntelGpuTop() {
    _intelGpuTopProcess?.kill();
    _intelGpuTopProcess = null;
    _intelGpuTopBuffer.clear();
    _cachedIntelGpuBusy = null;
  }

  /// Grants `intel_gpu_top` specifically the capability it needs
  /// (CAP_PERFMON) to read perf-events, via
  /// `pkexec setcap cap_perfmon+ep <path-to-intel_gpu_top>`. This is
  /// deliberately narrower than lowering perf_event_paranoid system-wide:
  /// it's a one-time, permanent grant to that single binary rather than
  /// a system-wide relaxation of perf-event security, and it survives
  /// reboots. Pops up the normal polkit authentication dialog — the app
  /// itself never sees or handles the password.
  Future<bool> fixIntelGpuPermission() async {
    AppLogger.instance.info(_logSource, 'User requested GPU permission fix via pkexec (setcap)');
    try {
      final whichResult = await Process.run('which', ['intel_gpu_top']);
      if (whichResult.exitCode != 0) {
        AppLogger.instance.error(
          _logSource,
          'Cannot setcap: intel_gpu_top not found on PATH (is intel-gpu-tools installed?)',
        );
        return false;
      }
      final binaryPath = (whichResult.stdout as String).trim();

      final result = await Process.run(
        'pkexec',
        ['setcap', 'cap_perfmon+ep', binaryPath],
      );
      final success = result.exitCode == 0;
      AppLogger.instance.info(
        _logSource,
        success
            ? 'cap_perfmon granted to $binaryPath successfully'
            : 'pkexec setcap failed (exit ${result.exitCode}): ${(result.stderr as String).trim()}',
      );
      if (success) {
        // Kill any existing (broken/unprivileged) process and let the
        // next poll spawn a fresh one with the new permission — don't
        // wait for the "logged once" gate or throttle to expire.
        disposeIntelGpuTop();
        _intelGpuTopStatusLogged = false;
        _gpuDiagnostics.removeWhere((_, d) => d.kind != GpuDiagnosticKind.ok);
        _lastIntelToolAttempt.clear();
      }
      return success;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'pkexec call failed (is polkit installed?): $e');
      return false;
    }
  }

  /// Runs `pkexec apt-get install -y intel-gpu-tools`, streaming its
  /// output into the app log as it happens so a slow install is visible
  /// rather than the UI just looking stuck.
  Future<bool> installIntelGpuTools() async {
    AppLogger.instance.info(_logSource, 'User requested intel-gpu-tools install via pkexec');
    try {
      final process = await Process.start(
        'pkexec',
        ['apt-get', 'install', '-y', 'intel-gpu-tools'],
        environment: {'DEBIAN_FRONTEND': 'noninteractive'},
      );

      process.stdout.transform(const SystemEncoding().decoder).listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) AppLogger.instance.debug(_logSource, 'apt-get: $trimmed');
      });
      process.stderr.transform(const SystemEncoding().decoder).listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) AppLogger.instance.debug(_logSource, 'apt-get: $trimmed');
      });

      final exitCode = await process.exitCode;
      final success = exitCode == 0;
      AppLogger.instance.info(
        _logSource,
        success
            ? 'intel-gpu-tools installed successfully'
            : 'intel-gpu-tools install failed (exit $exitCode)',
      );
      if (success) {
        disposeIntelGpuTop();
        _intelGpuTopStatusLogged = false;
        _gpuDiagnostics.removeWhere((_, d) => d.kind != GpuDiagnosticKind.ok);
        _lastIntelToolAttempt.clear();
      }
      return success;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'pkexec apt-get call failed: $e');
      return false;
    }
  }
}
