/// Which vendor/backend produced a [GpuSample]. Determines which fields
/// are realistically populated — e.g. integrated GPUs rarely expose a
/// separate VRAM figure since they share system memory.
enum GpuVendor { nvidia, amd, intel, unknown }

/// A single point-in-time GPU reading. Fields are nullable because
/// availability differs by vendor/driver (NVIDIA via nvidia-smi vs.
/// AMD/Intel via sysfs, which expose less detail depending on kernel
/// driver version).
class GpuSample {
  /// Stable identifier for this GPU across polls, used to key history
  /// buffers when multiple GPUs are present (e.g. "nvidia0", "card0").
  final String id;
  final DateTime timestamp;
  final String name;
  final GpuVendor vendor;
  final double? loadPercent;
  final double? memoryUsedMiB;
  final double? memoryTotalMiB;
  final double? temperatureC;
  final double? powerDrawWatts;
  final double? clockMHz;

  /// True when [temperatureC] isn't actually a GPU-specific reading,
  /// but the CPU package temperature used as a stand-in — the case for
  /// most integrated Intel GPUs, which share a die with the CPU and
  /// have no separate thermal sensor exposed by the kernel. Kept as an
  /// explicit flag (rather than silently substituting the value)
  /// because presenting a shared-die reading as if it were an
  /// independently-measured GPU temperature would be misleading, even
  /// though the number itself is genuine and relevant.
  final bool temperatureIsSharedWithCpu;

  /// GPU fan speed in RPM, or null when unavailable — absent for most
  /// integrated GPUs (no fan of their own), passively-cooled cards,
  /// and any vendor/driver combination this app has no fan sensor
  /// access for. Never fabricated as 0.
  final int? fanRpm;

  const GpuSample({
    required this.id,
    required this.timestamp,
    required this.name,
    this.vendor = GpuVendor.unknown,
    this.loadPercent,
    this.memoryUsedMiB,
    this.memoryTotalMiB,
    this.temperatureC,
    this.powerDrawWatts,
    this.clockMHz,
    this.temperatureIsSharedWithCpu = false,
    this.fanRpm,
  });

  factory GpuSample.unavailable() => GpuSample(
        id: 'none',
        timestamp: DateTime.now(),
        name: 'No GPU detected',
      );
}
