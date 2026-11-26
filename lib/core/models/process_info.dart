/// A single row in the process table.
class ProcessInfo {
  final int pid;
  final String name;
  final double cpuPercent;
  final int memoryKiB;
  final String user;
  final String state;

  /// GPU load attributable to this specific process, 0-100, or null
  /// when not available. Distinct from "0%" (measured and genuinely
  /// idle) — null means "not measured for this process," which
  /// callers should render as a dash, not a zero.
  final double? gpuPercent;

  const ProcessInfo({
    required this.pid,
    required this.name,
    required this.cpuPercent,
    required this.memoryKiB,
    required this.user,
    required this.state,
    this.gpuPercent,
  });

  /// Returns a copy with [gpuPercent] filled in — used to merge
  /// per-process GPU data (a separate, optional read) into an
  /// already-built process list without needing every call site that
  /// constructs a [ProcessInfo] to know about GPU tracking at all.
  ProcessInfo withGpuPercent(double? gpuPercent) => ProcessInfo(
        pid: pid,
        name: name,
        cpuPercent: cpuPercent,
        memoryKiB: memoryKiB,
        user: user,
        state: state,
        gpuPercent: gpuPercent,
      );
}
