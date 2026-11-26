/// A single point-in-time memory reading. All values in kibibytes (KiB),
/// matching /proc/meminfo's native unit, converted for display in the UI.
class MemorySample {
  final DateTime timestamp;
  final int totalKiB;
  final int usedKiB;
  final int availableKiB;
  final int cachedKiB;
  final int swapTotalKiB;
  final int swapUsedKiB;

  const MemorySample({
    required this.timestamp,
    required this.totalKiB,
    required this.usedKiB,
    required this.availableKiB,
    required this.cachedKiB,
    required this.swapTotalKiB,
    required this.swapUsedKiB,
  });

  double get usedPercent => totalKiB == 0 ? 0 : (usedKiB / totalKiB) * 100;
  double get swapUsedPercent =>
      swapTotalKiB == 0 ? 0 : (swapUsedKiB / swapTotalKiB) * 100;

  factory MemorySample.empty() => MemorySample(
        timestamp: DateTime.now(),
        totalKiB: 0,
        usedKiB: 0,
        availableKiB: 0,
        cachedKiB: 0,
        swapTotalKiB: 0,
        swapUsedKiB: 0,
      );
}
