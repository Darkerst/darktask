/// Which resource a benchmark stresses.
enum BenchmarkType { cpu, memory, disk, network, crypto, gpu }

/// Intensity level, matching Hardware Tester's Licht/Gemiddeld/Zwaar
/// convention, plus an optional Duurtest (soak test) level for
/// catching sustained thermal throttling that a 30-45s run can miss.
/// Concrete parameters (worker count, duration, file size) are decided
/// per-test in BenchmarkService — not every type treats "duurtest" the
/// same way (see BenchmarkService's per-type duration functions), since
/// e.g. a 10-minute disk write has different real-world risk (filling
/// the disk) than a 10-minute CPU loop.
enum BenchmarkIntensity { licht, gemiddeld, zwaar, duurtest }

extension BenchmarkIntensityLabel on BenchmarkIntensity {
  String get label {
    switch (this) {
      case BenchmarkIntensity.licht:
        return 'Licht';
      case BenchmarkIntensity.gemiddeld:
        return 'Gemiddeld';
      case BenchmarkIntensity.zwaar:
        return 'Zwaar';
      case BenchmarkIntensity.duurtest:
        return 'Duurtest';
    }
  }
}

/// Which sub-mode a GPU test run used — the built-in rendering-load
/// approximation, or a real compute benchmark via an external tool
/// (glmark2), when installed.
enum GpuTestMode { render, compute }

/// A live update streamed while a benchmark is running.
class BenchmarkProgress {
  final double fractionComplete; // 0.0–1.0
  final String statusText;
  final double? currentLoadPercent;
  final double? currentTemperatureC;

  const BenchmarkProgress({
    required this.fractionComplete,
    required this.statusText,
    this.currentLoadPercent,
    this.currentTemperatureC,
  });
}

/// The final outcome of a completed (or aborted) benchmark run.
class BenchmarkResult {
  final BenchmarkType type;
  final BenchmarkIntensity intensity;
  final Duration actualDuration;
  final bool aborted;
  final String? abortReason;
  final double? score; // meaning depends on type — see summaryLine
  final double? peakTemperatureC;
  final bool throttleDetected;
  final Map<String, String> details;

  /// When this run finished. Defaults to "now" at construction time —
  /// every call site in BenchmarkService builds one right as a run
  /// completes, so that's always the right value; only the persisted
  /// history read back from disk (see BenchmarkHistoryStore) passes an
  /// explicit value, reconstructing the original moment.
  final DateTime timestamp;

  BenchmarkResult({
    required this.type,
    required this.intensity,
    required this.actualDuration,
    this.aborted = false,
    this.abortReason,
    this.score,
    this.peakTemperatureC,
    this.throttleDetected = false,
    this.details = const {},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Serializes to a JSON-compatible map for [BenchmarkHistoryStore].
  /// Durations/enums have no native JSON representation, so they're
  /// written out as milliseconds/`.name` and reversed in [fromJson].
  Map<String, dynamic> toJson() => {
        'type': type.name,
        'intensity': intensity.name,
        'actualDurationMs': actualDuration.inMilliseconds,
        'aborted': aborted,
        'abortReason': abortReason,
        'score': score,
        'peakTemperatureC': peakTemperatureC,
        'throttleDetected': throttleDetected,
        'details': details,
        'timestamp': timestamp.toIso8601String(),
      };

  /// Reverses [toJson]. Returns null (never throws) on malformed input
  /// — e.g. a history file from an older app version with a field
  /// that's since been removed, or hand-edited/corrupted JSON — so one
  /// bad line in the history file doesn't take down the whole reader,
  /// consistent with this app's "degrade gracefully, never crash on a
  /// sensor/storage read" convention (see e.g. BackgroundSensorFeed).
  static BenchmarkResult? fromJson(Map<String, dynamic> json) {
    try {
      return BenchmarkResult(
        type: BenchmarkType.values.byName(json['type'] as String),
        intensity: BenchmarkIntensity.values.byName(json['intensity'] as String),
        actualDuration: Duration(milliseconds: json['actualDurationMs'] as int),
        aborted: json['aborted'] as bool? ?? false,
        abortReason: json['abortReason'] as String?,
        score: (json['score'] as num?)?.toDouble(),
        peakTemperatureC: (json['peakTemperatureC'] as num?)?.toDouble(),
        throttleDetected: json['throttleDetected'] as bool? ?? false,
        details: (json['details'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ?? const {},
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  String get summaryLine {
    if (aborted) return 'Gestopt: ${abortReason ?? 'onbekende reden'}';
    switch (type) {
      case BenchmarkType.cpu:
        return score != null
            ? '${score!.toStringAsFixed(1)} miljoen bewerkingen/s (gecombineerd)'
            : 'Geen score beschikbaar';
      case BenchmarkType.memory:
        return score != null
            ? '${score!.toStringAsFixed(1)} GB/s kopieersnelheid (sequentieel)'
            : 'Geen score beschikbaar';
      case BenchmarkType.disk:
        return score != null
            ? '${score!.toStringAsFixed(1)} MB/s gemiddeld (sequentieel)'
            : 'Geen score beschikbaar';
      case BenchmarkType.network:
        return score != null
            ? '${score!.toStringAsFixed(0)} MB/s (loopback)'
            : 'Geen score beschikbaar';
      case BenchmarkType.crypto:
        return score != null
            ? '${score!.toStringAsFixed(0)} MB/s SHA-256 (gecombineerd)'
            : 'Geen score beschikbaar';
      case BenchmarkType.gpu:
        return score != null
            ? (details['modus'] == 'compute'
                ? '${score!.toStringAsFixed(0)} punten (glmark2)'
                : '${score!.toStringAsFixed(0)} frames gerenderd')
            : 'Geen score beschikbaar';
    }
  }
}

/// A single battery-drain measurement — separate from BenchmarkResult
/// since it doesn't fit the same "higher score is better" shape and
/// only applies to machines that have a battery at all.
class BatteryTestResult {
  final bool aborted;
  final String? abortReason;
  final Duration actualDuration;
  final int startCapacityPercent;
  final int endCapacityPercent;

  /// Extrapolated drain rate, in percent per hour, based on the
  /// measured drop over [actualDuration]. Null if the test was too
  /// short or aborted before a meaningful drop was measured.
  final double? percentPerHour;

  /// Gemiddeld verbruik tijdens de test in watt, en de daaruit volgende
  /// looptijd van een volle accu (uren) bij deze belasting. Alleen gevuld
  /// als de machine mWh/mW kan leveren (fijner dan hele procenten).
  final double? averagePowerWatts;
  final double? estimatedRuntimeHours;

  /// Korte uitleg over hoe het getal tot stand kwam (voor het scherm).
  final String? methodNote;

  const BatteryTestResult({
    required this.aborted,
    this.abortReason,
    required this.actualDuration,
    required this.startCapacityPercent,
    required this.endCapacityPercent,
    this.percentPerHour,
    this.averagePowerWatts,
    this.estimatedRuntimeHours,
    this.methodNote,
  });
}
