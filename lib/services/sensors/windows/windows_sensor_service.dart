import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../../../core/models/battery_energy_sample.dart';
import '../../../core/models/battery_sample.dart';
import '../../../core/models/cpu_detail_info.dart';
import '../../../core/models/cpu_sample.dart';
import '../../../core/models/disk_health_info.dart';
import '../../../core/models/disk_sample.dart';
import '../../../core/models/gpu_diagnostic.dart';
import '../../../core/models/gpu_sample.dart';
import '../../../core/models/load_sample.dart';
import '../../../core/models/memory_sample.dart';
import '../../../core/models/network_sample.dart';
import '../../../core/models/system_info_sample.dart';
import '../system_sensor_service.dart';
import 'background_sensor_feed.dart';
import 'battery_ioctl_reader.dart';
import 'disk_activity_ioctl_reader.dart';
import 'libre_hardware_monitor.dart';
import 'native_battery_reader.dart';
import 'native_disk_space_reader.dart';
import 'native_elevation_check.dart';
import 'native_memory_reader.dart';
import 'native_system_info_reader.dart';
import 'native_uptime_reader.dart';
import 'ata_pass_through_reader.dart';
import 'nvme_health_reader.dart';
import 'dxgi_gpu_names.dart';
import 'pdh_ffi.dart';
import 'powershell_session.dart';

const _logSource = 'WindowsSensorService';

/// Reads live hardware telemetry on Windows via PowerShell + CIM/WMI —
/// the Windows equivalent of [LinuxSensorService]'s /proc and sysfs
/// reads. Implements the same [SystemSensorService] contract, so every
/// screen and service in the app works unchanged regardless of which
/// platform actually ends up running.
///
/// **This implementation was written without access to a real Windows
/// machine to test against.** Every PowerShell query below is believed
/// correct based on documented CIM class properties, but WMI/CIM
/// property availability has genuine, known gaps across Windows
/// versions and hardware vendors — treat every null-returning field as
/// a plausible first real bug to check, not necessarily a driver
/// limitation the way most Linux nulls in this app are.
///
/// CPU temperature/power and AMD/Intel GPU load/temperature aren't
/// available via stock Windows WMI at all — closed via
/// [LibreHardwareMonitorBridge] (see its own class doc), the same
/// approach Marco previously used for Hardware Tester. That bridge
/// degrades gracefully (returns null, logs once) when its DLL isn't
/// present, so this class works either way — just with those specific
/// fields empty until the DLL is placed where the bridge looks for it.
///
/// One [PowerShellSession] is shared across most reads, since spawning a
/// fresh `powershell.exe` per query would cost ~200-500ms every time —
/// noticeable at this app's ~1s poll cadence.
///
/// **The LHM bridge gets its own, second [PowerShellSession]
/// ([_lhmShell]) instead of sharing [_shell].** Added 2026-09-22: LHM's
/// own init (`Computer.Open()` + PawnIO driver load + hardware
/// enumeration + its diagnostic sweep) is easily the heaviest single
/// command either session ever runs — measured at over 8s on a cold
/// start on a slower machine (see [LibreHardwareMonitorBridge._doInitialize]).
/// When that ran through the one shared session, every *other*
/// PowerShell-backed sensor (network counters, page-file usage, video
/// controller CIM, ...) queued up behind it and couldn't return its own,
/// otherwise-fast first reading until LHM's init finished — the actual
/// cause behind "sensors take a while to show up" at cold start, not
/// just LHM itself being slow. Splitting LHM onto its own session lets
/// those other reads return immediately while LHM initializes in the
/// background on its own process; only the sensors that actually go
/// through LHM (CPU temperature/power, AMD/Intel GPU load/temperature)
/// still wait on it, exactly as before.
class WindowsSensorService implements SystemSensorService {
  final PowerShellSession _shell = PowerShellSession();

  /// Dedicated session for [_lhm] — see the class doc above for why this
  /// isn't [_shell].
  final PowerShellSession _lhmShell = PowerShellSession();
  final PdhCpuReader _pdhCpu = PdhCpuReader();

  /// Fast, native (no PowerShell, no WMI) thread-/process-count
  /// reading — see [PdhSystemReader]'s class doc in `pdh_ffi.dart` for
  /// why this was added (the `Win32_PerfFormattedData_PerfOS_System`
  /// WMI query it replaces was confirmed visibly slow/timing out live).
  final PdhSystemReader _pdhSystem = PdhSystemReader();

  /// Fast, native (no PowerShell, no WMI) swap/pagefile usage
  /// percentage — see [PdhPageFileReader]'s class doc in `pdh_ffi.dart`.
  final PdhPageFileReader _pdhPageFile = PdhPageFileReader();
  late final LibreHardwareMonitorBridge _lhm = LibreHardwareMonitorBridge(_lhmShell);

  /// Absolute last-resort CPU/system temperature source — tried only
  /// when [_backgroundFeed] and [_lhm] have both already come up empty
  /// for this poll. See [PdhThermalZoneReader]'s class doc for why this
  /// exists (TMOG's own disassembly confirmed it uses the same ACPI
  /// thermal zone counter as its resilience layer) and why its reading
  /// is deliberately coarse.
  final PdhThermalZoneReader _pdhThermalZone = PdhThermalZoneReader();

  // Logged once, not per-poll (this method runs every second) — a
  // simple confirmation that the background feed is actually serving
  // fresh temperature data, since BackgroundSensorFeed.readFeed()
  // itself stays quiet on success (only failure paths log anything),
  // which otherwise leaves no way to tell from the log alone whether
  // it's genuinely in use versus the per-launch LHM path silently
  // taking over.
  bool _loggedBackgroundFeedInUse = false;

  // Same one-time-log reasoning as [_loggedBackgroundFeedInUse] above,
  // for the ACPI thermal zone fallback (see [_pdhThermalZone]).
  bool _loggedThermalZoneFallbackInUse = false;

