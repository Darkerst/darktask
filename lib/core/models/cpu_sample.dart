/// A single point-in-time CPU reading.
class CpuSample {
  final DateTime timestamp;
  final double overallLoadPercent;
  final double systemLoadPercent; // time spent in kernel/system mode
  final List<double> perCoreLoadPercent;
  final double? clockMHz;
  final double? temperatureC;

  /// CPU fan speed in RPM, or null when this platform/board exposes no
  /// such sensor — genuinely absent on most laptops (fan control lives
  /// on the embedded controller, not exposed to software at all) and
  /// on any liquid-cooled or fanless setup. Never fabricated as 0.
  final int? fanRpm;

  const CpuSample({
    required this.timestamp,
    required this.overallLoadPercent,
    this.systemLoadPercent = 0,
    required this.perCoreLoadPercent,
    this.clockMHz,
    this.temperatureC,
    this.fanRpm,
  });

  factory CpuSample.empty() => CpuSample(
        timestamp: DateTime.now(),
        overallLoadPercent: 0,
        perCoreLoadPercent: const [],
      );
}
