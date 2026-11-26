import '../../core/models/battery_energy_sample.dart';
import '../../core/models/battery_sample.dart';
import '../../core/models/cpu_detail_info.dart';
import '../../core/models/cpu_sample.dart';
import '../../core/models/disk_health_info.dart';
import '../../core/models/disk_sample.dart';
import '../../core/models/gpu_diagnostic.dart';
import '../../core/models/gpu_sample.dart';
import '../../core/models/load_sample.dart';
import '../../core/models/memory_sample.dart';
import '../../core/models/network_sample.dart';
import '../../core/models/system_info_sample.dart';

/// Platform-independent contract for reading live hardware telemetry.
/// [LinuxSensorService] (mixin-composed, reading /proc, /sys, and CLI
/// tools) and `WindowsSensorService` (PowerShell/CIM-based) both
/// implement this, so every screen and service in the app is written
/// against `SystemSensorService` and never needs to know or care which
/// OS it's actually running on — `app.dart` is the one place that picks
/// the concrete implementation, based on `Platform.isWindows`.
///
/// Every field on every returned model is already nullable where
/// availability genuinely differs by OS/driver/hardware (e.g. GPU
/// temperature, CPU power draw) — implementations return null rather
/// than a fabricated value when something isn't obtainable, consistent
/// with the rest of this app's "no fake data" rule. A platform simply
/// leaving more fields null than another isn't a bug in that platform's
/// implementation; it's this interface working as designed.
abstract class SystemSensorService {
  // --- CPU ---------------------------------------------------------------

  /// Instantaneous CPU load. On the very first call there's no prior
  /// snapshot to diff against, so implementations return a zeroed
  /// sample — callers should discard the first reading, same as today.
  Future<CpuSample> readCpu();

  /// Average CPU package power draw since the last call, in watts, or
  /// null if this platform/hardware doesn't expose it (e.g. no RAPL on
  /// non-Intel, or no equivalent Windows sensor without vendor tools).
  Future<double?> readCpuPowerWatts();

  /// Static/slow-changing CPU details (physical cores, sockets,
  /// virtualization, governor, ...) — meant to be read once when a
  /// detail panel opens, not polled every second.
  Future<CpuDetailInfo> readCpuDetails();

  /// Total thread count system-wide, or null if unavailable.
  Future<int?> readThreadCount();

  // --- Memory & load -------------------------------------------------

  /// System load averages. Windows has no direct load-average concept;
  /// implementations there return a best-effort equivalent or a zeroed
  /// sample rather than fabricating one.
  Future<LoadSample> readLoad();

  Future<MemorySample> readMemory();

  // --- Disk ------------------------------------------------------------

  Future<List<DiskSample>> readDisks();

  /// System-wide disk I/O "busy" percentage, or null if unavailable.
  Future<double?> readDiskActivity();

  // --- Network -----------------------------------------------------------

  Future<List<NetworkSample>> readNetwork();

  // --- GPU ---------------------------------------------------------------

  Future<List<GpuSample>> readGpus();

  /// Per-GPU diagnostics (e.g. "load reading needs a permission fix" on
  /// Linux/Intel) that the UI can offer an in-app action for. Always
  /// empty on platforms with nothing actionable to offer.
  Map<String, GpuDiagnostic> get gpuDiagnostics;

  /// Stops any persistent background process a platform's GPU-load
  /// reader may be keeping alive (e.g. Linux's intel_gpu_top, or a
  /// Windows LibreHardwareMonitor session). Safe to call even if
  /// nothing is running.
  void disposeIntelGpuTop();

  /// Attempts to fix a permission-related GPU diagnostic in-app.
  /// Returns false (never throws) on platforms with nothing to fix.
  Future<bool> fixIntelGpuPermission();

  /// Attempts to install a missing optional GPU-monitoring tool in-app.
  /// Returns false (never throws) on platforms with nothing to install
  /// this way.
  Future<bool> installIntelGpuTools();

  // --- Battery -----------------------------------------------------------