  /// Runs a PowerShell script that ends in `ConvertTo-Json -Compress`
  /// and decodes the result. Returns null on any failure (session
  /// unavailable, malformed/empty output, wrong type) — callers should
  /// already handle null as "unavailable," same as every Linux sensor
  /// read in this app.
  Future<dynamic> _runJson(String script) async {
    final output = await _shell.run(script);
    if (output == null) return null;
    final trimmed = output.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to parse JSON from PowerShell: $e\nOutput was: $trimmed');
      return null;
    }
  }

  /// Turns the Winlogon Shell registry value into a readable name.
  /// "explorer.exe" (the default on virtually every Windows install)
  /// becomes "Windows Verkenner (Explorer)"; anything else is shown
  /// as-is, since a replaced shell is unusual enough that guessing at
  /// a friendly name for it would be more likely wrong than helpful.
  String? _describeShellPath(String? shellPath) {
    if (shellPath == null || shellPath.isEmpty) return null;
    if (shellPath.toLowerCase().contains('explorer.exe')) return 'Windows Verkenner (Explorer)';
    return shellPath;
  }

  /// Maps the process that launched DarkTask to a readable name — the
  /// small, closed set of common launchers gets friendly Dutch names;
  /// anything else (a less common terminal emulator, a script runner)
  /// is shown by its own process name rather than forced into one of
  /// these buckets.
  String? _describeLauncherProcess(String? processName) {
    if (processName == null || processName.isEmpty) return null;
    switch (processName.toLowerCase()) {
      case 'explorer.exe':
        return 'Windows Verkenner (dubbelklik)';
      case 'powershell.exe':
        return 'Windows PowerShell';
      case 'pwsh.exe':
        return 'PowerShell 7+';
      case 'cmd.exe':
        return 'Opdrachtprompt (cmd.exe)';
      case 'windowsterminal.exe':
        return 'Windows Terminal';
      default:
        return processName;
    }
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  // --- CPU -----------------------------------------------------------

  bool _cpuCountersReady = false;
  bool _cpuCountersFailed = false;
  Future<bool>? _cpuCountersInitInFlight;

  /// Creates persistent .NET `System.Diagnostics.PerformanceCounter`
  /// objects (kept alive in the PowerShell session's global scope,
  /// same lifetime pattern as LibreHardwareMonitor's Computer object)
  /// once, instead of using `Get-CimInstance
  /// Win32_PerfFormattedData_PerfOS_Processor` on every poll.
  ///
  /// This isn't a style preference — independently measured,
  /// `Get-CimInstance` against `*PerfFormattedData*` WMI classes
  /// averages roughly a quarter of a second *per call*, because the
  /// WMI provider layer wraps the underlying Performance Data Helper
  /// (PDH) API with substantial overhead of its own. A raw
  /// `PerformanceCounter` object talks to PDH directly: creating it
  /// once costs about the same as one `Get-CimInstance` call, but every
  /// subsequent `.NextValue()` call is essentially instant. At this
  /// app's ~1s poll cadence, that's the difference between CPU load
  /// alone costing ~250ms of the one shared PowerShell session's time
  /// every single tick, versus a few milliseconds.
  ///
  /// Falls back to the `Get-CimInstance`-based path automatically if
  /// counter creation fails for any reason (e.g. a locale or
  /// permissions quirk on some machines) — this is a genuine, sourced
  /// optimization, but one this bridge can't fully verify without a
  /// Windows machine to measure the before/after on directly.
  Future<bool> _ensureCpuCountersReady() async {
    if (_cpuCountersReady) return true;
    if (_cpuCountersFailed) return false;

    // Two pollers can call this before either one's PowerShell
    // round-trip below has finished (e.g. MonitoringDashboard and
    // PerformanceScreen both polling within the same startup window,
    // before _cpuCountersReady flips true) — without this guard, both
    // would independently run the init script and both log "actief",
    // which is confusing noise in the log even though it's otherwise
    // harmless (creating the same PowerShell counters twice doesn't
    // break anything). Sharing one in-flight Future makes every
    // concurrent caller await the same single attempt instead.
    final inFlight = _cpuCountersInitInFlight;
    if (inFlight != null) return inFlight;
    final future = _initCpuCounters();
    _cpuCountersInitInFlight = future;
    try {
      return await future;
    } finally {
      _cpuCountersInitInFlight = null;
    }
  }

  Future<bool> _initCpuCounters() async {
    final script = r"try { "
        r"$global:__darktaskCpuCounters = @{}; "
        r"$names = (New-Object System.Diagnostics.PerformanceCounterCategory('Processor')).GetInstanceNames(); "
        r"foreach ($n in $names) { "
        r"  $c = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', $n); "
        r"  $c.NextValue() | Out-Null; "
        r"  $global:__darktaskCpuCounters[$n] = $c; "
        r"} "
        r"$global:__darktaskCpuPrivCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Privileged Time', '_Total'); "
        r"$global:__darktaskCpuPrivCounter.NextValue() | Out-Null; "
        r"Write-Output 'DARKTASK_CPU_COUNTERS_OK' "
        r"} catch { Write-Output ('DARKTASK_CPU_COUNTERS_ERROR: ' + $_.Exception.Message) }";

    final result = await _shell.run(script);
    final trimmed = result?.trim() ?? '';
    if (trimmed.contains('DARKTASK_CPU_COUNTERS_OK')) {
      _cpuCountersReady = true;
      AppLogger.instance.info(_logSource, 'Snelle CPU-belastingstellers (.NET PerformanceCounter) actief.');
      return true;
    }

    _cpuCountersFailed = true;
    AppLogger.instance.info(
      _logSource,
      'Kon snelle CPU-belastingstellers niet initialiseren (${trimmed.isEmpty ? "geen output" : trimmed}) — '
      'valt terug op de tragere Get-CimInstance-methode voor CPU-belasting. Dit bericht komt niet terug.',
    );
    return false;
  }

  /// The actual PowerShell round-trip behind the per-core CPU
  /// load/clock-speed figures — factored out of `_readCpuUncached` so
  /// it has exactly one implementation whether it's awaited inline
  /// (no FFI headline number available at all) or run in the
  /// background (FFI already has the headline number; see
  /// `_refreshPerCoreInBackground`). Returns null only if the
  /// PowerShell round-trip itself produced nothing usable — a plain
  /// zero-filled result still comes back as a normal map.
  Future<Map<String, dynamic>?> _fetchCpuCountersViaPowerShell() async {
    final countersReady = await _ensureCpuCountersReady();
    dynamic result;
    if (countersReady) {
      result = await _runJson(
        r"$perf = @{}; "
        r"foreach ($k in $global:__darktaskCpuCounters.Keys) { $perf[$k] = [math]::Round($global:__darktaskCpuCounters[$k].NextValue(), 1) } "
        r"$priv = [math]::Round($global:__darktaskCpuPrivCounter.NextValue(), 1); "
        r"$clock = (Get-CimInstance Win32_Processor | Select-Object -First 1).CurrentClockSpeed; "
        r"[PSCustomObject]@{ perf = $perf; priv = $priv; clock = $clock } | ConvertTo-Json -Compress -Depth 4",
      );
    } else {
      // Fallback path — combined into one round-trip (processor
      // load/kernel-time rows plus clock speed) rather than two
      // separate calls, same reasoning as before: every extra
      // PowerShell round-trip is fully serialized through the one
      // shared PowerShellSession.
      result = await _runJson(
        r'$perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | '
        r'Select-Object Name, PercentProcessorTime, PercentPrivilegedTime; '
        r'$clock = (Get-CimInstance Win32_Processor | Select-Object -First 1).CurrentClockSpeed; '
        r'[PSCustomObject]@{ perf = $perf; clock = $clock } | ConvertTo-Json -Compress -Depth 4',
      );
    }
    if (result == null) return null;

    double freshOverall = 0;
    double freshSystem = 0;
    final perCore = <int, double>{};

    if (countersReady) {
      // Fast path: $perf is already a flat {"0": 12.3, "1": 5.0,
      // "_Total": 8.1, ...} map — no Name/PercentProcessorTime rows to
      // walk, since PerformanceCounter's own instance names are the
      // keys directly.
      final perfMap = result['perf'] as Map<String, dynamic>?;
      freshSystem = _asDouble(result['priv']) ?? 0;
      if (perfMap != null) {
        for (final entry in perfMap.entries) {
          final value = _asDouble(entry.value) ?? 0;
          if (entry.key == '_Total') {
            freshOverall = value;
          } else {
            final coreIndex = int.tryParse(entry.key);
            if (coreIndex != null) perCore[coreIndex] = value;
          }
        }
      }
    } else {
      final perfRaw = result['perf'];
      final rows = perfRaw is List ? perfRaw : [perfRaw];
      for (final row in rows) {
        final name = row['Name']?.toString();
        final pct = _asDouble(row['PercentProcessorTime']) ?? 0;
        if (name == '_Total') {
          freshOverall = pct;
          freshSystem = _asDouble(row['PercentPrivilegedTime']) ?? 0;
        } else {
          final coreIndex = int.tryParse(name ?? '');
          if (coreIndex != null) perCore[coreIndex] = pct;
        }
      }
    }

    final freshPerCoreList = <double>[];
    final sortedIndices = perCore.keys.toList()..sort();
    for (final i in sortedIndices) {
      freshPerCoreList.add(perCore[i]!);
    }
    final freshClockMHz = _asDouble(result['clock']);

    return {
      'overall': freshOverall,
      'system': freshSystem,
      'perCore': freshPerCoreList,
      'clock': freshClockMHz,
    };
  }

  bool _perCoreRefreshInFlight = false;

  /// Fire-and-forget refresh of the PowerShell-derived per-core/clock
  /// cache (see the `pdhResult != null` branch of `_readCpuUncached`
  /// for why this exists instead of being awaited inline). Guarded
  /// against overlapping refreshes — at this app's ~1s poll cadence, a
  /// slow first PowerShell round-trip could otherwise pile up several
  /// redundant ones before the first even returns.
  void _refreshPerCoreInBackground() {
    if (_perCoreRefreshInFlight) return;
    _perCoreRefreshInFlight = true;
    unawaited(
      _fetchCpuCountersViaPowerShell().then((fetched) {
        if (fetched != null) {
          _perCoreCache = {'perCore': fetched['perCore'], 'clock': fetched['clock']};
          _perCoreCacheTime = DateTime.now();
        }
      }).catchError((Object e, StackTrace st) {
        AppLogger.instance.debug(_logSource, 'Achtergrond-verversing van per-core CPU-gegevens mislukt: $e');
      }).whenComplete(() => _perCoreRefreshInFlight = false),
    );
  }

  // Per-core breakdown and clock speed don't need to be as fresh as
  // the headline "CPU load" number every single poll — nobody notices
  // if the per-core mini-graphs are a couple of seconds behind. Caching
  // them separately (and more loosely) than the aggregate figure below
  // means the PDH-FFI fast path can genuinely skip the PowerShell
  // round-trip most polls, rather than paying for it every single
  // second regardless of which source supplies the headline number.
  Map<String, dynamic>? _perCoreCache;
  DateTime? _perCoreCacheTime;
  static const _perCoreCacheTtl = Duration(seconds: 3);

  // A short cache on the *entire* readCpu() result — distinct from the
  // per-core cache above, which only covers half of it. This exists
  // specifically for the "alles tegelijk" stress test: CPU, memory,
  // and crypto sub-benchmarks each run their own independent 1-second
  // safety timer, all calling this same method on this same shared
  // WindowsSensorService instance. Without this cache, three
  // near-simultaneous callers meant three full reads (PDH + LHM +
  // PowerShell) every second instead of one — exactly the load that
  // was observed to overwhelm both the shared PowerShell session and
  // the PDH query itself during real testing. A caller arriving within
  // this short window gets the same reading the first caller already
  // paid for, rather than triggering a redundant one of its own.
  CpuSample? _fullCpuSampleCache;
  DateTime? _fullCpuSampleCacheTime;
  static const _fullCpuSampleCacheTtl = Duration(milliseconds: 700);

  /// The most recently resolved CPU temperature — from whichever
  /// source actually supplied it (BackgroundSensorFeed, the in-process
  /// LibreHardwareMonitor bridge, or, as a last resort, the ACPI
  /// thermal zone counter in [_pdhThermalZone]; see the assignment in
  /// [_readCpuUncached] for why this is tracked separately from any one
  /// source's own internal state). Read by
  /// [needsElevationForFullSensors]/[msrBlockedDespiteElevation] below
  /// so those warnings only show when there's genuinely no working
  /// temperature reading at all — not whenever one specific internal
  /// path happens to be blocked while another already covers it.
  double? _lastKnownCpuTempC;

  @override
  Future<CpuSample> readCpu() async {
    final cached = _fullCpuSampleCache;
    final cachedAt = _fullCpuSampleCacheTime;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _fullCpuSampleCacheTtl) {
      return cached;
    }
    final sample = await _readCpuUncached();
    _fullCpuSampleCache = sample;
    _fullCpuSampleCacheTime = DateTime.now();
    return sample;
  }

  Future<CpuSample> _readCpuUncached() async {
    try {
      // Fast path first: a direct dart:ffi PDH reading needs no
      // PowerShell round-trip at all for the headline figures. If it's
      // unavailable or fails (including permanently disabling itself —
      // see PdhCpuReader's class doc on why that's deliberate), this
      // falls through to the always-available PowerShell path below,
      // which also refreshes the per-core cache as a side effect.
      final pdhResult = _pdhCpu.read();

      final perCoreCached = _perCoreCache;
      final perCoreCachedAt = _perCoreCacheTime;
      final perCoreFresh = perCoreCached != null &&
          perCoreCachedAt != null &&
          DateTime.now().difference(perCoreCachedAt) < _perCoreCacheTtl;

      double overall;
      double system;
      List<double> perCoreList;
      double? clockMHz;

      if (pdhResult != null && perCoreFresh) {
        // Genuinely no PowerShell round-trip this poll — both halves
        // came from cache/FFI.
        overall = pdhResult['overall']!;
        system = pdhResult['privileged']!;
        perCoreList = List<double>.from(perCoreCached['perCore'] as List);
        clockMHz = perCoreCached['clock'] as double?;
      } else if (pdhResult != null) {
        // The headline figure is already in hand via pure FFI — no
        // PowerShell needed for it at all. Only the per-core breakdown
        // and clock speed are stale/missing, and nobody's looking at
        // those within the first second of the app being open (or even
        // the first several polls). Making this poll's *entire* result
        // — and, on the very first call ever, the whole app's
        // splash-screen warm-up `Future.wait` in app.dart — wait on a
        // cold `powershell.exe` spawn (~1+ second, per real measured
        // logs) just to backfill numbers nothing is rendering yet was
        // exactly the "eerste PowerShell-aanroep kost een volle
        // seconde" cold-start cost a person asked to have addressed.
        // Refreshing in the background instead means this call returns
        // immediately with the real overall number, and the per-core
        // cache fills in a poll or two later — same trade-off already
        // used for CPU temperature (BackgroundSensorFeed) and the
        // disk-space/SMART split.
        _refreshPerCoreInBackground();
        overall = pdhResult['overall']!;
        system = pdhResult['privileged']!;
        perCoreList = perCoreCached != null ? List<double>.from(perCoreCached['perCore'] as List) : <double>[];
        clockMHz = perCoreCached?['clock'] as double?;
      } else {
        // No FFI fallback for the headline number either here — this
        // path genuinely has nothing to return without the PowerShell
        // round-trip, so (unlike the branch above) it has to be awaited
        // inline.
        final fetched = await _fetchCpuCountersViaPowerShell();
        if (fetched == null) return CpuSample.empty();

        final freshPerCoreList = fetched['perCore'] as List<double>;
        final freshClockMHz = fetched['clock'] as double?;
        _perCoreCache = {'perCore': freshPerCoreList, 'clock': freshClockMHz};
        _perCoreCacheTime = DateTime.now();

        overall = fetched['overall'] as double;
        system = fetched['system'] as double;
        perCoreList = freshPerCoreList;
        clockMHz = freshClockMHz;
      }

      // Prefer the persistent background task (BackgroundSensorFeed)
      // when it's set up and producing fresh data — no PowerShell
      // round-trip needed at all, and crucially, no re-elevation
      // needed either, unlike the per-launch LibreHardwareMonitorBridge
      // path below. Falls through to that existing, always-available
      // path when the background task isn't set up or has gone stale.
      final feed = await _backgroundFeed.readFeed();
      double? temperatureC = _asDouble(feed?['cpuTempC']);

      if (temperatureC != null && !_loggedBackgroundFeedInUse) {
        _loggedBackgroundFeedInUse = true;
        AppLogger.instance.info(
          _logSource,
          'Achtergronddienst levert verse CPU-temperatuur (${temperatureC.toStringAsFixed(0)}°C) — '
          'geen koude LibreHardwareMonitor-opstart nodig voor dit specifieke getal. Dit bericht komt niet terug.',
        );
      }

      // LibreHardwareMonitorLib fills the gap stock WMI leaves — returns
      // null (not a fabricated value) if the DLL isn't present or a
      // specific CPU doesn't expose a given sensor; see
      // LibreHardwareMonitorBridge's class doc for both cases. Cached
      // internally by the bridge for a fraction of a second, so calling
      // it here even when temperatureC is already satisfied by the
      // background feed costs nothing extra — readCpuPowerWatts() below
      // already calls this every tick regardless, and shares that same
      // cache window. Fan RPM has no background-feed equivalent, so
      // this is the only source for it.
      final lhmCpu = await _lhm.readCpuSensors();
      temperatureC ??= lhmCpu?['temperatureC'];
      final fanRpm = lhmCpu?['fanRpm'];

      // Both sources above have now had their shot. Rather than
      // leaving temperatureC null on hardware neither one can read —
      // an unsupported CPU generation, an undocumented embedded
      // controller, a persistent VBS/MSR block — try the ACPI thermal
      // zone counter every other tool (including TMOG, confirmed via
      // its own disassembly — see PdhThermalZoneReader's class doc)
      // falls back to. Coarser than a proper CPU-package reading, but
      // "a coarse number" beats "no number at all" for the warning
      // banner this feeds into.
      if (temperatureC == null) {
        final thermalZoneC = _pdhThermalZone.read();
        if (thermalZoneC != null) {
          temperatureC = thermalZoneC;
          // Logged from right here, using the just-null-checked local
          // (not the outer `temperatureC` field) — the analyzer can
          // promote `thermalZoneC` to non-nullable `double` from the
          // `!= null` check immediately above, but it can't promote
          // `temperatureC` itself this way (it's reassigned in a
          // branch, not narrowed by a direct null-check right before
          // use), so building the log message from `thermalZoneC`
          // instead avoids a `double?`-not-null compile error for
          // `toStringAsFixed`.
          if (!_loggedThermalZoneFallbackInUse) {
            _loggedThermalZoneFallbackInUse = true;
            AppLogger.instance.info(
              _logSource,
              'Achtergronddienst en LibreHardwareMonitor leverden geen CPU-temperatuur — '
              'ACPI thermal zone-teller gebruikt als laatste redmiddel (${thermalZoneC.toStringAsFixed(0)}°C, '
              'grover dan een echte CPU-package-uitlezing). Dit bericht komt niet terug.',
            );
          }
        }
      }

      // Tracked separately from `_lhm.needsElevation`/`msrBlockedByVbs`
      // (see [needsElevationForFullSensors]/[msrBlockedDespiteElevation]
      // below) precisely because those two can be true at the same
      // moment this ends up with a perfectly good number: when
      // BackgroundSensorFeed is set up and delivering a fresh
      // temperature (a separate, already-elevated background task —
      // see its own class doc), `temperatureC` above is already
      // satisfied before `_lhm.readCpuSensors()` even runs. That call
      // still happens every poll regardless (for fanRpm, and as the
      // fallback source), and on a machine where THIS process's own
      // in-process LibreHardwareMonitor instance genuinely can't read
      // MSR temps (a real, persistent block for that specific process,
      // not a one-off cold-start race), its `needsElevation`/
      // `msrBlockedByVbs` flags stay true forever — accurately
      // describing that one internal path, but confusingly, since the
      // background feed's separate reading means the person is looking
      // at a working number the whole time. Reported and reproduced:
      // the warning banner kept showing "geblokkeerd" with a real
      // temperature plainly visible right next to it.
      _lastKnownCpuTempC = temperatureC;

      return CpuSample(
        timestamp: DateTime.now(),
        overallLoadPercent: overall,
        systemLoadPercent: system,
        perCoreLoadPercent: perCoreList,
        clockMHz: clockMHz,
        temperatureC: temperatureC,
        fanRpm: fanRpm?.round(),
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read CPU stats: $e\n$st');
      return CpuSample.empty();
    }
  }

  @override
  Future<double?> readCpuPowerWatts() async {
    // Same preference order as the temperature read above (background
    // feed first, this bridge as fallback) — but with one extra
    // caveat temperature doesn't need. LibreHardwareMonitor's "CPU
    // Package" RAPL power sensor starts at an explicit 0.0 (never
    // null) until a real energy delta has been computed — see
    // LibreHardwareMonitorBridge.cpuPowerStuckAtZero's doc for the
    // full story on that quirk, reproduced and documented earlier in
    // this same file. For THIS bridge's own live reads that 0.0 only
    // ever lasts a single tick, since the same long-lived Computer
    // object keeps getting polled every second regardless — but the
    // background feed is a separate, standalone process with its own
    // independent PawnIO/MSR access, opened once at task-start and
    // never retried. Nothing guarantees that process's driver access
    // succeeds or fails in lockstep with this one's, and reproduced
    // live: a background feed whose own energy-delta calculation
    // never gets off the ground stays wedged at that literal starting
    // 0.0 forever, with nothing left to compute a real delta against.
    // Trusting any non-null feed value unconditionally (the original
    // version of this method) meant that permanently-stuck 0.0 would
    // always win over a perfectly real, live, non-zero reading this
    // same poll's own bridge could supply instead — the exact "power
    // shows 0.0 W and never moves" symptom this was rewritten for.
    // So: only treat a reading as trustworthy proof of a working power
    // sensor when it's genuinely non-zero; a bare 0.0 from either
    // source falls through to whichever source (if any) actually has
    // something better, and only settles for a stuck 0.0 (over
    // showing nothing at all) once neither source has anything better
    // to offer.
    final feed = await _backgroundFeed.readFeed();
    final feedPower = _asDouble(feed?['cpuPowerW']);
    if (feedPower != null && feedPower != 0.0) return feedPower;

    // No standard WMI/CIM power-draw sensor on stock Windows —
    // LibreHardwareMonitorLib closes this gap when its DLL is present
    // (see LibreHardwareMonitorBridge); null otherwise, same as every
    // other genuinely-unavailable sensor in this app.
    final lhmCpu = await _lhm.readCpuSensors();
    final bridgePower = lhmCpu?['powerWatts'];
    if (bridgePower != null && bridgePower != 0.0) return bridgePower;

    return feedPower ?? bridgePower;
  }

  final BackgroundSensorFeed _backgroundFeed = BackgroundSensorFeed();
  final NvmeHealthReader _nvmeHealth = NvmeHealthReader();
  final AtaPassThroughReader _ataPassThrough = AtaPassThroughReader();
  final BatteryIoctlReader _batteryIoctl = BatteryIoctlReader();

  final NativeSystemInfoReader _nativeSystemInfo = NativeSystemInfoReader();

  @override
  Future<CpuDetailInfo> readCpuDetails() async {
    try {
      final result = await _runJson(
        r'$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1; '
        r'$cs = Get-CimInstance Win32_ComputerSystem; '
        r'[PSCustomObject]@{ '
        r'NumberOfCores = $cpu.NumberOfCores; '
        r'NumberOfLogicalProcessors = $cpu.NumberOfLogicalProcessors; '
        r'NumberOfProcessors = $cs.NumberOfProcessors; '
        r'VirtualizationFirmwareEnabled = $cpu.VirtualizationFirmwareEnabled; '
        r'HypervisorPresent = $cs.HypervisorPresent; '
        r'Model = $cs.Model; '
        r'MaxClockSpeed = $cpu.MaxClockSpeed '
        r'} | ConvertTo-Json -Compress',
      );
      if (result == null) return CpuDetailInfo.unknown();

      final model = (result['Model'] as String?)?.toLowerCase() ?? '';
      final isVm = model.contains('virtual') || model.contains('vmware') || model.contains('kvm');

      // Direct native call for this one field where a genuinely
      // unambiguous native equivalent exists (see
      // NativeSystemInfoReader's class doc on why this doesn't remove
      // the WMI round-trip above — the rest of this data still needs
      // it regardless). Falls back to the WMI-derived value on any
      // failure, same as every other reader.
      final nativeLogicalProcessors = _nativeSystemInfo.readLogicalProcessorCount();

      // **Added 2026-09-16.** Mirrors what PowerFreqService._readWindows()
      // already does for the Energie/Frequentie-scherm: Windows has no
      // real cpufreq governor, but its active Power Plan is the closest
      // conceptual equivalent (it also drives CPU frequency-scaling
      // behavior, among other things) — see that method's doc comment
      // for the full reasoning on why a Power Plan is prefixed
      // "Energieschema:" rather than presented as if it were a genuine
      // governor. Read fresh here rather than shared with
      // PowerFreqService's own 5s cache: this runs once per
      // Performance-screen visit (see CpuDetailInfo's "read once, not
      // polled" doc), not once a second, so the extra `powercfg`
      // process call costs nothing worth caching for.
      final powerPlanName = await _readActivePowerPlanName();

      // **Added 2026-09-16.** `Win32_Processor.VirtualizationFirmwareEnabled`
      // alone is a known-unreliable WMI field — confirmed live: reported
      // null/false on real hardware that plainly has VT-x/AMD-V enabled
      // (Hyper-V, WSL2, or Geheugenintegriteit/Kernisolatie/VBS was
      // already running there — see libre_hardware_monitor.dart's own
      // VBS diagnostic for that same underlying factor). Once a
      // hypervisor has taken over the machine, this specific WMI
      // property's detection method stops working correctly for reasons
      // Microsoft has never fully documented; it isn't specific to this
      // app. `Win32_ComputerSystem.HypervisorPresent` is a much stronger
      // positive signal precisely *because* it's the inverse situation:
      // if a hypervisor (Hyper-V, VBS, or — for a VM guest — the host's
      // own hypervisor) is actively running right now, hardware
      // virtualization is provably enabled, since none of those can run
      // without it. Costs no extra WMI round-trip — $cs was already
      // being fetched above for Model/NumberOfProcessors. Left null
      // (→ "onbekend" in the UI) only when *neither* signal is
      // positive — still honest, not a guess, for the genuine case of
      // an older machine where VT-x really is off or this WMI class
      // simply doesn't populate either field.
      final virtualizationFirmwareEnabled = result['VirtualizationFirmwareEnabled'] == true;
      final hypervisorPresent = result['HypervisorPresent'] == true;
      final String? virtualizationSupport;
      if (virtualizationFirmwareEnabled) {
        virtualizationSupport = 'Enabled (firmware)';
      } else if (hypervisorPresent) {
        virtualizationSupport = 'Enabled (hypervisor actief)';
      } else {
        virtualizationSupport = null;
      }

      return CpuDetailInfo(
        physicalCores: _asInt(result['NumberOfCores']),
        logicalProcessors: nativeLogicalProcessors ?? _asInt(result['NumberOfLogicalProcessors']),
        sockets: _asInt(result['NumberOfProcessors']),
        virtualizationSupport: virtualizationSupport,
        isVirtualMachine: isVm,
        baseSpeedMHz: _asDouble(result['MaxClockSpeed']),
        // "Frequency driver" is a Linux (cpufreq) concept with no
        // direct Windows equivalent at all — left null rather than
        // guessing at something that isn't the same thing.
        governor: powerPlanName != null ? 'Energieschema: $powerPlanName' : null,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read CPU details: $e');
      return CpuDetailInfo.unknown();
    }
  }

  /// Active Windows Power Plan's display name (e.g. "Balanced", "Hoge
  /// prestaties"), or null if it couldn't be read. Same `powercfg
  /// /getactivescheme` call and same parsing (the name is the part in
  /// parentheses; the GUID before it isn't useful to show) as
  /// `PowerFreqService._readWindows()` — kept as its own separate call
  /// here rather than sharing that service's instance/cache, since nothing
  /// links the two services together and this one only ever runs once
  /// per Performance-screen visit.
  Future<String?> _readActivePowerPlanName() async {
    try {
      final schemeResult = await Process.run('powercfg', ['/getactivescheme']);
      if (schemeResult.exitCode != 0) return null;
      final match = RegExp(r'\(([^)]+)\)').firstMatch(schemeResult.stdout as String);
      return match?.group(1);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'powercfg /getactivescheme failed: $e');
      return null;
    }
  }

  // Fallback path only as of 2026-09-15 — both callers now try
  // PdhSystemReader (dart:ffi, no WMI at all) first; see that class's
  // doc in pdh_ffi.dart. Kept as-is for when that reader is unavailable
  // or has disabled itself: shared between readThreadCount() and
  // readLoad(), which otherwise would each independently query the same
  // underlying Win32_PerfFormattedData_PerfOS_System WMI object (one of
  // the measurably-slow "*PerfFormattedData*" classes) for a different
  // property — cached briefly so calling both in the same poll tick
  // costs one round-trip instead of two.
  Map<String, dynamic>? _systemPerfCache;
  DateTime? _systemPerfCacheTime;
  static const _systemPerfCacheTtl = Duration(milliseconds: 800);

  Future<Map<String, dynamic>?> _getSystemPerfData() async {
    final cached = _systemPerfCache;
    final cachedAt = _systemPerfCacheTime;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _systemPerfCacheTtl) {
      return cached;
    }
    final result = await _runJson(
      'Get-CimInstance Win32_PerfFormattedData_PerfOS_System | '
      'Select-Object Threads, Processes | ConvertTo-Json -Compress',
    );
    if (result is Map<String, dynamic>) {
      _systemPerfCache = result;
      _systemPerfCacheTime = DateTime.now();
      return result;
    }
    return null;
  }

  @override
  Future<int?> readThreadCount() async {
    try {
      // Fast path first: PdhSystemReader needs no PowerShell/WMI
      // round-trip at all — see its class doc in pdh_ffi.dart. Falls
      // through to the WMI-based reading below on any failure
      // (including permanently disabling itself).
      final pdhResult = _pdhSystem.read();
      if (pdhResult != null) return pdhResult['threads'];

      final data = await _getSystemPerfData();
      return _asInt(data?['Threads']);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read thread count: $e');
      return null;
    }
  }

  // --- Memory & load ---------------------------------------------------

  @override
  Future<LoadSample> readLoad() async {
    // Windows has no direct equivalent of Unix load averages (a
    // run-queue-length statistic sampled by the scheduler) — rather
    // than fabricate one, this uses current CPU load as the closest
    // available approximation for load1, and leaves load5/load15 at 0
    // (never populated) so they read as "not available" rather than a
    // real 5/15-minute average that doesn't actually exist here.
    try {
      // Same fast native path as readThreadCount() above, and the same
      // fallback — see PdhSystemReader's class doc in pdh_ffi.dart.
      final pdhResult = _pdhSystem.read();
      final int totalTasks;
      if (pdhResult != null) {
        totalTasks = pdhResult['processes']!;
      } else {
        final data = await _getSystemPerfData();
        totalTasks = _asInt(data?['Processes']) ?? 0;
      }
      final cpu = await readCpu();
      return LoadSample(
        load1: cpu.overallLoadPercent / 100 * (cpu.perCoreLoadPercent.isEmpty ? 1 : cpu.perCoreLoadPercent.length),
        load5: 0,
        load15: 0,
        runningTasks: 0,
        totalTasks: totalTasks,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read load/process count: $e');
      return LoadSample.empty();
    }
  }

  final NativeMemoryReader _nativeMemory = NativeMemoryReader();

  @override
  Future<MemorySample> readMemory() async {
    try {
      // Fast path first: GlobalMemoryStatusEx needs no WMI round-trip
      // for the physical-memory figures at all — see
      // NativeMemoryReader's class doc for why swap intentionally
      // isn't read this way. Falls through to the full WMI query below
      // (which covers both physical memory and swap together) on any
      // failure, including the reader permanently disabling itself.
      final nativeMem = _nativeMemory.read();
      if (nativeMem != null) {
        final swap = await _readSwapUsage();
        return MemorySample(
          timestamp: DateTime.now(),
          totalKiB: nativeMem['totalKiB']!,
          usedKiB: nativeMem['usedKiB']!,
          availableKiB: nativeMem['availableKiB']!,
          cachedKiB: 0,
          swapTotalKiB: swap.$1,
          swapUsedKiB: swap.$2,
        );
      }

      final result = await _runJson(
        r'$os = Get-CimInstance Win32_OperatingSystem; '
        r'$pf = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1; '
        r'[PSCustomObject]@{ '
        r'TotalVisibleMemorySize = $os.TotalVisibleMemorySize; '
        r'FreePhysicalMemory = $os.FreePhysicalMemory; '
        r'SwapAllocatedMB = $pf.AllocatedBaseSize; '
        r'SwapUsedMB = $pf.CurrentUsage '
        r'} | ConvertTo-Json -Compress',
      );
      if (result == null) return MemorySample.empty();

      final totalKiB = _asInt(result['TotalVisibleMemorySize']) ?? 0;
      final freeKiB = _asInt(result['FreePhysicalMemory']) ?? 0;
      final swapTotalKiB = (_asInt(result['SwapAllocatedMB']) ?? 0) * 1024;
      final swapUsedKiB = (_asInt(result['SwapUsedMB']) ?? 0) * 1024;

      return MemorySample(
        timestamp: DateTime.now(),
        totalKiB: totalKiB,
        usedKiB: totalKiB - freeKiB,
        availableKiB: freeKiB,
        // Windows doesn't expose a direct "page cache size" the way
        // /proc/meminfo's Cached field does — left at 0 rather than
        // guessed; the Memory screen already treats 0 as "not shown"
        // wherever it matters.
        cachedKiB: 0,
        swapTotalKiB: swapTotalKiB,
        swapUsedKiB: swapUsedKiB,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read memory stats: $e\n$st');
      return MemorySample.empty();
    }
  }

  // The page file's *total* size, unlike its current usage, changes
  // only when someone actually resizes it — essentially never during a
  // running session. Cached far longer than a single poll tick so the
  // one remaining WMI call this method needs (only for this one number)
  // costs almost nothing amortized over a session, instead of paying
  // for it on every single readMemory() call the way the old combined
  // query did — see PdhPageFileReader's class doc in pdh_ffi.dart for
  // the full reasoning behind this split.
  int? _pageFileTotalMBCache;
  DateTime? _pageFileTotalMBCacheTime;
  static const _pageFileTotalMBCacheTtl = Duration(seconds: 60);

  Future<int> _readPageFileTotalMB() async {
    final cached = _pageFileTotalMBCache;
    final cachedAt = _pageFileTotalMBCacheTime;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _pageFileTotalMBCacheTtl) {
      return cached;
    }
    try {
      final result = await _runJson(
        r'(Get-CimInstance Win32_PageFileUsage | Select-Object -First 1).AllocatedBaseSize | ConvertTo-Json -Compress',
      );
      final freshTotalMB = _asInt(result);
      // A timed-out/failed query (freshTotalMB == null — e.g. the
      // PowerShell session was still backed up right after app launch)
      // is not the same thing as "the pagefile total is 0" — caching
      // that non-answer would pin swap total (and therefore swap used)
      // at 0 for the full minute-long TTL. On failure this instead
      // returns the last known value without touching the cache
      // timestamp, so the very next poll retries immediately rather
      // than waiting out the TTL on a value that was never observed.
      if (freshTotalMB == null) return cached ?? 0;
      _pageFileTotalMBCache = freshTotalMB;
      _pageFileTotalMBCacheTime = DateTime.now();
      return freshTotalMB;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read page file total size: $e');
      return cached ?? 0;
    }
  }

  /// Just the pagefile half of the old combined query — used when
  /// [NativeMemoryReader] already supplied the physical-memory numbers
  /// and only swap is still needed.
  Future<(int, int)> _readSwapUsage() async {
    try {
      // Fast path first: PdhPageFileReader needs no PowerShell/WMI
      // round-trip for the part that actually changes every poll (the
      // usage percentage) — only the rarely-changing total size below
      // still touches WMI, and only once a minute. Falls through to the
      // full WMI-based reading on any failure (including permanently
      // disabling itself).
      final usagePercent = _pdhPageFile.read();
      if (usagePercent != null) {
        final totalMB = await _readPageFileTotalMB();
        final totalKiB = totalMB * 1024;
        final usedKiB = (totalKiB * usagePercent / 100).round();
        return (totalKiB, usedKiB);
      }

      final result = await _runJson(
        r'Get-CimInstance Win32_PageFileUsage | Select-Object -First 1 | '
        r'Select-Object AllocatedBaseSize, CurrentUsage | ConvertTo-Json -Compress',
      );
      if (result == null) return (0, 0);
      final totalMB = _asInt(result['AllocatedBaseSize']) ?? 0;
      final usedMB = _asInt(result['CurrentUsage']) ?? 0;
      return (totalMB * 1024, usedMB * 1024);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read swap usage: $e');
      return (0, 0);
    }
  }

  // --- Disk ------------------------------------------------------------

  final NativeDiskSpaceReader _nativeDiskSpace = NativeDiskSpaceReader();

  @override
  Future<List<DiskSample>> readDisks() async {
    try {
      // Fast path first: NativeDiskSpaceReader needs no PowerShell/WMI
      // round-trip at all — see its class doc for why this matters
      // beyond just the Disk Space screen (AlertMonitorService polls
      // this every 20s for the whole app's lifetime). Falls through to
      // the WMI-based reading below on any failure (including
      // permanently disabling itself).
      final nativeDisks = _nativeDiskSpace.read();
      if (nativeDisks != null) {
        final disks = <DiskSample>[];
        for (final row in nativeDisks) {
          final total = row['totalBytes'] as int;
          final free = row['freeBytes'] as int;
          if (total == 0) continue;
          final device = row['device'] as String;
          disks.add(DiskSample(
            device: device,
            fsType: row['fsType'] as String,
            mountPoint: device,
            totalBytes: total,
            usedBytes: total - free,
            availableBytes: free,
          ));
        }
        return disks;
      }

      final result = await _runJson(
        r'Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | '
        r'Select-Object DeviceID, FileSystem, Size, FreeSpace | ConvertTo-Json -Compress',
      );
      if (result == null) return [];
      final rows = result is List ? result : [result];

      final disks = <DiskSample>[];
      for (final row in rows) {
        final total = _asInt(row['Size']);
        final free = _asInt(row['FreeSpace']);
        if (total == null || free == null || total == 0) continue;
        disks.add(DiskSample(
          device: (row['DeviceID'] as String?) ?? '?',
          fsType: (row['FileSystem'] as String?) ?? 'unknown',
          mountPoint: (row['DeviceID'] as String?) ?? '?', // e.g. "C:" — Windows has no separate mount-point concept for local drive letters
          totalBytes: total,
          usedBytes: total - free,
          availableBytes: free,
        ));
      }
      return disks;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read disk usage: $e\n$st');
      return [];
    }
  }

  bool _diskCounterReady = false;
  bool _diskCounterFailed = false;

  Future<bool> _ensureDiskCounterReady() async {
    if (_diskCounterReady) return true;
    if (_diskCounterFailed) return false;

    // A fixed '_Total' instance doesn't exist in the PhysicalDisk
    // category on every machine — observed live via the Log screen on
    // a system where the SSD sits behind a RAID-mode storage
    // controller (see readDiskHealth's own busType="RAID" for this
    // same drive): ".NET threw "Instance _Total does not exist in the
    // specified Category." Same fallback shape as
    // _ensureCpuCountersReady()'s per-core enumeration above: ask the
    // category what instances actually exist, and average across every
    // real one when '_Total' isn't among them.
    final script = r"try { "
        r"$names = @((New-Object System.Diagnostics.PerformanceCounterCategory('PhysicalDisk')).GetInstanceNames()); "
        r"if ($names -contains '_Total') { "
        r"  $global:__darktaskDiskCounters = @(New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', '% Disk Time', '_Total')); "
        r"} else { "
        r"  $real = @($names | Where-Object { $_ -ne '_Total' }); "
        r"  $global:__darktaskDiskCounters = @($real | ForEach-Object { New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', '% Disk Time', $_) }); "
        r"} "
        r"foreach ($c in $global:__darktaskDiskCounters) { $c.NextValue() | Out-Null } "
        r"Write-Output 'DARKTASK_DISK_COUNTER_OK' "
        r"} catch { Write-Output ('DARKTASK_DISK_COUNTER_ERROR: ' + $_.Exception.Message) }";

    final result = await _shell.run(script);
    final trimmed = result?.trim() ?? '';
    if (trimmed.contains('DARKTASK_DISK_COUNTER_OK')) {
      _diskCounterReady = true;
      AppLogger.instance.info(_logSource, 'Snelle schijftellers (.NET PerformanceCounter) actief.');
      return true;
    }

    _diskCounterFailed = true;
    AppLogger.instance.info(
      _logSource,
      'Kon snelle schijftellers niet initialiseren (${trimmed.isEmpty ? "geen output" : trimmed}) — '
      'valt terug op de tragere Get-CimInstance-methode voor schijfactiviteit. Dit bericht komt niet terug.',
    );
    return false;
  }

  final DiskActivityIoctlReader _ioctlDisk = DiskActivityIoctlReader();
  final PdhDiskReader _pdhDisk = PdhDiskReader();

  @override
  Future<double?> readDiskActivity() async {
    // Fastest and most reliable path first: IOCTL_DISK_PERFORMANCE read
    // directly per physical drive — see DiskActivityIoctlReader's class
    // doc for why this exists ahead of the PhysicalDisk\% Disk Time
    // counter below, which turned out to report a permanent, incorrect
    // 0% on this app's own RAID-backed test hardware.
    final ioctlValue = _ioctlDisk.read();
    if (ioctlValue != null) return ioctlValue;

    // Confirmed live on that same RAID-backed test hardware: once the
    // storage driver has told us with ERROR_INVALID_FUNCTION that it
    // doesn't implement disk-activity IOCTLs at all, EVERY
    // PhysicalDisk-category counter below is fed by that exact same
    // IOCTL under the hood — verified by a diagnostic 'Disk Bytes/sec'
    // reading that came back 0 too, not just '% Disk Time'. Continuing
    // on to those paths would only ever produce a confidently-wrong
    // 0%, so this reports "not available" (null) instead of pretending
    // to have a real number — honest beats plausible-looking-but-fake.
    if (DiskActivityIoctlReader.definitivelyUnsupported) return null;

    // Next: same reasoning as CPU's PdhCpuReader — a direct FFI reading
    // needs no PowerShell round-trip at all. Falls through to the
    // PowerShell-based paths below on any failure (including
    // PdhDiskReader permanently disabling itself).
    final pdhValue = _pdhDisk.read();
    if (pdhValue != null) return pdhValue;

    try {
      // Same reasoning and same speedup as CPU load's
      // _ensureCpuCountersReady(): the underlying WMI class here
      // (Win32_PerfFormattedData_PerfDisk_PhysicalDisk) is one of the
      // measurably-slow "*PerfFormattedData*" classes — a persistent
      // .NET PerformanceCounter talking to PDH directly, created once
      // and polled via NextValue(), avoids paying that cost every
      // single second.
      if (await _ensureDiskCounterReady()) {
        // $global:__darktaskDiskCounters is always an array now (one
        // entry for '_Total' when that instance exists, one per real
        // PhysicalDisk instance when it doesn't — see
        // _ensureDiskCounterReady's doc comment above), so a single
        // average over whatever is in it covers both cases uniformly.
        final result = await _runJson(
          r'[math]::Round(($global:__darktaskDiskCounters | ForEach-Object { $_.NextValue() } | '
          r'Measure-Object -Average).Average, 1) | ConvertTo-Json -Compress',
        );
        final value = _asDouble(result);
        if (value != null) return value.clamp(0, 100);
        // Fall through to the Get-CimInstance path if the counter
        // unexpectedly returned nothing this one time, rather than
        // giving up on disk activity for the rest of the session.
      }

      // Same '_Total' caveat as _ensureDiskCounterReady() above applies
      // to this WMI-based fallback path, so it gets the same treatment:
      // prefer the '_Total' row when the category has one, otherwise
      // average across every real (non-'_Total') row instead of
      // querying for a row that will never come back. Written with
      // Where-Object rather than -Filter "Name='_Total'" so the whole
      // script can stay a single raw string without fighting Dart's
      // rule that a raw string can't contain its own quote character.
      final result = await _runJson(
        r"$rows = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk); "
        r"$total = $rows | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1; "
        r"if ($total) { $val = $total.PercentDiskTime } else { "
        r"  $real = @($rows | Where-Object { $_.Name -ne '_Total' }); "
        r"  $val = if ($real.Count -gt 0) { ($real | Measure-Object -Property PercentDiskTime -Average).Average } else { $null } "
        r"} "
        r"$val | ConvertTo-Json -Compress",
      );
      final value = _asDouble(result);
      return value?.clamp(0, 100);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read disk activity: $e');
      return null;
    }
  }

  // --- Network ---------------------------------------------------------

  bool _netCountersReady = false;
  bool _netCountersFailed = false;
  List<String>? _netAdapterNames;
  Future<bool>? _netCountersInitInFlight;

  Future<bool> _ensureNetCountersReady() async {
    if (_netCountersReady) return true;
    if (_netCountersFailed) return false;

    // Same concurrent-caller race as _ensureCpuCountersReady above —
    // see its comment for why this in-flight guard exists.
    final inFlight = _netCountersInitInFlight;
    if (inFlight != null) return inFlight;
    final future = _initNetCounters();
    _netCountersInitInFlight = future;
    try {
      return await future;
    } finally {
      _netCountersInitInFlight = null;
    }
  }

  Future<bool> _initNetCounters() async {
    final script = r"try { "
        r"$global:__darktaskNetCounters = @{}; "
        r"$names = (New-Object System.Diagnostics.PerformanceCounterCategory('Network Interface')).GetInstanceNames(); "
        r"foreach ($n in $names) { "
        r"  $rx = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Received/sec', $n); "
        r"  $tx = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Sent/sec', $n); "
        r"  $rx.NextValue() | Out-Null; $tx.NextValue() | Out-Null; "
        r"  $global:__darktaskNetCounters[$n] = @{ rx = $rx; tx = $tx }; "
        r"} "
        // The instance names as .NET's PerformanceCounterCategory
        // returns them are exactly what's needed for the dart:ffi PDH
        // path too (see PdhNetworkReader) — Windows itself already
        // sanitizes adapter names for the performance-counter registry
        // (replacing literal '(' / ')' with '[' / ']' specifically to
        // avoid colliding with PDH's own "\Category(Instance)\Counter"
        // path syntax), so the names .NET hands back here are already
        // safe to use verbatim in a raw PDH counter path — no separate
        // escaping logic needs to be written or verified.
        r"Write-Output ('DARKTASK_NET_COUNTERS_OK:' + ($names -join '|')) "
        r"} catch { Write-Output ('DARKTASK_NET_COUNTERS_ERROR: ' + $_.Exception.Message) }";

    final result = await _shell.run(script);
    final trimmed = result?.trim() ?? '';
    if (trimmed.contains('DARKTASK_NET_COUNTERS_OK')) {
      _netCountersReady = true;
      final namesPart = trimmed.substring(trimmed.indexOf(':') + 1).trim();
      _netAdapterNames = namesPart.isEmpty ? [] : namesPart.split('|');
      AppLogger.instance.info(_logSource, 'Snelle netwerktellers (.NET PerformanceCounter) actief.');
      return true;
    }
    _netCountersFailed = true;
    AppLogger.instance.info(
      _logSource,
      'Kon snelle netwerktellers niet initialiseren (${trimmed.isEmpty ? "geen output" : trimmed}) — '
      'valt terug op de tragere Get-CimInstance-methode voor netwerksnelheid. Dit bericht komt niet terug.',
    );
    return false;
  }

  final PdhNetworkReader _pdhNetwork = PdhNetworkReader();

  @override
  Future<List<NetworkSample>> readNetwork() async {
    // Ensuring the PowerShell-derived counters/adapter-name list exists
    // first is unavoidable groundwork — the dart:ffi path below reuses
    // those exact (already-sanitized) adapter names rather than
    // duplicating Windows' own instance-name enumeration in raw FFI,
    // which would mean marshaling PDH's double-null-terminated wildcard
    // string lists — meaningfully more failure-prone than reusing a
    // list .NET has already safely produced. Once the fast path is
    // initialized (see PdhNetworkReader — all covered adapters or none,
    // deliberately no partial-adapter state), this groundwork is only
    // ever paid once per session, not every poll.
    final countersReady = await _ensureNetCountersReady();
    if (countersReady && _netAdapterNames != null) {
      final pdhSamples = _pdhNetwork.read(_netAdapterNames!);
      if (pdhSamples != null) {
        return _buildNetworkSamples(pdhSamples.entries.map((e) => (e.key, e.value.$1, e.value.$2)));
      }
    }

    try {
      // Same reasoning and same speedup as CPU load and disk activity:
      // Win32_PerfFormattedData_Tcpip_NetworkInterface is one of the
      // measurably-slow "*PerfFormattedData*" WMI classes — persistent
      // .NET PerformanceCounter objects (one pair per adapter, created
      // once) talk to PDH directly instead.
      dynamic result;
      if (countersReady) {
        result = await _runJson(
          r"$result = @{}; "
          r"foreach ($k in $global:__darktaskNetCounters.Keys) { "
          r"  $result[$k] = @{ rx = [math]::Round($global:__darktaskNetCounters[$k].rx.NextValue(), 1); tx = [math]::Round($global:__darktaskNetCounters[$k].tx.NextValue(), 1) } "
          r"} "
          r"$result | ConvertTo-Json -Compress -Depth 4",
        );
      } else {
        result = await _runJson(
          r'Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | '
          r'Select-Object Name, BytesReceivedPersec, BytesSentPersec | ConvertTo-Json -Compress',
        );
      }
      if (result == null) return [];

      final entries = <(String, double, double)>[];
      if (countersReady) {
        final map = result as Map<String, dynamic>;
        for (final entry in map.entries) {
          final v = entry.value as Map<String, dynamic>;
          entries.add((entry.key, _asDouble(v['rx']) ?? 0, _asDouble(v['tx']) ?? 0));
        }
      } else {
        final rows = result is List ? result : [result];
        for (final row in rows) {
          final name = (row['Name'] as String?) ?? '?';
          entries.add((name, _asDouble(row['BytesReceivedPersec']) ?? 0, _asDouble(row['BytesSentPersec']) ?? 0));
        }
      }
      return _buildNetworkSamples(entries);
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read network stats: $e\n$st');
      return [];
    }
  }

  /// Shared by all three network data sources (PDH-FFI, PowerShell
  /// PerformanceCounter, and the Get-CimInstance fallback) — the
  /// filtering and sorting rules don't depend on where the numbers
  /// came from, only on the adapter name and its rates.
  List<NetworkSample> _buildNetworkSamples(Iterable<(String, double, double)> entries) {
    final samples = <NetworkSample>[];
    for (final (name, rx, tx) in entries) {
      final lower = name.toLowerCase();
      // Windows' virtual/loopback/tunnel adapters show up in this
      // same list — filtered out the same way the Linux
      // implementation filters "lo"/docker/veth/etc., just matched
      // against Windows' own naming conventions instead.
      if (lower.contains('loopback') ||
          lower.contains('isatap') ||
          lower.contains('teredo') ||
          lower.contains('virtual') ||
          lower.contains('bluetooth') ||
          lower.contains('wan miniport')) {
        continue;
      }
      final type = (lower.contains('wi-fi') || lower.contains('wifi') || lower.contains('wireless'))
          ? NetworkInterfaceType.wifi
          : NetworkInterfaceType.ethernet;
      samples.add(NetworkSample(
        interfaceName: name,
        type: type,
        rxBytesPerSec: rx,
        txBytesPerSec: tx,
        // None of the three sources carry a cumulative "total bytes
        // since boot" counter the way /proc/net/dev does — 0 here
        // means "not available", not "no traffic yet".
        totalRxBytes: 0,
        totalTxBytes: 0,
      ));
    }

    samples.sort((a, b) {
      final aTotal = a.rxBytesPerSec + a.txBytesPerSec;
      final bTotal = b.rxBytesPerSec + b.txBytesPerSec;
      if (aTotal > 0 || bTotal > 0) return bTotal.compareTo(aTotal);
      return a.type == NetworkInterfaceType.ethernet ? -1 : 1;
    });
    return samples;
  }

  // --- GPU ---------------------------------------------------------------

  bool _nvidiaAbsenceLogged = false;
  Set<String> _genericGpuIds = {};
  bool _genericGpuSummaryLogged = false;
  int _genericGpuEmptyPolls = 0;

  @override
  Future<List<GpuSample>> readGpus() async {
    final results = <GpuSample>[];
    results.addAll(await _readNvidiaGpusWindows());
    results.addAll(await _readGenericGpusWindows());
    return results;
  }

  /// Identical CSV format/flags to the Linux nvidia-smi read — NVIDIA
  /// ships the same CLI on both platforms, so this is one of the few
  /// pieces of this file that's genuinely low-risk to have gotten
  /// right without a Windows machine to test on.
  Future<List<GpuSample>> _readNvidiaGpusWindows() async {
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
          loadPercent: _asDouble(parts[2]),
          memoryUsedMiB: _asDouble(parts[3]),
          memoryTotalMiB: _asDouble(parts[4]),
          temperatureC: _asDouble(parts[5]),
          powerDrawWatts: _asDouble(parts[6]),
          // clocks.current.graphics is already reported in MHz by
          // nvidia-smi — no unit conversion needed, unlike some of its
          // other fields. Only present on drivers new enough to
          // support this query field; parts.length guard below keeps
          // older drivers (7 fields, no clock) working exactly as
          // before rather than being rejected outright.
          clockMHz: parts.length > 7 ? _asDouble(parts[7]) : null,
        ));
      }
      return samples;
    } catch (e) {
      _logNvidiaAbsenceOnce('nvidia-smi not installed: $e');
      return [];
    }
  }

  void _logNvidiaAbsenceOnce(String reason) {
    if (_nvidiaAbsenceLogged) return;
    _nvidiaAbsenceLogged = true;
    AppLogger.instance.info(_logSource, 'No NVIDIA GPU detected ($reason). This message will not repeat.');
  }

  /// Logs what the Win32_VideoController scan found — once, so it's
  /// visible whether an AMD/Intel GPU was detected at all (independent
  /// of whether LibreHardwareMonitorLib is available to fill in its
  /// load/temperature) — same parity Linux's GpuSensorMixin already has
  /// via _logSysfsSummaryOnChange. Without this, a person with no LHM
  /// DLL installed had no way to tell "no GPU found by WMI at all"
  /// apart from "GPU found, just no load/temp sensor data yet".
  void _logGenericGpuSummaryOnChange(List<GpuSample> samples) {
    if (_genericGpuSummaryLogged) return;
    if (samples.isEmpty) {
      // One empty answer is not proof: at app start the video-controller
      // query can come back empty while the shared PowerShell session is
      // still busy, and the GPUs then show up a moment later. Only say
      // "no GPU" after several polls in a row found nothing.
      _genericGpuEmptyPolls++;
      if (_genericGpuEmptyPolls < 10) return;
      _genericGpuSummaryLogged = true;
      AppLogger.instance.info(_logSource, 'Win32_VideoController scan found no AMD/Intel GPU.');
      return;
    }
    _genericGpuSummaryLogged = true;
    for (final s in samples) {
      final loadStatus = s.loadPercent != null ? '${s.loadPercent!.toStringAsFixed(0)}%' : 'n/a (LHM)';
      final tempStatus = s.temperatureC == null
          ? 'n/a (LHM)'
          : '${s.temperatureC!.toStringAsFixed(0)}°C${s.temperatureIsSharedWithCpu ? ' (shared with CPU package — no separate GPU sensor)' : ''}';
      AppLogger.instance.info(
        _logSource,
        'Win32_VideoController GPU detected: ${s.name} (id=${s.id}, load=$loadStatus, temp=$tempStatus)',
      );
    }
  }

  /// Covers AMD/Intel (and NVIDIA cards nvidia-smi somehow missed) via
  /// generic WMI video-controller info for identity (name, VRAM), with
  /// load and temperature filled in via LibreHardwareMonitorLib when
  /// its DLL is present (see LibreHardwareMonitorBridge). For Intel
  /// iGPUs LibreHardwareMonitor itself doesn't expose a temperature
  /// sensor for (older pre-Xe parts especially), this falls back to
  /// the CPU package temperature — same die-sharing reasoning, and
  /// same explicit [GpuSample.temperatureIsSharedWithCpu] flag, as the
  /// equivalent Linux fallback in GpuSensorMixin.
  // Name/VRAM/PNP-ID essentially never change during a running session
  // (a GPU doesn't get swapped out live) — unlike the LHM-sourced
  // load/temperature below, which genuinely needs a fresh read every
  // poll. Caching this static half avoids a WMI round-trip every
  // single second for data that would return the exact same thing.
  // This is *not* an FFI conversion — LibreHardwareMonitorLib is a
  // managed .NET assembly, not a native C DLL, so unlike pdh.dll or
  // kernel32.dll it can't be called via dart:ffi's DynamicLibrary at
  // all; doing so would mean hosting the .NET CLR directly from Dart
  // (COM interop with mscoree.dll, AppDomain management) — a
  // meaningfully larger and riskier undertaking than anything in this
  // file, and not attempted here.
  List<Map<String, dynamic>>? _videoControllerCache;
  DateTime? _videoControllerCacheTime;
  static const _videoControllerCacheTtl = Duration(seconds: 30);

  Future<List<Map<String, dynamic>>> _getVideoControllers() async {
    final cached = _videoControllerCache;
    final cachedAt = _videoControllerCacheTime;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _videoControllerCacheTtl) {
      return cached;
    }
    final result = await _runJson(
      r'Get-CimInstance Win32_VideoController | '
      r'Select-Object Name, AdapterRAM, PNPDeviceID | ConvertTo-Json -Compress',
    );
    // `result == null` means the query timed out/failed (e.g. the
    // PowerShell session was still backed up right after app launch,
    // competing with the LibreHardwareMonitor download/install and
    // every other reader's own first-poll queries) — not "this machine
    // genuinely has no AMD/Intel GPU". Caching that as an empty result
    // would hide a real GPU from the list for the full TTL, so on
    // failure this falls back to whatever was last known (nothing, on
    // a genuine first-ever failure) *without* refreshing the cache
    // timestamp — the next poll retries immediately instead of waiting
    // out the TTL on a result that was never actually observed.
    if (result == null) return cached ?? const [];
    final rows = result is List ? result : [result];
    final typed = rows.map((r) => r as Map<String, dynamic>).toList();
    _videoControllerCache = typed;
    _videoControllerCacheTime = DateTime.now();
    return typed;
  }

  /// Last GPU sensor rows LibreHardwareMonitor produced, kept around
  /// purely so [_readLhmGpuSensors] has something honest to hand back
  /// while its very first (potentially multi-second) initialization is
  /// still running in the background — see that method's doc.
  List<Map<String, dynamic>> _lhmGpuCache = const [];
  bool _lhmGpuRefreshInFlight = false;

  /// Fast, native (no LibreHardwareMonitor, no PowerShell, no
  /// achtergronddienst) per-adapter GPU *load* reading — see
  /// [PdhGpuReader]'s class doc for how it works.
  final PdhGpuReader _pdhGpu = PdhGpuReader();

  /// Resolves [_pdhGpu]'s per-LUID load readings to adapter names via
  /// DXGI — see [DxgiAdapterNames]'s class doc, including why it's
  /// held to a materially higher verification bar than everything else
  /// in this file.
  final DxgiAdapterNames _dxgiNames = DxgiAdapterNames();

  /// Returns LibreHardwareMonitor's AMD/Intel GPU sensor rows, using
  /// the same "don't make the very first caller pay for the cold-start
  /// cost" trick already applied to CPU per-core data (see
  /// `_refreshPerCoreInBackground`'s doc for the full background on
  /// why). `LibreHardwareMonitorBridge._ensureInitialized()` is a
  /// single-flight operation: once `_lhm.status` has moved off
  /// `notChecked` (successfully or not), every future call is a plain,
  /// already-cheap PowerShell round-trip and gets awaited normally
  /// here. Only the *very first* call — which would otherwise block on
  /// LibreHardwareMonitorLib's `Add-Type`/`Computer.Open()` chain
  /// (multi-second, dominated by the PawnIO driver load and hardware
  /// enumeration, not something further reducible in code) — defers to
  /// the background instead, so the splash screen's warm-up
  /// `Future.wait` isn't held hostage by it. GPU identity (name, VRAM)
  /// from `_getVideoControllers()` above still shows up immediately
  /// either way, since that's plain WMI with no LHM dependency; only
  /// the load/temperature figures are missing for the first poll or
  /// two, exactly the same trade-off already accepted for CPU per-core
  /// data and CPU temperature (BackgroundSensorFeed).
  Future<List<Map<String, dynamic>>> _readLhmGpuSensors() async {
    if (_lhm.status != LhmStatus.notChecked) {
      return _lhm.readGpuSensors();
    }

    if (_lhmGpuRefreshInFlight) return _lhmGpuCache;
    _lhmGpuRefreshInFlight = true;
    unawaited(
      _lhm.readGpuSensors().then((rows) {
        _lhmGpuCache = rows;
      }).catchError((Object e, StackTrace st) {
        AppLogger.instance.debug(_logSource, 'Achtergrond-verversing van GPU-sensorgegevens (LHM) mislukt: $e');
      }).whenComplete(() => _lhmGpuRefreshInFlight = false),
    );
    return _lhmGpuCache;
  }

  Future<List<GpuSample>> _readGenericGpusWindows() async {
    try {
      // Real physical GPUs are always PCI devices on Windows. Anything
      // else — confirmed live: "Microsoft Remote Display Adapter",
      // PNPDeviceID starting "SWD\REMOTEDISPLAYENUM\..." — is a
      // software/virtual display adapter: Remote Desktop's own
      // indirect display driver (shows up the moment this machine is
      // used over RDP), a VNC/Parsec-style virtual display, or
      // similar. It's never real hardware to report load/temperature
      // for, so it's filtered out here before anything else — this
      // just stops it cluttering the GPU list with a permanent
      // "n/a (LHM)" entry (per-adapter PDH/DXGI attribution below no
      // longer cares how many rows there are, unlike its first version).
      final allRows = await _getVideoControllers();
      final rows = allRows.where((r) {
        final pnp = (r['PNPDeviceID'] as String?) ?? '';
        return pnp.toUpperCase().startsWith('PCI\\');
      }).toList();

      // Fetched once per readGpus() call (not per-row) — a single
      // PowerShell round-trip covers every AMD/Intel GPU at once (or,
      // on the very first call before LHM has finished initializing,
      // whatever's cached so far — see _readLhmGpuSensors's doc).
      final lhmGpus = await _readLhmGpuSensors();
      final lhmAmd = lhmGpus.where((g) => g['hardwareType'] == 'GpuAmd').toList();
      final lhmIntel = lhmGpus.where((g) => g['hardwareType'] == 'GpuIntel').toList();

      // Fast, correctly-attributed per-adapter GPU load: PdhGpuReader
      // (native, instant — see its class doc in pdh_ffi.dart) gives
      // busiest-engine load keyed by LUID; DxgiAdapterNames (see its
      // own class doc) resolves each LUID to that adapter's name.
      // Neither call does real work more than once per app session —
      // DxgiAdapterNames.resolve() is a plain cached Map after its
      // first (COM-based) call, and PdhGpuReader's own initialization
      // is likewise one-time — so this costs nothing per poll beyond a
      // fast PDH query. Joined into a name-keyed map once here, then
      // matched per-row below the same substring-tolerant way the LHM/
      // achtergronddienst matching already works, since DXGI's and
      // WMI's names for the same physical card can differ slightly
      // just like LHM's do.
      final luidToName = _dxgiNames.resolve();
      final loadByLuid = (luidToName != null) ? _pdhGpu.readByAdapter() : null;
      Map<String, double>? pdhLoadByDescription;
      if (luidToName != null && loadByLuid != null) {
        pdhLoadByDescription = {};
        for (final entry in loadByLuid.entries) {
          final description = luidToName[entry.key];
          if (description != null) {
            pdhLoadByDescription[description.toLowerCase()] = entry.value;
          }
        }
      }

      // Same DXGI source as the load attribution above, this time for
      // VRAM size — see DxgiAdapterNames.resolveVram()'s doc for why:
      // WMI's AdapterRAM is a known-unreliable 32-bit field that wraps
      // or reports garbage for any card with 4GB+ of dedicated memory,
      // while DXGI's DedicatedVideoMemory has no such ceiling. Built
      // the same name-keyed way as pdhLoadByDescription above (and
      // deliberately reuses luidToName rather than re-resolving DXGI —
      // resolve()/resolveVram() share one cached enumeration).
      final vramByLuid = luidToName != null ? _dxgiNames.resolveVram() : null;
      Map<String, int>? dxgiVramByDescription;
      if (luidToName != null && vramByLuid != null) {
        dxgiVramByDescription = {};
        for (final entry in vramByLuid.entries) {
          final description = luidToName[entry.key];
          if (description != null) {
            dxgiVramByDescription[description.toLowerCase()] = entry.value;
          }
        }
      }

      // Checked once per call, reused for every row below — see the
      // temperature-assignment comments further down for why this is
      // preferred over the LHM/PowerShell path when available.
      final backgroundFeed = await _backgroundFeed.readFeed();

      final samples = <GpuSample>[];
      var amdIndex = 0;
      var intelIndex = 0;
      // Lazily fetched at most once per readGpus() call, and reused if
      // more than one Intel GPU needs the die-shared-temperature
      // fallback below — avoids redundant PowerShell round-trips for
      // what would always be the same CPU reading within one call.
      Map<String, double?>? lhmCpuCache;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final name = (row['Name'] as String?) ?? 'Unknown GPU';
        final lowerName = name.toLowerCase();
        // Skip NVIDIA entries here — already covered (with real load
        // and temp data) by nvidia-smi above; listing the same
        // physical card twice with worse data would be confusing.
        if (lowerName.contains('nvidia') || lowerName.contains('geforce') || lowerName.contains('quadro')) {
          continue;
        }
        final pnpId = (row['PNPDeviceID'] as String?) ?? '';
        final vendor = lowerName.contains('amd') || lowerName.contains('radeon')
            ? GpuVendor.amd
            : (lowerName.contains('intel') ? GpuVendor.intel : GpuVendor.unknown);

        // Prefer DXGI's VRAM figure over WMI's AdapterRAM when this row
        // can be matched to a DXGI adapter (same substring-tolerant
        // matching as pdhLoadByDescription above) — see
        // DxgiAdapterNames.resolveVram()'s doc for why WMI's own value
        // can't be trusted on its own for cards with 4GB+ of VRAM. Any
        // row that can't be matched (or where DXGI reported exactly 0,
        // itself a sign this specific adapter wasn't matched correctly)
        // keeps the original WMI value unchanged — this is additive,
        // never a regression from what WMI already reported.
        var ramBytes = _asInt(row['AdapterRAM']);
        if (dxgiVramByDescription != null) {
          for (final entry in dxgiVramByDescription.entries) {
            if (entry.key.contains(lowerName) || lowerName.contains(entry.key)) {
              if (entry.value > 0) ramBytes = entry.value;
              break;
            }
          }
        }

        // Best-effort pairing between WMI's Win32_VideoController list
        // and LibreHardwareMonitor's own hardware list: the two don't
        // share a common ID, and their reported names can differ
        // slightly for the same physical card (e.g. WMI's "AMD Radeon
        // RX 580" vs LHM's "AMD Radeon RX 580 Graphics"), so this
        // matches positionally within the same vendor type — correct
        // for the overwhelmingly common single-GPU-per-vendor case,
        // and still better than nothing on rarer multi-GPU-same-vendor
        // setups even if a pairing occasionally lands on the wrong
        // card there.
        Map<String, dynamic>? lhmMatch;
        if (vendor == GpuVendor.amd && amdIndex < lhmAmd.length) {
          lhmMatch = lhmAmd[amdIndex++];
        } else if (vendor == GpuVendor.intel && intelIndex < lhmIntel.length) {
          lhmMatch = lhmIntel[intelIndex++];
        }

        // Deliberately null (not 0) when neither the feed nor an LHM
        // match has a reading — 0% load would be a specific, false
        // claim; null honestly means "not measured".
        var gpuTempC = lhmMatch?['temperatureC'] as double?;
        var gpuLoadPercent = lhmMatch?['loadPercent'] as double?;
        var tempSharedWithCpu = false;

        // Prefer the background feed's own temperature/load for this
        // GPU when available — same preference order as readCpu()/
        // readCpuPowerWatts() above, and same reasoning: no PowerShell
        // round-trip needed at all, no re-elevation needed either. This
        // is what keeps GPU load/temperature from visibly "trickling
        // in" a couple of seconds after startup the way it used to —
        // when the background service is set up, both numbers come
        // straight out of the feed file (already-fresh, sub-second),
        // and the main process's own LibreHardwareMonitor instance
        // (still initializing in the background at this point; see
        // _readLhmGpuSensors's doc) never ends up mattering for the
        // very first read at all. Matched by substring rather than
        // exact equality since WMI and LHM/the feed can report
        // slightly different names for the same physical card (e.g.
        // "AMD Radeon RX 580" vs "AMD Radeon RX 580 Graphics") — the
        // same tolerance the positional lhmMatch pairing above already
        // assumes implicitly.
        if (backgroundFeed != null) {
          final feedGpus = backgroundFeed['gpus'] as List<dynamic>?;
          if (feedGpus != null) {
            for (final g in feedGpus) {
              final feedName = (g as Map<String, dynamic>)['name'] as String?;
              if (feedName != null &&
                  (feedName.toLowerCase().contains(lowerName) || lowerName.contains(feedName.toLowerCase()))) {
                final feedTemp = _asDouble(g['tempC']);
                if (feedTemp != null) gpuTempC = feedTemp;
                final feedLoad = _asDouble(g['loadPercent']);
                if (feedLoad != null) gpuLoadPercent = feedLoad;
                break;
              }
            }
          }
        }

        // Fast native PDH+DXGI reading wins over both LHM and the
        // background feed when this specific row could be matched to
        // a DXGI-reported adapter name — see pdhLoadByDescription's
        // computation above. Matched by substring both ways, same
        // tolerance as the background-feed matching just above (DXGI
        // and WMI can report slightly different names for the same
        // physical card). Unlike temperature, this needs no
        // achtergronddienst setup at all — works from the very first
        // launch, on any number of real GPUs.
        if (pdhLoadByDescription != null) {
          for (final entry in pdhLoadByDescription.entries) {
            if (entry.key.contains(lowerName) || lowerName.contains(entry.key)) {
              gpuLoadPercent = entry.value;
              break;
            }
          }
        }

        if (gpuTempC == null && vendor == GpuVendor.intel) {
          // Most integrated Intel GPUs share a die with the CPU and
          // have no separate thermal sensor of their own — especially
          // true for older, pre-Xe iGPUs (like HD/UHD Graphics 5xx-6xx
          // series) that LibreHardwareMonitor's own maintainers have
          // noted get thinner sensor coverage than newer Intel/AMD
          // parts. The CPU package temperature (already fetched via
          // LHM for readCpu()) covers the whole die, GPU included —
          // using it here is honest, not a guess, same reasoning and
          // same explicit flag as the equivalent Linux fallback in
          // GpuSensorMixin.
          final feedCpuTemp = _asDouble(backgroundFeed?['cpuTempC']);
          if (feedCpuTemp != null) {
            gpuTempC = feedCpuTemp;
            tempSharedWithCpu = true;
          } else {
            final lhmCpu = lhmCpuCache ??= await _lhm.readCpuSensors();
            gpuTempC = lhmCpu?['temperatureC'];
            tempSharedWithCpu = gpuTempC != null;
          }
        }

        samples.add(GpuSample(
          id: pnpId.isNotEmpty ? pnpId : 'gpu$i',
          timestamp: DateTime.now(),
          name: name,
          vendor: vendor,
          loadPercent: gpuLoadPercent,
          memoryTotalMiB: ramBytes != null && ramBytes > 0 ? ramBytes / 1048576 : null,
          temperatureC: gpuTempC,
          // Uses _asDouble() (num-tolerant) rather than a direct cast,
          // even though LHM's own readGpuSensors() already normalizes
          // these via .toDouble() before this point — matching this
          // file's established defensive style rather than assuming
          // that normalization can never change upstream.
          powerDrawWatts: _asDouble(lhmMatch?['powerWatts']),
          clockMHz: _asDouble(lhmMatch?['clockMHz']),
          temperatureIsSharedWithCpu: tempSharedWithCpu,
          // NVIDIA fan speed (via nvidia-smi, in _readNvidiaGpusWindows
          // above) is reported as a PERCENTAGE of max fan speed, not
          // RPM — a different unit that doesn't belong in this same
          // field, so that path deliberately leaves fanRpm null rather
          // than mislabeling a % as RPM. LHM's AMD/Intel reading here
          // is genuinely RPM.
          fanRpm: _asDouble(lhmMatch?['fanRpm'])?.round(),
        ));
      }
      _genericGpuIds = samples.map((s) => s.id).toSet();
      // Only let the one-shot summary latch once a *genuine*
      // Win32_VideoController answer has been observed at least once
      // (_videoControllerCacheTime is only ever set on real success —
      // see _getVideoControllers's doc) — otherwise an empty result
      // from a transient PowerShell timeout on the very first poll
      // (e.g. while busy downloading LibreHardwareMonitor at startup)
      // would permanently log "no AMD/Intel GPU found" even though the
      // very next poll finds them fine.
      if (_videoControllerCacheTime != null) {
        _logGenericGpuSummaryOnChange(samples);
      }
      return samples;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read Win32_VideoController: $e\n$st');
      return [];
    }
  }

  @override
  Map<String, GpuDiagnostic> get gpuDiagnostics {
    // Only relevant for AMD/Intel GPUs, whose load/temperature depend
    // on LibreHardwareMonitorLib being present and loaded — NVIDIA
    // cards (covered by nvidia-smi) never need this fix, so they never
    // get an entry here regardless of LHM's status.
    if (_genericGpuIds.isEmpty) return const {};

    switch (_lhm.status) {
      case LhmStatus.dllMissing:
        return {
          for (final id in _genericGpuIds)
            id: const GpuDiagnostic(
              kind: GpuDiagnosticKind.toolMissing,
              message: 'LibreHardwareMonitorLib.dll ontbreekt — belasting/temperatuur voor deze GPU '
                  'zijn hierdoor niet beschikbaar.',
            ),
        };
      case LhmStatus.initFailed:
        // Not offered as a one-click fix: the DLL is already present
        // but failed to load, most often because the app isn't running
        // elevated — an in-app button can't restart the process as
        // Administrator on its own, so this stays informational
        // (visible via the Log screen) rather than an actionable
        // button that would need to lie about what it can do.
        return {
          for (final id in _genericGpuIds)
            id: const GpuDiagnostic(
              kind: GpuDiagnosticKind.unknown,
              message: 'LibreHardwareMonitorLib.dll gevonden maar laden mislukt — vaak opgelost door '
                  'DarkTask als Administrator te starten. Zie de Log-tab voor details.',
            ),
        };
      case LhmStatus.ok:
      case LhmStatus.notChecked:
        return const {};
    }
  }

  @override
  void disposeIntelGpuTop() {
    // No separate "GPU-only" background process on this first-pass
    // Windows implementation — the shared PowerShellSession(s) back
    // every sensor, not just GPU. Reusing this interface method (rather
    // than adding a Windows-only lifecycle method the app shell would
    // need a type-check to call) as the single place that stops it, so
    // `app.dart` can clean up whichever platform's persistent
    // background process is running without knowing which OS it's on.
    // Both sessions are stopped — [_lhmShell] (added 2026-09-22, see
    // this class's own doc comment) is just as much a live
    // `powershell.exe` process as [_shell] and would otherwise be left
    // running past the app's own lifetime.
    _shell.dispose();
    _lhmShell.dispose();
  }

  @override
  Future<bool> fixIntelGpuPermission() async => false;

  /// Downloads and installs LibreHardwareMonitorLib.dll — the Windows
  /// equivalent of the Linux "install this optional tool" action,
  /// triggered the same way (an explicit button click in the GPU
  /// detail panel), never automatically. See
  /// [LibreHardwareMonitorBridge.downloadAndInstall] for exactly what
  /// this does and why it isn't silent.
  @override
  Future<bool> installIntelGpuTools() => _lhm.downloadAndInstall();

  /// See [LibreHardwareMonitorBridge.pawnIoConfirmedMissing] — narrows
  /// the generic "CPU temperature blocked despite elevation" symptom
  /// down to the one specific, confirmed cause this app can actually
  /// offer a fix for.
  @override
  bool get pawnIoConfirmedMissing => _lhm.pawnIoConfirmedMissing;

  /// See [LibreHardwareMonitorBridge.installPawnIo] for exactly what
  /// this does (downloads the official, signature-verified PawnIO
  /// installer and runs it) and why it isn't silent — same reasoning
  /// as [installIntelGpuTools], one trust-level higher.
  @override
  Future<bool> installPawnIo() => _lhm.installPawnIo();

  // Guards autoProvisionSensorDependencies() to at most one real
  // attempt per app launch — readCpu() (used below to force an init
  // attempt) is polled every second by every open screen, so without
  // this a naive "check status, act if needed" would just re-run on
  // every single poll tick for as long as something stayed missing
  // (e.g. no internet at the exact moment of launch).
  bool _autoProvisionAttempted = false;

  /// See [SystemSensorService.autoProvisionSensorDependencies] for the
  /// full reasoning behind what this does and why it's conditioned on
  /// already running elevated. Three steps, each independently gated
  /// on its own precondition still being true (so e.g. a machine that
  /// only needs PawnIO, not the DLL, doesn't get an unnecessary DLL
  /// re-download attempt first) and each logged exactly the way the
  /// equivalent manual button already logs it, via the very same
  /// methods (`installIntelGpuTools`, `installPawnIo`,
  /// `setupBackgroundSensorFeed`) the buttons call:
  ///
  /// Architecture note, added 2026-09-13: this is one of three
  /// independent triggers that can call `installPawnIo()`/
  /// `setupBackgroundSensorFeed()` without coordinating with each
  /// other first — the other two are the manual buttons in
  /// PerformanceScreen (`_installPawnIo`/`_setupBackgroundFeed`, a
  /// deliberate user action) and the mid-session self-heal check in
  /// `LibreHardwareMonitorBridge.readCpuSensors()` (gated on its own
  /// `_attemptedAutoPawnIoInstall`, guarding against exactly the case
  /// this method's own `_autoProvisionAttempted` can't: PawnIO going
  /// missing *during* a session rather than only at launch — see that
  /// method's doc for the full reasoning and a reproduced example).
  /// Deliberately NOT merged into one shared "auto-install" gate: each
  /// of the three has a genuinely different precondition (elevated at
  /// launch / explicit user click / confirmed-missing mid-session) and
  /// merging them would mean picking one, weakening the others. What
  /// actually matters — that none of the three can ever run a second,
  /// colliding install/setup concurrently with another — is instead
  /// guaranteed structurally, because all three ultimately call
  /// through the same two mutex-guarded public methods
  /// (`installPawnIo`/`setupBackgroundSensorFeed`, both in this file
  /// and in `LibreHardwareMonitorBridge`): whichever trigger gets
  /// there first starts the real work, and any other trigger that
  /// fires while it's still running just awaits that same in-flight
  /// `Future` instead of starting a second one. Confirmed live: this
  /// is what fixed a real collision between two of these three
  /// triggers, reproduced on real hardware before the mutex existed.
  ///
  /// 1. `readCpu()` — the same call `warmUpSensors()` already makes,
  ///    awaited here so `_lhm.status`/`pawnIoConfirmedMissing` reflect
  ///    a real attempt rather than their unset defaults. If the DLL
  ///    turns out to be missing, `installIntelGpuTools()` downloads
  ///    it, then `readCpu()` runs once more so the newly-installed DLL
  ///    is actually loaded before the PawnIO check below runs against
  ///    current information instead of stale pre-install state.
  /// 2. If `pawnIoConfirmedMissing`, `installPawnIo()` — signature
  ///    verification and post-install re-verification happen inside
  ///    that method exactly as they do for the button; nothing about
  ///    its trust checks is skipped or weakened here.
  /// 3. If the background sensor feed isn't already active,
  ///    `setupBackgroundSensorFeed()` — registers the scheduled task
  ///    that avoids a cold LibreHardwareMonitor start on every future
  ///    launch. Its own `-Verb RunAs` elevation request is a silent
  ///    no-op UAC-wise when the parent process (this one) is already
  ///    elevated, consistent with everything else this method does.
  @override
  Future<void> autoProvisionSensorDependencies() async {
    if (_autoProvisionAttempted) return;
    _autoProvisionAttempted = true;

    if (NativeElevationCheck.isElevated() != true) {
      AppLogger.instance.debug(
        _logSource,
        'Automatische installatie van sensorafhankelijkheden overgeslagen — dit proces draait niet '
        'verhoogd (als Administrator). De bestaande knoppen (GPU-detail, CPU-detail, achtergronddienst) '
        'werken nog gewoon handmatig.',
      );
      return;
    }

    try {
      await readCpu().catchError((_) => CpuSample.empty());

      if (_lhm.status == LhmStatus.dllMissing) {
        AppLogger.instance.info(
          _logSource,
          'Automatisch installeren: LibreHardwareMonitorLib.dll ontbreekt — download wordt gestart '
          '(proces draait al verhoogd, dus geen apart knopje nodig).',
        );
        final installed = await installIntelGpuTools();
        if (installed) {
          // Force a fresh init against the just-installed DLL so the
          // PawnIO check right below sees current state, not whatever
          // _lhm.status/pawnIoConfirmedMissing were before it existed.
          await readCpu().catchError((_) => CpuSample.empty());
        }
      }

      if (pawnIoConfirmedMissing) {
        AppLogger.instance.info(
          _logSource,
          'Automatisch installeren: PawnIO-driver ontbreekt — stille installatie wordt gestart '
          '(proces draait al verhoogd, dus geen apart knopje nodig).',
        );
        await installPawnIo();
        // Same reasoning as the DLL-install branch above: a successful
        // installPawnIo() resets the bridge's _initFuture/_status back
        // to notChecked/dllMissing-or-ok-unknown so the *next* real
        // sensor read reflects the just-installed driver — but that
        // also means _lhm.loadedDllPath (read by
        // setupBackgroundSensorFeed() below, via the fallbackDllPath it
        // passes through) goes back to null the instant this line
        // returns, even though the DLL itself never went anywhere.
        // Reproduced live: this step's own success log line was
        // immediately followed by "achtergronddienst... niet gelukt:
        // LibreHardwareMonitorLib.dll is nog niet gedownload" — not
        // because the DLL was missing, but because nothing had
        // re-triggered _doInitialize() yet to repopulate that path
        // before the background-service step ran against it.
        await readCpu().catchError((_) => CpuSample.empty());
      }

      if (!await isBackgroundSensorFeedActive()) {
        AppLogger.instance.info(
          _logSource,
          'Automatisch installeren: achtergronddienst nog niet actief — wordt nu ingesteld '
          '(proces draait al verhoogd, dus geen apart knopje nodig).',
        );
        final error = await setupBackgroundSensorFeed();
        if (error != null) {
          // Added 2026-09-13, reproduced live: registration itself
          // (`Register-ScheduledTask`, the UAC-gated step that can
          // genuinely fail — declined prompt, a real permissions
          // problem) already succeeded by the time this specific message
          // can occur; this one only means the post-registration data
          // poll ran out of patience. Reproduced live, twice, on the
          // same machine: the task was in fact running fine moments
          // later on its own, once something (a later isActive()/
          // readFeed() check — the next app launch, say) checked again
          // without redoing this whole setup dance. Logging that as a
          // scary ERROR when the automatic, unattended path hits it is
          // misleading — nothing actually failed to install, it just
          // hasn't produced its first reading yet — so this one specific
          // message logs as informational here. The manual "Installeer"
          // button in the UI still surfaces the exact same string as a
          // real, visible error, since a person who explicitly asked for
          // this and is watching it happen deserves to know it's stuck,
          // not just told to wait.
          AppLogger.instance.info(
              _logSource, 'Automatisch instellen van de achtergronddienst: $error');
        }
      }
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Automatische installatie van sensorafhankelijkheden mislukt: $e');
    }
  }

  // --- Battery -----------------------------------------------------------

  final NativeBatteryReader _nativeBattery = NativeBatteryReader();
  final NativeUptimeReader _nativeUptime = NativeUptimeReader();

  // Design capacity never changes, and full-charge capacity only ever
  // drifts slowly over months as a battery wears — cached
  // indefinitely once successfully read (not on a short TTL like the
  // fast-changing sensors elsewhere in this file), so this WMI
  // round-trip only ever happens once per app session rather than on
  // every single battery poll. Read from `root\wmi`'s ACPI battery
  // classes specifically — the same ones `powercfg /batteryreport`
  // itself reads from — not `Win32_Battery`, which doesn't reliably
  // expose these on many systems.
  ({double designMWh, double fullChargeMWh, int? cycleCount})? _batteryHealthCache;
  bool _batteryHealthReadAttempted = false;

  Future<({double designMWh, double fullChargeMWh, int? cycleCount})?> _readBatteryHealthWindows() async {
    if (_batteryHealthCache != null) return _batteryHealthCache;
    if (_batteryHealthReadAttempted) return null;
    _batteryHealthReadAttempted = true;

    // Tried first: talks directly to the battery's miniclass driver,
    // bypassing root\wmi's BatteryStaticData/BatteryFullChargedCapacity
    // classes entirely — the classes with the confirmed firmware bug
    // documented below. Only falls through to that WMI-based path when
    // this direct read fails outright (not a mismatch/bug detection,
    // an actual failure to get any data at all).
    final direct = _batteryIoctl.readBatteryInformation();
    if (direct != null && direct.designCapacityMWh != direct.fullChargeCapacityMWh) {
      final health = (
        designMWh: direct.designCapacityMWh.toDouble(),
        fullChargeMWh: direct.fullChargeCapacityMWh.toDouble(),
        cycleCount: direct.cycleCount,
      );
      _batteryHealthCache = health;
      AppLogger.instance.info(
        _logSource,
        'Batterijgezondheid: directe IOCTL-uitlezing gelukt '
        '(${direct.designCapacityMWh} mWh ontwerp, ${direct.fullChargeCapacityMWh} mWh vol, '
        '${direct.cycleCount ?? '?'} cycli).',
      );
      return health;
    }

    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | '
            r'Select-Object -First 1).DesignedCapacity; '
            r'$full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | '
            r'Select-Object -First 1).FullChargedCapacity; '
            r'$cycles = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | '
            r'Select-Object -First 1).CycleCount; '
            r'[PSCustomObject]@{ design = $design; full = $full; cycles = $cycles } | ConvertTo-Json -Compress',
      ]);
      if (result.exitCode != 0) return null;
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return null;

      final decoded = jsonDecode(output) as Map<String, dynamic>;
      final design = _asDouble(decoded['design']);
      final full = _asDouble(decoded['full']);
      if (design == null || full == null || design <= 0) return null;

      // A confirmed firmware bug on some laptop models (documented in
      // multiple real-world reports, HP ProBooks among them):
      // BatteryStaticData.DesignedCapacity and
      // BatteryFullChargedCapacity.FullChargedCapacity return the
      // *exact same* value — meaning the health ratio always comes out
      // to precisely 100%, regardless of the battery's real condition,
      // because the two WMI classes are effectively reporting the same
      // underlying number rather than two genuinely different
      // measurements. Detected here as "no reliable data" rather than
      // shown as a false, always-100% health reading — an old,
      // visibly-used battery reporting exactly 100% is itself the tell.
      // (The direct IOCTL path above is tried first specifically to
      // avoid this bug entirely; this check only matters when that
      // direct path itself wasn't available.)
      if (design == full) {
        AppLogger.instance.debug(
          _logSource,
          'Batterijgezondheid genegeerd: DesignedCapacity en FullChargedCapacity zijn identiek '
          '($design mWh) — bekend firmware-euvel op sommige laptopmodellen, geen echte meting.',
        );
        return null;
      }

      final health = (designMWh: design, fullChargeMWh: full, cycleCount: _asInt(decoded['cycles']));
      _batteryHealthCache = health;
      return health;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read battery health (root\\wmi): $e');
      return null;
    }
  }

  @override
  Future<BatteryEnergySample?> readBatteryEnergy() async {
    try {
      final status = _batteryIoctl.readBatteryStatus();
      if (status == null) return null;
      final health = await _readBatteryHealthWindows();
      final discharging = (status.powerState & 0x2) != 0; // BATTERY_DISCHARGING
      final rate = status.rateMW;
      return BatteryEnergySample(
        remainingMWh: status.capacityMWh.toDouble(),
        fullChargeMWh: health?.fullChargeMWh,
        drawMW: (discharging && rate != null && rate != 0) ? rate.abs().toDouble() : null,
        discharging: discharging,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Batterij-energie uitlezen mislukt: $e');
      return null;
    }
  }

  @override
  Future<BatterySample> readBattery() async {
    // Fast path first: GetSystemPowerStatus needs no WMI round-trip at
    // all. A non-null result here is authoritative either way — a
    // machine with genuinely no battery returns {'present': false},
    // which is the correct final answer, not a reason to fall through
    // to WMI. Only a null result (the reader unusable/disabled) falls
    // back below.
    final nativeBattery = _nativeBattery.read();
    if (nativeBattery != null) {
      final present = nativeBattery['present'] as bool;
      final health = present ? await _readBatteryHealthWindows() : null;
      return BatterySample(
        present: present,
        capacityPercent: nativeBattery['capacityPercent'] as int?,
        status: nativeBattery['status'] as String?,
        designCapacityMWh: health?.designMWh,
        fullChargeCapacityMWh: health?.fullChargeMWh,
        cycleCount: health?.cycleCount,
      );
    }

    try {
      final result = await _runJson(
        r'Get-CimInstance Win32_Battery | Select-Object EstimatedChargeRemaining, BatteryStatus | ConvertTo-Json -Compress',
      );
      if (result == null) return BatterySample.absent();
      final row = result is List ? (result.isEmpty ? null : result.first) : result;
      if (row == null) return BatterySample.absent();

      final capacity = _asInt(row['EstimatedChargeRemaining']);
      // Win32_Battery.BatteryStatus: 1=Discharging, 2=AC/On-line
      // (effectively "not on battery"), 3=Fully Charged, 6/7/8/9=
      // various charging states. Mapped to the same status strings the
      // Linux side uses ("Charging"/"Discharging"/"Full") so
      // BatterySample.isDischarging works identically on both
      // platforms without callers needing to know which OS they're on.
      final statusCode = _asInt(row['BatteryStatus']);
      String? status;
      switch (statusCode) {
        case 1:
          status = 'Discharging';
          break;
        case 2:
          status = 'AC';
          break;
        case 3:
          status = 'Full';
          break;
        case 6:
        case 7:
        case 8:
        case 9:
          status = 'Charging';
          break;
        default:
          status = null;
      }

      final health = await _readBatteryHealthWindows();
      return BatterySample(
        present: true,
        capacityPercent: capacity,
        status: status,
        designCapacityMWh: health?.designMWh,
        fullChargeCapacityMWh: health?.fullChargeMWh,
        cycleCount: health?.cycleCount,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read battery state: $e');
      return BatterySample.absent();
    }
  }

  // --- System info ---------------------------------------------------

  @override
  Future<SystemInfoSample> readSystemInfo() async {
    try {
      // The (near-instant, dart:ffi GetTickCount64) uptime read doesn't
      // depend on anything the PowerShell script below produces, so it
      // happens first rather than after awaiting that script — purely
      // for honesty in the log: NativeUptimeReader's one-time
      // "actief"-message used to print only once this whole method's
      // slow script had finished, which read (misleadingly) like the
      // uptime reader itself was slow to initialize. It isn't; see the
      // comment on the script below for what actually is.
      final nativeUptime = _nativeUptime.read();

      // Deliberately its own fresh, one-off `powershell.exe` process
      // (same reasoning as readDiskHealth()'s Get-PhysicalDisk query)
      // rather than going through the shared, persistent
      // [PowerShellSession] every other sensor read here relies on.
      // This script alone chains five separate WMI/CIM round-trips
      // (OperatingSystem, ComputerSystem, Processor, BIOS, and three
      // more for the process-ancestry walk below) — independently
      // measured at upward of a second combined even on its own, and
      // this method is only ever called once at startup (via
      // warmUpSensors's background prefetch) plus every few seconds
      // from the System Info/Performance screens, never from the
      // ~1s-cadence live polling loops. Routing it through the shared
      // session anyway meant it could sit queued in that session's FIFO
      // right behind whatever else happened to be warming up at the
      // same moment (LibreHardwareMonitor's Add-Type/Computer.Open(),
      // the CPU per-core counters, ...) — from the outside that looked
      // exactly like an unexplained ~1.2s stall "around" the uptime
      // reader in the startup log, when the actual cause was this
      // script queued behind unrelated work on a session it never
      // needed to share in the first place. Running it standalone means
      // its own genuine WMI cost stays exactly what it is, without also
      // blocking (or being blocked by) every other sensor.
      final processResult = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$os = Get-CimInstance Win32_OperatingSystem; '
            r'$cs = Get-CimInstance Win32_ComputerSystem; '
            r'$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1; '
            r'$bios = Get-CimInstance Win32_BIOS; '
            // Windows' desktop shell isn't user-swappable the way a Linux
            // desktop environment is, but it *is* genuinely configurable
            // (registry) rather than hardcoded — reading the actual value
            // rather than assuming "Explorer" covers the rare case of a
            // custom shell replacement correctly, and still gives a real,
            // specific answer in the overwhelmingly common case.
            r'$shellPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" '
            r'-Name Shell -ErrorAction SilentlyContinue).Shell; '
            // Walking one step up the parent-process chain finds what
            // actually launched this app — PowerShell, Command Prompt,
            // Windows Terminal, or File Explorer (a double-click) — the
            // closest real Windows equivalent to "which shell is the user
            // running this from," since Windows has no persistent
            // $SHELL-style environment variable naming an interactive
            // shell the way Linux does.
            // Two levels up, not one: $PID here is this one-off
            // PowerShell process's own process (which DarkTask itself
            // just spawned for this single query) — its immediate parent
            // is darktask.exe, not whatever actually launched DarkTask,
            // exactly as it was when this ran through the persistent
            // shared session instead (any powershell.exe DarkTask spawns
            // is equally a direct child of darktask.exe, so this walk is
            // unaffected by which PowerShell process happens to run it).
            // The process that matters is darktask.exe's own parent:
            // PowerShell, Command Prompt, Windows Terminal, or File
            // Explorer (a double-click).
            r'$psProc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"; '
            r'$darktaskProc = if ($psProc) { Get-CimInstance Win32_Process -Filter ("ProcessId=" + $psProc.ParentProcessId) } else { $null }; '
            r'$launcherProc = if ($darktaskProc) { Get-CimInstance Win32_Process -Filter ("ProcessId=" + $darktaskProc.ParentProcessId) } else { $null }; '
            r'[PSCustomObject]@{ '
            r'Hostname = $cs.Name; '
            r'OsCaption = $os.Caption; '
            r'OsVersion = $os.Version; '
            r'OsArchitecture = $os.OSArchitecture; '
            r'LastBootUpTime = $os.LastBootUpTime; '
            r'CpuName = $cpu.Name; '
            r'CpuCores = $cpu.NumberOfLogicalProcessors; '
            r'TotalPhysicalMemory = $cs.TotalPhysicalMemory; '
            r'Manufacturer = $cs.Manufacturer; '
            r'Model = $cs.Model; '
            r'BiosVersion = $bios.SMBIOSBIOSVersion; '
            r'BiosDate = $bios.ReleaseDate; '
            r'ShellPath = $shellPath; '
            r'ParentProcessName = $launcherProc.Name '
            r'} | ConvertTo-Json -Compress',
      ]);

      if (processResult.exitCode != 0) {
        AppLogger.instance.error(
          _logSource,
          'Systeeminfo-opvraging (powershell.exe) gaf exitcode ${processResult.exitCode}: ${processResult.stderr}',
        );
        return SystemInfoSample.unknown();
      }
      final rawOutput = (processResult.stdout as String).trim();
      if (rawOutput.isEmpty) return SystemInfoSample.unknown();

      dynamic result;
      try {
        result = jsonDecode(rawOutput);
      } catch (e) {
        AppLogger.instance.debug(_logSource, 'Failed to parse system info JSON: $e\nOutput was: $rawOutput');
        return SystemInfoSample.unknown();
      }
      if (result == null) return SystemInfoSample.unknown();

      Duration uptime = Duration.zero;
      if (nativeUptime != null) {
        uptime = nativeUptime;
      } else {
        final bootTimeRaw = result['LastBootUpTime']?.toString();
        if (bootTimeRaw != null) {
          // CIM DateTime over PowerShell's ConvertTo-Json typically
          // serializes as a .NET "/Date(ms)/" string or an ISO string
          // depending on PowerShell version — handled defensively since
          // this is exactly the kind of formatting detail that's hard to
          // get right without a real machine to check against. Only
          // reached if NativeUptimeReader (see its class doc) isn't
          // usable, which sidesteps this ambiguity entirely.
          final msMatch = RegExp(r'/Date\((\d+)\)/').firstMatch(bootTimeRaw);
          DateTime? bootTime;
          if (msMatch != null) {
            bootTime = DateTime.fromMillisecondsSinceEpoch(int.parse(msMatch.group(1)!));
          } else {
            bootTime = DateTime.tryParse(bootTimeRaw);
          }
          if (bootTime != null) uptime = DateTime.now().difference(bootTime);
        }
      }

      final gpus = await readGpus();

      return SystemInfoSample(
        hostname: _nativeSystemInfo.readHostname() ?? (result['Hostname'] as String?) ?? Platform.localHostname,
        osName: (result['OsCaption'] as String?)?.trim() ?? 'Windows',
        kernelVersion: (result['OsVersion'] as String?) ?? 'onbekend',
        architecture: (result['OsArchitecture'] as String?) ?? 'onbekend',
        uptime: uptime,
        cpuModel: (result['CpuName'] as String?)?.trim() ?? 'onbekend',
        cpuCores: _asInt(result['CpuCores']) ?? 0,
        totalMemoryGiB: (_asInt(result['TotalPhysicalMemory']) ?? 0) / (1024 * 1024 * 1024),
        gpuNames: gpus.map((g) => g.name).toList(),
        systemVendor: result['Manufacturer'] as String?,
        systemModel: result['Model'] as String?,
        biosVersion: result['BiosVersion'] as String?,
        biosDate: result['BiosDate'] as String?,
        // Windows' desktop shell isn't user-swappable the way a Linux
        // desktop environment is — it's "Windows Verkenner (Explorer)"
        // on the overwhelming majority of systems — but it genuinely
        // is configurable (the registry value read above), so the
        // rare case of a replaced shell is reported accurately rather
        // than assumed away.
        desktopEnvironment: _describeShellPath(result['ShellPath'] as String?),
        // Windows' Desktop Window Manager (DWM) has been the single,
        // non-swappable compositor since Vista — not a "which one did
        // you pick" field the way X11-vs-Wayland is on Linux, but a
        // real, correct answer rather than a dismissive one.
        displayServer: 'Desktop Window Manager (DWM)',
        // The process that actually launched DarkTask (see the query
        // above) — PowerShell, Command Prompt, Windows Terminal, or
        // File Explorer for a double-click — the closest real Windows
        // equivalent to Linux's $SHELL, since Windows has no
        // persistent environment variable naming "the" interactive
        // shell the way a Linux login shell does.
        shell: _describeLauncherProcess(result['ParentProcessName'] as String?),
        // Platform.localeName is backed by the OS's own locale (ICU on
        // every platform Flutter supports) — genuinely available on
        // Windows too, unlike the LANG/LC_ALL POSIX environment
        // variables this used to read, which essentially never exist
        // there at all.
        locale: Platform.localeName,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read system info: $e\n$st');
      return SystemInfoSample.unknown();
    }
  }

  // --- Elevation -----------------------------------------------------

  // Both gated on `_lastKnownCpuTempC == null` — i.e. no source at all
  // (background feed, in-process LHM, or the ACPI thermal zone
  // fallback) currently has a real CPU temperature — on top of the
  // underlying LHM-specific flag. Without that guard, a machine where
  // BackgroundSensorFeed (or the thermal zone fallback) already
  // supplies a working temperature could still show one of these
  // "blocked" warnings purely because the main process's OWN
  // LibreHardwareMonitor instance can't read MSR temps directly, even
  // though the person is looking at a real number the whole time —
  // confusing and, from the "is there actually a problem to fix here"
  // standpoint the warning exists to answer, simply wrong. See
  // _readCpuUncached's assignment to _lastKnownCpuTempC for the full
  // reasoning.
  @override
  bool get needsElevationForFullSensors => _lastKnownCpuTempC == null && _lhm.needsElevation;

  @override
  bool get isRunningElevated => NativeElevationCheck.isElevated() == true;

  @override
  bool get msrBlockedDespiteElevation => _lastKnownCpuTempC == null && _lhm.msrBlockedByVbs;

  @override
  Future<String?> restartElevated() async {
    try {
      final exePath = Platform.resolvedExecutable;
      final escapedPath = exePath.replaceAll("'", "''");

      // Start-Process -Verb RunAs is PowerShell's way of invoking
      // ShellExecuteEx with the "runas" verb — the standard mechanism
      // for triggering a UAC elevation prompt. It throws synchronously
      // if the person declines the prompt, which lets this check
      // success *before* closing the current instance, rather than
      // exiting blindly and hoping the elevated copy actually started.
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "try { Start-Process -FilePath '$escapedPath' -Verb RunAs | Out-Null; "
            "Write-Output 'DARKTASK_ELEVATE_OK' } catch { Write-Output ('DARKTASK_ELEVATE_ERROR: ' + \$_.Exception.Message) }",
      ]);

      final output = '${result.stdout}\n${result.stderr}';
      if (output.contains('DARKTASK_ELEVATE_OK')) {
        AppLogger.instance.info(
          _logSource,
          'Herstart als Administrator geaccepteerd — deze (niet-verhoogde) instantie sluit nu af.',
        );
        // Stop the persistent PowerShell session cleanly first so it
        // doesn't linger as an orphaned process once this instance
        // exits — same cleanup path app.dart already calls on normal
        // shutdown.
        disposeIntelGpuTop();
        exit(0);
      }

      final errorMatch = RegExp(r'DARKTASK_ELEVATE_ERROR:\s*(.+)').firstMatch(output);
      final message = errorMatch?.group(1)?.trim();
      AppLogger.instance.info(_logSource, 'Herstart als Administrator niet doorgegaan: ${message ?? output.trim()}');
      // The UAC dialog itself already communicates "declined" — this
      // is deliberately phrased as a neutral fact, not implying the
      // person did anything wrong.
      return message != null && message.isNotEmpty
          ? 'Herstart geannuleerd: $message'
          : 'Herstart als Administrator is niet doorgegaan.';
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to restart elevated: $e');
      return 'Herstart als Administrator is mislukt: $e';
    }
  }

  // --- Per-process GPU ---------------------------------------------

  /// Windows exposes a "GPU Engine" performance-counter category with
  /// one instance per (process, GPU engine) pair — instance names look
  /// like `pid_1234_luid_0x...0x..._phys_0_eng_0_engtype_3D`. This is
  /// the exact same mechanism Windows' own Task Manager uses for its
  /// per-process GPU column.
  ///
  /// **Deliberately not converted to persistent counters the way
  /// CPU/disk/network were.** Those categories have a small, stable
  /// set of instances (cores, disks, adapters) that barely change
  /// during a session. GPU Engine instances appear and disappear
  /// constantly as processes start and stop using the GPU — reusing a
  /// PerformanceCounter object across polls here would risk the same
  /// instance-name-reuse problem flagged for per-process CPU tracking
  /// (see ProcessService's class doc): a stale counter silently
  /// reporting a *different* process's data once an instance name gets
  /// recycled. Instead, this creates fresh counters, takes both
  /// readings a rate counter needs, and discards them — all within one
  /// short-lived script run, never persisted across polls.
  @override
  Future<Map<int, double>> readPerProcessGpuLoad() async {
    try {
      final result = await _runJson(
        r"$counters = @{}; "
        r"$names = (New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')).GetInstanceNames(); "
        // Pass 1: create every counter and take the throwaway priming
        // sample. Rate counters read 0 on their first sample — there's
        // no prior value to diff against yet — so this has to happen
        // before the single shared settle delay below, not per
        // instance (see the class doc above for why persistence across
        // polls isn't used instead of this).
        r"foreach ($n in $names) { "
        r"  if ($n -match 'pid_(\d+)_') { "
        r"    try { "
        r"      $c = New-Object System.Diagnostics.PerformanceCounter('GPU Engine', 'Utilization Percentage', $n); "
        r"      $c.NextValue() | Out-Null; "
        r"      $counters[$n] = @{ counter = $c; procPid = $matches[1] }; "
        r"    } catch { } "
        r"  } "
        r"}; "
        // One single settle delay total, regardless of how many
        // instances exist — a process can easily have several engines
        // (3D, Copy, VideoDecode, ...), and sleeping per-instance
        // would multiply this into several seconds for no reason.
        r"Start-Sleep -Milliseconds 200; "
        // Pass 2: read every already-created counter's real value and
        // aggregate by PID (summed across that PID's engines).
        r"$result = @{}; "
        r"foreach ($entry in $counters.Values) { "
        r"  try { "
        r"    $val = $entry.counter.NextValue(); "
        r"    if (-not $result.ContainsKey($entry.procPid)) { $result[$entry.procPid] = 0.0 } "
        r"    $result[$entry.procPid] = $result[$entry.procPid] + $val; "
        r"  } catch { } "
        r"}; "
        r"$result | ConvertTo-Json -Compress",
      );
      if (result == null) return {};
      if (result is! Map<String, dynamic>) return {};

      final merged = <int, double>{};
      for (final entry in result.entries) {
        final pid = int.tryParse(entry.key);
        final value = _asDouble(entry.value);
        if (pid != null && value != null) {
          merged[pid] = value.clamp(0, 100);
        }
      }
      return merged;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read per-process GPU load: $e');
      return {};
    }
  }

  // --- Background sensor feed -----------------------------------

  @override
  Future<bool> isBackgroundSensorFeedActive() => _backgroundFeed.isActive();

  @override
  Future<String?>? _setupBackgroundFeedInFlight;

  /// Added 2026-09-13, following the exact same reasoning as
  /// `LibreHardwareMonitorBridge.installPawnIo`'s own choke point (see
  /// its doc comment): at least two independent call sites can decide
  /// "the background feed isn't active yet" around the same moment —
  /// this class's own `autoProvisionSensorDependencies()` and a separate
  /// check in app.dart, neither aware of the other. `_doSetupBackground
  /// SensorFeed` below Stop-ScheduledTask's then Start-ScheduledTask's
  /// the exact same task by name; two overlapping runs of that sequence
  /// racing on the same scheduled task is the same shape of problem that
  /// produced a real, reproduced failure for `installPawnIo()` (two
  /// downloads colliding on one file) — not yet reproduced here, but
  /// there's no reason to wait for it to happen live before closing the
  /// same gap the same way. A second concurrent caller now just awaits
  /// the one attempt already in progress.
  Future<String?> setupBackgroundSensorFeed() {
    final inFlight = _setupBackgroundFeedInFlight;
    if (inFlight != null) {
      AppLogger.instance.info(
        _logSource,
        'Instellen van de achtergronddienst is al bezig (via een andere aanroep) — wacht op dat '
        'resultaat in plaats van de geplande taak een tweede keer tegelijk te stoppen/starten.',
      );
      return inFlight;
    }
    final future = _doSetupBackgroundSensorFeed();
    _setupBackgroundFeedInFlight = future;
    unawaited(future.whenComplete(() => _setupBackgroundFeedInFlight = null));
    return future;
  }

  Future<String?> _doSetupBackgroundSensorFeed() async {
    // Added 2026-09-13, reproduced live: `_lhm.loadedDllPath` reflects
    // whatever `_doInitialize()` last found, which briefly reads back as
    // null right after `installPawnIo()` resets it (see the comment in
    // `autoProvisionSensorDependencies()` above) — it stays that way
    // until something re-triggers `_doInitialize()`. This method used to
    // read that field directly with no such trigger of its own, so
    // whichever caller happened to land in that window got
    // `fallbackDllPath: null` and failed with "LibreHardwareMonitorLib.dll
    // is nog niet gedownload" — even though the DLL was sitting right
    // there on disk the whole time, confirmed by the very next sensor
    // read succeeding moments later. A cheap `readCpu()` first guarantees
    // a freshly-populated `loadedDllPath` regardless of which caller gets
    // here first or what just ran immediately before it.
    await readCpu().catchError((_) => CpuSample.empty());
    return _backgroundFeed.setupBackgroundService(fallbackDllPath: _lhm.loadedDllPath);
  }

  @override
  Future<String?> removeBackgroundSensorFeed() => _backgroundFeed.removeBackgroundService();

  // --- Disk health -----------------------------------------------

  /// `Get-StorageReliabilityCounter` (part of the Storage module,
  /// built into Windows 8/Server 2012 and later) is the same
  /// PowerShell-native source File Explorer's own drive health
  /// indicators and third-party tools alike read from — no raw
  /// SMART/ATA command parsing needed the way Linux's smartctl does
  /// it. `Wear` specifically is vendor-normalized to a single 0-100
  /// scale by the storage driver itself, sidestepping the
  /// vendor-specific SMART attribute IDs (231 vs 233 vs others
  /// depending on manufacturer) that make wear-level genuinely
  /// inconsistent to read directly from raw SMART data.
  @override
  Future<List<DiskHealthInfo>> readDiskHealth() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$disks = Get-PhysicalDisk | ForEach-Object { '
            r'  $disk = $_; '
            r'  $counters = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue; '
            r'  $wmiDrive = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | '
            r'    Where-Object { $_.Index -eq $disk.DeviceId }; '
            r'  [PSCustomObject]@{ '
            r'    deviceId = $disk.DeviceId; '
            r'    model = $disk.FriendlyName; '
            r'    isSsd = ($disk.MediaType -eq "SSD"); '
            r'    busType = $disk.BusType.ToString(); '
            r'    powerOnHours = $counters.PowerOnHours; '
            r'    wear = $counters.Wear; '
            r'    temperature = $counters.Temperature; '
            r'    pnpDeviceId = $wmiDrive.PNPDeviceID; '
            r'  } '
            r'}; '
            // Windows' own storage-miniport WMI SMART exposure —
            // root\WMI's MSStorageDriver_FailurePredictData class —
            // predates and is more broadly supported across storage
            // controllers (including some RAID-mode setups) than the
            // newer Get-StorageReliabilityCounter above. VendorSpecific
            // is a raw byte array: a 2-byte header, then one 12-byte
            // block per SMART attribute (attribute ID at relative
            // offset 0, a 4-byte raw value at relative offset 5) — the
            // exact layout confirmed against the open-source
            // Krugertech.IO.Smart library's own parsing code, not
            // guessed at. Only attribute 9 (Power-On Hours) is
            // extracted here — the one SMART attribute whose raw value
            // means the same thing (an hour count) across effectively
            // every vendor; wear-related attributes stay out for the
            // same vendor-inconsistency reason smartctl-based parsing
            // already avoids them elsewhere in this app. Temperature
            // (attribute 194 / 0xC2) is included alongside it — the
            // one temperature SMART attribute ID that's consistent
            // across virtually every vendor (unlike the higher,
            // vendor-specific 0xE0+ range), with its current-Celsius
            // reading conventionally stored as the low byte of the
            // same 4-byte raw field already being read for hours.
            r'$smartPowerOnHours = @{}; '
            r'$smartTemperature = @{}; '
            r'$smartInstanceNames = @(); '
            r'Get-CimInstance -Namespace root\WMI -ClassName MSStorageDriver_FailurePredictData -ErrorAction SilentlyContinue | '
            r'ForEach-Object { '
            r'  $bytes = $_.VendorSpecific; '
            r'  $instanceName = $_.InstanceName; '
            r'  $smartInstanceNames += $instanceName; '
            r'  for ($i = 0; $i -lt 30; $i++) { '
            r'    $base = $i * 12 + 2; '
            r'    if ($base + 10 -ge $bytes.Length) { break } '
            r'    $id = $bytes[$base]; '
            r'    if ($id -eq 9) { '
            r'      $smartPowerOnHours[$instanceName] = [BitConverter]::ToUInt32($bytes, $base + 5); '
            r'    } elseif ($id -eq 194) { '
            r'      $smartTemperature[$instanceName] = $bytes[$base + 5]; '
            r'    } '
            r'  } '
            r'}; '
            r'foreach ($d in $disks) { '
            r'  $d | Add-Member -NotePropertyName smartDiagCount -NotePropertyValue $smartInstanceNames.Count -Force; '
            r'  $d | Add-Member -NotePropertyName smartDiagNames -NotePropertyValue ($smartInstanceNames -join "; ") -Force; '
            r'  if ($d.pnpDeviceId) { '
            r'    foreach ($key in $smartPowerOnHours.Keys) { '
            r'      if ($key -like ("*" + $d.pnpDeviceId + "*")) { '
            r'        $d | Add-Member -NotePropertyName smartPowerOnHours -NotePropertyValue $smartPowerOnHours[$key] -Force; '
            r'        break; '
            r'      } '
            r'    } '
            r'    foreach ($key in $smartTemperature.Keys) { '
            r'      if ($key -like ("*" + $d.pnpDeviceId + "*")) { '
            r'        $d | Add-Member -NotePropertyName smartTemperature -NotePropertyValue $smartTemperature[$key] -Force; '
            r'        break; '
            r'      } '
            r'    } '
            r'  } '
            r'}; '
            r'$disks | ConvertTo-Json -Compress -Depth 3',
      ]);
      if (result.exitCode != 0) {
        AppLogger.instance.error(
          _logSource,
          'Get-PhysicalDisk/Get-StorageReliabilityCounter exited ${result.exitCode}: ${result.stderr}',
        );
        return [];
      }
      final output = (result.stdout as String).trim();
      AppLogger.instance.info(_logSource, 'Schijfgezondheid ruwe PowerShell-uitvoer: $output');
      if (output.isEmpty) {
        AppLogger.instance.info(
          _logSource,
          'Get-PhysicalDisk gaf geen schijven terug, of Get-StorageReliabilityCounter is niet beschikbaar op dit systeem.',
        );
        return [];
      }

      final decoded = jsonDecode(output);
      final rows = decoded is List ? decoded : [decoded];

      return rows.map((r) {
        final map = r as Map<String, dynamic>;
        final deviceIndex = _asInt(map['deviceId']);
        final busType = map['busType']?.toString();
        final isNvme = busType?.toUpperCase() == 'NVME';

        AppLogger.instance.info(
          _logSource,
          'PhysicalDrive$deviceIndex: busType="$busType", isSsd=${map['isSsd']}, '
          '${isNvme ? 'directe NVMe-uitlezing wordt geprobeerd...' : 'geen NVMe, directe route overgeslagen.'}',
        );

        var powerOnHours = _asInt(map['powerOnHours']);
        // Windows' storage-miniport WMI SMART exposure
        // (MSStorageDriver_FailurePredictData, queried above) is
        // preferred over Get-StorageReliabilityCounter's own
        // PowerOnHours when both are present — it's the older, more
        // broadly-supported mechanism (see the query comment above for
        // the full reasoning), so where it has a real reading, that
        // reading is trusted first.
        final smartPowerOnHours = _asInt(map['smartPowerOnHours']);
        if (smartPowerOnHours != null) powerOnHours = smartPowerOnHours;

        var rawWear = (map['isSsd'] == true) ? _asDouble(map['wear']) : null;

        // For NVMe drives specifically, prefer the direct SMART/health
        // log query (NvmeHealthReader) over Get-StorageReliabilityCounter
        // — it reads the standardized NVMe PercentageUsed/PowerOnHours
        // fields directly from the drive itself, sidestepping whatever
        // Get-StorageReliabilityCounter's driver abstraction does or
        // doesn't track (see the placeholder-detection comment below,
        // and NvmeHealthReader's own doc, for the specific, confirmed
        // real-world unreliability this exists to work around). Only
        // overwrites the PowerShell-derived values when it actually
        // succeeds — any failure here (not accessible, IOCTL declined,
        // implausible data) leaves the existing values and placeholder
        // detection below exactly as they were.
        if (isNvme && deviceIndex != null) {
          final direct = _nvmeHealth.readHealth(deviceIndex);
          if (direct != null) {
            rawWear = direct.percentageUsed;
            powerOnHours = direct.powerOnHours;
            AppLogger.instance.info(
              _logSource,
              'NVMe-schijf PhysicalDrive$deviceIndex: directe SMART-uitlezing gelukt '
              '(${direct.percentageUsed.toStringAsFixed(0)}% gebruikt, ${direct.powerOnHours}u).',
            );
          } else {
            AppLogger.instance.info(
              _logSource,
              'NVMe-schijf PhysicalDrive$deviceIndex: directe SMART-uitlezing mislukt — '
              'valt terug op Get-StorageReliabilityCounter (zie eerdere regels voor de exacte reden).',
            );
          }
        }

        // A confirmed, documented quirk (Microsoft's own
        // Get-StorageReliabilityCounter example output, and multiple
        // real-world reports): many storage controllers report Wear=0
        // not because the drive is genuinely unworn, but because that
        // counter simply isn't tracked/exposed on this hardware — 0 is
        // the field's default, not a measurement. A drive with
        // meaningful, non-trivial PowerOnHours (i.e. it's clearly been
        // in real use) reporting exactly 0 wear is the tell-tale sign
        // of this placeholder case, not a genuinely brand-new drive —
        // treated as "no real data" (null) rather than shown as a
        // false "100% life remaining." Only applies to the
        // PowerShell-derived value — a genuine 0 from the direct NVMe
        // read above is a real, standardized measurement, not a
        // placeholder.
        final wearLooksLikePlaceholder =
            !isNvme && rawWear == 0 && (powerOnHours == null || powerOnHours > 24);

        // Same preference order as powerOnHours above: the WMI SMART
        // temperature (attribute 194) is trusted first when present,
        // since it's the more broadly-supported source. Anything below
        // 5°C is treated the same way Wear=0 already is above —
        // implausible for a drive that's actually spinning/powered
        // inside a running PC, and so more likely a placeholder default
        // from whichever source reported it than a genuine reading —
        // left null rather than shown as a real (near-freezing)
        // temperature.
        //
        // Widened from an exact `== 0` check on 2026-09-22, reproduced
        // live: a Kingston NVMe SSD behind a RAID controller reported
        // exactly 1°C (not 0) for a machine that had clearly been
        // running for a while — the same placeholder pattern as the 0°C
        // case, just one off. `< 5` keeps this conservative (an indoor
        // PC's drive essentially never legitimately reads that low
        // while powered on) rather than trying to guess every possible
        // placeholder value a driver might report.
        var temperatureC = _asDouble(map['temperature']);
        final smartTemperature = _asDouble(map['smartTemperature']);
        if (smartTemperature != null) temperatureC = smartTemperature;
        if (temperatureC != null && temperatureC < 5) temperatureC = null;

        // Last-resort fallback for non-NVMe drives specifically (ATA
        // pass-through sends a legacy ATA command, which isn't the
        // protocol NVMe drives speak — those already have their own,
        // more standardized route via NvmeHealthReader above): only
        // attempted when the WMI SMART route above found nothing at
        // all for this drive, since that's the specific gap this
        // exists to try closing — see AtaPassThroughReader's own doc
        // for the full reasoning, including why even this isn't
        // guaranteed to work (RAID/storage driver support for ATA
        // pass-through is genuinely undocumented and version-dependent,
        // per Hard Disk Sentinel's own public documentation of this
        // exact problem).
        if (!isNvme && deviceIndex != null && powerOnHours == null) {
          final viaAta = _ataPassThrough.readSmartData(deviceIndex);
          if (viaAta != null) {
            if (viaAta.powerOnHours != null) powerOnHours = viaAta.powerOnHours;
            // Same `< 5` placeholder guard as the WMI-derived value
            // above — a genuine ATA pass-through reading isn't any less
            // susceptible to a driver's placeholder default than the
            // WMI route is.
            if (viaAta.temperatureC != null && viaAta.temperatureC! < 5) {
              // Placeholder — leave temperatureC as whatever the WMI
              // route above already determined (including null),
              // rather than overwriting it with this implausible value.
            } else if (viaAta.temperatureC != null) {
              temperatureC = viaAta.temperatureC;
            }
          }
        }

        // Log what the UI will actually be given, so a log alone shows
        // whether a drive behind a RAID controller ended up with real
        // values (from the WMI SMART fallback above) or with nothing.
        AppLogger.instance.info(
          _logSource,
          'PhysicalDrive${map['deviceId']}: resultaat — '
          'aan-uren=${powerOnHours ?? 'n/a'}, '
          'temperatuur=${temperatureC != null ? '${temperatureC.toStringAsFixed(0)}°C' : 'n/a'}, '
          'slijtage=${wearLooksLikePlaceholder ? 'n/a (schijf meldt alleen een placeholder-0)' : (rawWear != null ? '${rawWear.toStringAsFixed(0)}% gebruikt' : 'n/a')}.',
        );

        return DiskHealthInfo(
          deviceId: '\\\\.\\PhysicalDrive${map['deviceId']}',
          model: map['model']?.toString(),
          isSsd: map['isSsd'] as bool?,
          powerOnHours: powerOnHours,
          // Wear is only a meaningful figure for SSDs (see this
          // model's own doc) — left null for spinning disks rather
          // than showing a counter that, even if the driver returns
          // one, doesn't represent the same thing a hard disk's
          // mechanical wear actually is.
          wearPercentUsed: wearLooksLikePlaceholder ? null : rawWear,
          temperatureC: temperatureC,
        );
      }).toList();
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to read disk health: $e\n$st');
      return [];
    }
  }
}
