/// Detailed, mostly-static CPU info for the Performance > CPU detail
/// view — read once (not polled every second) via `lscpu` and sysfs.
/// Fields are nullable/left as "onbekend" rather than guessed when the
/// underlying source isn't available, instead of fabricating a value.
class CpuDetailInfo {
  final double? baseSpeedMHz;
  final int? physicalCores;
  final int? sockets;
  final int? logicalProcessors;
  final String? virtualizationSupport; // e.g. "VT-x", "AMD-V", or null
  final bool? isVirtualMachine;
  final String? frequencyDriver; // e.g. "intel_pstate"
  final String? governor; // e.g. "powersave"

  const CpuDetailInfo({
    this.baseSpeedMHz,
    this.physicalCores,
    this.sockets,
    this.logicalProcessors,
    this.virtualizationSupport,
    this.isVirtualMachine,
    this.frequencyDriver,
    this.governor,
  });

  factory CpuDetailInfo.unknown() => const CpuDetailInfo();
}