  Future<BatterySample> readBattery();

  /// Batterij in mWh/mW (fijner dan hele procenten), voor korte
  /// verbruiksmetingen. Null als de machine dit niet kan leveren; de
  /// aanroeper valt dan terug op [readBattery].
  Future<BatteryEnergySample?> readBatteryEnergy();

  // --- System info ---------------------------------------------------

  Future<SystemInfoSample> readSystemInfo();

  // --- Elevation -----------------------------------------------------

  /// True when this platform has detected that running elevated (as
  /// Administrator on Windows) would unlock sensors currently
  /// returning null — specifically LibreHardwareMonitor's "sensor
  /// known, value always empty" pattern for CPU temperature/power on
  /// Windows. Always false on Linux, which has no equivalent concept
  /// (permission issues there are handled per-action via pkexec, not a
  /// single whole-app elevation).
  bool get needsElevationForFullSensors;

  /// True when this process itself is currently running elevated (as
  /// Administrator on Windows) — a direct, live answer, not inferred
  /// from whether a given sensor happens to be readable right now (see
  /// [needsElevationForFullSensors] for that inference, which can go
  /// false again once the background feed or another fallback path
  /// starts covering a sensor, even on a non-elevated launch).
  ///
  /// Used by the Performance screen to decide whether the background-
  /// sensor-feed "set up"/"already active" cards are still worth
  /// showing at all: on an elevated launch,
  /// [SystemSensorService.autoProvisionSensorDependencies] already
  /// silently handles that setup (or its failure is already visible on
  /// the Log tab) before the person ever sees this screen, so offering
  /// the same action again here would just be redundant UI — those
  /// cards are only genuinely useful on a non-elevated launch, where
  /// auto-provisioning is a deliberate no-op and this remains the only
  /// way to opt in. Always false on Linux, which has no elevation
  /// concept to report.
  bool get isRunningElevated;

  /// True when this platform has detected LibreHardwareMonitor's same
  /// "sensor known, value always empty" pattern for CPU temperature/
  /// power — but while this process was already confirmed running
  /// elevated. Elevating again (restartElevated) is therefore not the
  /// fix; the far more likely cause is Windows' Memory Integrity/Core
  /// Isolation (Virtualization-Based Security), which many machines now
  /// ship enabled by default and which blocks direct MSR access
  /// regardless of process elevation, or running inside a VM (same
  /// underlying MSR restriction, enforced by the hypervisor instead).
  /// Always false on Linux, which has no MSR-elevation concept at all.
  bool get msrBlockedDespiteElevation;

  /// True when [msrBlockedDespiteElevation] is set AND this platform's
  /// own diagnostics have positively confirmed the specific cause:
  /// LibreHardwareMonitor's PawnIO kernel driver (its MSR access layer
  /// since v0.9.4) is not installed anywhere on this machine — checked
  /// three independent ways (the native driver list, Windows services,
  /// and a filesystem sweep), not guessed. [msrBlockedDespiteElevation]
  /// alone doesn't say *which* of several possible causes applies
  /// (Memory Integrity/VBS, a hypervisor, or this); this flag narrows
  /// it to the one that has an actual in-app fix. Always false on
  /// Linux, which has no PawnIO/MSR-driver concept.
  bool get pawnIoConfirmedMissing;

  /// Downloads the official PawnIO installer, verifies its signature,
  /// and runs it silently (no visible window — see
  /// [LibreHardwareMonitorBridge.installPawnIo] for the exact install
  /// switches), so LibreHardwareMonitor's MSR-based CPU temperature/
  /// power reads can work. Triggered either by an explicit button
  /// press or, on an already-elevated launch, automatically by
  /// [autoProvisionSensorDependencies] — either way the same signature
  /// check and post-install re-verification apply; nothing about the
  /// installer's own trust checks changes based on who called this.
  /// Returns true only once PawnIO's presence has been re-verified
  /// after the installer closes — never claims success just because
  /// the installer process exited. Always returns false on platforms
  /// with no PawnIO concept.
  Future<bool> installPawnIo();

