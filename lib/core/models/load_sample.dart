/// Linux load average (1/5/15 minute) plus task counts, read from
/// /proc/loadavg in one shot (that file conveniently has both).
class LoadSample {
  final double load1;
  final double load5;
  final double load15;
  final int runningTasks;
  final int totalTasks;

  const LoadSample({
    required this.load1,
    required this.load5,
    required this.load15,
    required this.runningTasks,
    required this.totalTasks,
  });

  factory LoadSample.empty() => const LoadSample(
        load1: 0,
        load5: 0,
        load15: 0,
        runningTasks: 0,
        totalTasks: 0,
      );
}
