import 'battery_sensor_mixin.dart';
import 'cpu_sensor_mixin.dart';
import 'disk_sensor_mixin.dart';
import 'gpu_sensor_mixin.dart';
import 'memory_load_sensor_mixin.dart';
import 'network_sensor_mixin.dart';
import 'system_info_sensor_mixin.dart';
import 'system_sensor_service.dart';

/// Reads live hardware telemetry on Linux via /proc, sysfs, and optional
/// external tools (nvidia-smi, sensors). No data ever leaves the machine —
/// everything here is local reads/process calls, no network calls at all.
///
/// Implements [SystemSensorService] — the platform-independent contract
/// every screen and service is written against — alongside
/// `WindowsSensorService`. `app.dart` picks which one to instantiate
/// based on `Platform.isWindows`.
///
/// The implementation used to be one ~1560-line file. It's now split by
/// hardware domain across sibling mixins in this directory:
///
/// - [BatterySensorMixin] — battery presence/capacity/charging state
/// - [CpuSensorMixin] — load, clock, temperature, RAPL power, lscpu details
/// - [GpuSensorMixin] — NVIDIA/AMD/Intel detection, fdinfo/intel_gpu_top,
///   permission-fix and tool-install actions (depends on [CpuSensorMixin]
///   for the CPU-temperature fallback used by integrated GPUs with no
///   thermal sensor of their own, hence the mixin order below)
/// - [MemoryLoadSensorMixin] — /proc/meminfo, /proc/loadavg
/// - [DiskSensorMixin] — disk space (`df`) and I/O activity (/proc/diskstats)
/// - [NetworkSensorMixin] — per-interface throughput (/proc/net/dev)
/// - [SystemInfoSensorMixin] — hostname/OS/kernel/DMI/desktop info (depends
///   on [GpuSensorMixin] for the GPU-name list, hence it's listed last)
///
/// This class itself only composes them — every method that existed
/// before (`readCpu()`, `readGpus()`, `fixIntelGpuPermission()`, etc.) is
/// still called the exact same way by every screen and service in the
/// app; nothing outside this directory needed to change for this split.
class LinuxSensorService
    with
        CpuSensorMixin,
        GpuSensorMixin,
        BatterySensorMixin,
        MemoryLoadSensorMixin,
        DiskSensorMixin,
        NetworkSensorMixin,
        SystemInfoSensorMixin
    implements SystemSensorService {
  // Linux has no whole-app elevation concept the way Windows does —
  // permission issues here are handled per-action via pkexec
  // (fixIntelGpuPermission/installIntelGpuTools above), not by
  // restarting the entire app with elevated rights.
  @override
  bool get needsElevationForFullSensors => false;

  @override
  bool get isRunningElevated => false;

  @override
  bool get msrBlockedDespiteElevation => false;

  @override
  bool get pawnIoConfirmedMissing => false;

  @override
  Future<bool> installPawnIo() async => false;

  // No-op by design, not just "not implemented yet" — see
  // SystemSensorService.autoProvisionSensorDependencies's doc: Linux
  // has no elevation concept to gate silent installs on, and its own
  // per-action fixes (fixIntelGpuPermission/installIntelGpuTools) go
  // through pkexec, which shows its own consent prompt and needs a
  // person present to answer it regardless of who triggered the call —
  // there's nothing this could do silently that the existing buttons
  // don't already do just as safely.
  @override
  Future<void> autoProvisionSensorDependencies() async {}

  @override
  Future<String?> restartElevated() async => 'Niet van toepassing op Linux.';

  @override
  Future<bool> isBackgroundSensorFeedActive() async => false;

  @override
  Future<String?> setupBackgroundSensorFeed() async => 'Niet van toepassing op Linux.';

  @override
  Future<String?> removeBackgroundSensorFeed() async => 'Niet van toepassing op Linux.';
}