  /// Best-effort, zero-interaction setup: on a launch where this
  /// process is already running elevated, silently installs/starts
  /// whatever this platform's sensors still need — currently
  /// [installIntelGpuTools] (the LHM DLL) if missing, then
  /// [installPawnIo] if [pawnIoConfirmedMissing], then
  /// [setupBackgroundSensorFeed] if not already active — instead of
  /// waiting for a person to notice a diagnostic box and press its
  /// button. Added on explicit request from someone who always starts
  /// DarkTask as Administrator anyway and wants every one-time setup
  /// step folded into that, rather than pressing three separate
  /// buttons across two screens after every fresh install.
  ///
  /// Deliberately conditioned on already running elevated — this
  /// silently downloads a third-party DLL, installs a signed kernel
  /// driver, and registers a scheduled task, and doing any of that
  /// with zero user awareness is only reasonable on the strength of
  /// the person having already chosen to launch the app as
  /// Administrator; on a non-elevated launch this is a no-op and the
  /// existing manual buttons (GPU detail's "fix" action, CPU detail's
  /// PawnIO button, Performance's "achtergronddienst instellen") are
  /// still there exactly as before, unchanged.
  ///
  /// Runs at most once per app launch (an internal guard, not
  /// re-entered on repeated calls) and every step it takes is still
  /// logged individually, same as the equivalent manual button would
  /// log — this changes who presses the button, not what happens or
  /// how visible it is afterward. Always a no-op on platforms with no
  /// elevation concept (Linux: permission fixes there are already
  /// per-action pkexec prompts, which need a person present to answer
  /// them anyway, so there's nothing this could silently do instead).
  Future<void> autoProvisionSensorDependencies();

  /// Relaunches the app with an elevation request (Windows: a UAC
  /// prompt) and, only if that succeeds, closes the current
  /// non-elevated instance. Returns null on success (the app is about
  /// to exit) or a human-readable error message on failure — e.g. the
  /// person declined the UAC prompt — so the UI can show it rather
  /// than silently doing nothing. Always returns a message (never
  /// exits) on platforms with no elevation concept.
  Future<String?> restartElevated();

  /// Per-process GPU load, keyed by PID, 0-100. Returns an empty map
  /// (never throws) on platforms/hardware where this isn't available —
  /// e.g. no GPU supports the underlying mechanism, or the process
  /// list has no active GPU users at all. A PID absent from the map
  /// means "not measured," not "measured as zero" — callers should
  /// treat missing entries as unavailable, not idle.
  Future<Map<int, double>> readPerProcessGpuLoad();

  /// True if a persistent background sensor task (see
  /// BackgroundSensorFeed) is already set up and producing fresh
  /// readings. Always false on Linux, which has no equivalent —
  /// permission issues there are handled per-action via pkexec, not a
  /// one-time elevated background task.
  Future<bool> isBackgroundSensorFeedActive();

  /// One-time setup for the background sensor task: see
  /// BackgroundSensorFeed's class doc for the full design reasoning.
  /// Returns null on success, or a human-readable error message on
  /// failure. Always returns a message (never sets anything up) on
  /// platforms with no elevation concept.
  Future<String?> setupBackgroundSensorFeed();

  /// Removes the background sensor task set up by
  /// [setupBackgroundSensorFeed]. Returns null on success, or a
  /// human-readable error message on failure.
  Future<String?> removeBackgroundSensorFeed();

  /// SMART/reliability data (power-on hours, wear/health) for every
  /// physical disk this app can read that data for. Returns an empty
  /// list — never throws — on a machine/OS combination where none of
  /// this is available (e.g. the required tool isn't installed, or the
  /// person hasn't granted the permission it needs). A disk absent
  /// from the result just means "no health data for this one," not
  /// that it doesn't exist — pair against [readDisks]'s device list
  /// for that.
  Future<List<DiskHealthInfo>> readDiskHealth();
}
