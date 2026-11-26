import 'dart:collection';

/// One polled snapshot of the sensors this app already reads every
/// tick, timestamped for [SensorLogRecorder]'s CSV export — the
/// DarkTask equivalent of HWiNFO64's timestamped sensor-logging CSV.
class SensorLogRow {
  final DateTime timestamp;
  final double cpuLoadPercent;
  final double memUsedPercent;
  final double? cpuPowerW;
  final double? cpuTempC;
  final double? diskActivityPercent;
  final double? networkBytesPerSec;

  /// Keyed by [GpuSample.id] — a `Map` rather than fixed fields because
  /// the number of GPUs isn't known until runtime (see
  /// [SensorStatsTracker]'s own doc for the same reasoning).
  final Map<String, double> gpuLoadPercent;
  final Map<String, double> gpuTempC;

  const SensorLogRow({
    required this.timestamp,
    required this.cpuLoadPercent,
    required this.memUsedPercent,
    this.cpuPowerW,
    this.cpuTempC,
    this.diskActivityPercent,
    this.networkBytesPerSec,
    this.gpuLoadPercent = const {},
    this.gpuTempC = const {},
  });
}

/// App-lifetime singleton building a rolling, timestamped sensor log —
/// fed passively by `PerformanceScreen._doPoll()` alongside the
/// existing `SensorStatsTracker.instance.record(...)` calls, so this
/// adds no extra sensor polling of its own, same as that class.
///
/// Deliberately an in-memory *rolling* buffer, not an ever-growing one
/// written to disk on every tick: at a 1s poll interval, [maxRows]
/// (12 hours worth) already holds tens of thousands of rows — plenty
/// for "export what's happened recently" — while avoiding either
/// unbounded memory growth over a multi-day-uptime session or the
/// complexity/IO cost of a background log-file writer. A person who
/// wants a full multi-day trace should export periodically; that's an
/// honest limitation to document rather than silently cap without
/// saying so (see [SensorLogRecorder]'s own [rowCount] surfaced in the
/// export UI).
class SensorLogRecorder {
  SensorLogRecorder._();
  static final SensorLogRecorder instance = SensorLogRecorder._();

  /// ~12 hours of rows at the fastest (1s) poll interval — see the
  /// class doc above for why this is bounded rather than unbounded.
  static const maxRows = 43200;

  final Queue<SensorLogRow> _rows = Queue<SensorLogRow>();
  final SplayTreeSet<String> _knownGpuIds = SplayTreeSet<String>();

  int get rowCount => _rows.length;

  DateTime? get oldestTimestamp => _rows.isEmpty ? null : _rows.first.timestamp;

  void record(SensorLogRow row) {
    _rows.addLast(row);
    if (_rows.length > maxRows) _rows.removeFirst();
    _knownGpuIds.addAll(row.gpuLoadPercent.keys);
    _knownGpuIds.addAll(row.gpuTempC.keys);
  }

  /// Clears the buffered log — offered for a future "log wissen"
  /// action, mirroring [SensorStatsTracker.resetAll]; not wired to any
  /// UI yet beyond being implicitly available.
  void clear() {
    _rows.clear();
    _knownGpuIds.clear();
  }

  /// Renders the current buffer as CSV text. GPU columns are fixed to
  /// every GPU id seen at least once so far this session (sorted for a
  /// stable column order across exports) — a row recorded before a
  /// given GPU's first successful reading simply leaves that cell
  /// blank, same "leave it blank rather than fabricate a zero" rule
  /// this app already applies to unavailable sensors elsewhere.
  String toCsv() {
    final gpuIds = _knownGpuIds.toList();
    final header = StringBuffer('timestamp,cpuLoadPercent,memUsedPercent,cpuPowerW,cpuTempC,'
        'diskActivityPercent,networkBytesPerSec');
    for (final id in gpuIds) {
      header.write(',gpuLoadPercent[$id],gpuTempC[$id]');
    }

    final buffer = StringBuffer(header.toString())..write('\r\n');
    for (final row in _rows) {
      buffer
        ..write(row.timestamp.toIso8601String())
        ..write(',')
        ..write(row.cpuLoadPercent.toStringAsFixed(2))
        ..write(',')
        ..write(row.memUsedPercent.toStringAsFixed(2))
        ..write(',')
        ..write(row.cpuPowerW?.toStringAsFixed(2) ?? '')
        ..write(',')
        ..write(row.cpuTempC?.toStringAsFixed(1) ?? '')
        ..write(',')
        ..write(row.diskActivityPercent?.toStringAsFixed(2) ?? '')
        ..write(',')
        ..write(row.networkBytesPerSec?.toStringAsFixed(0) ?? '');
      for (final id in gpuIds) {
        buffer
          ..write(',')
          ..write(row.gpuLoadPercent[id]?.toStringAsFixed(2) ?? '')
          ..write(',')
          ..write(row.gpuTempC[id]?.toStringAsFixed(1) ?? '');
      }
      buffer.write('\r\n');
    }
    return buffer.toString();
  }
}
