import 'dart:async';

import '../core/models/cpu_sample.dart';
import 'sensors/system_sensor_service.dart';

/// Shared, reference-counted CPU load/temperature poll for
/// [BenchmarkService]'s CPU, memory, and crypto tests — the three
/// whose safety timers need to watch CPU temperature, since all three
/// keep cores busy.
///
/// Why this exists: each of those tests used to run its own
/// independent `Timer.periodic(2s)` calling `sensors.readCpu()`
/// directly. That's fine when only one test runs at a time, but
/// "Alles tegelijk" (stress-everything) starts CPU, memory, *and*
/// crypto concurrently — three separate timers all hitting the same
/// underlying Windows sensor pathway (a single persistent PowerShell/
/// LibreHardwareMonitor session, or PDH) at roughly the same moments.
/// That self-inflicted contention was reproduced in testing: CPU-test
/// and memory-test both hit 3 consecutive 5-second read timeouts
/// within seconds of each other and aborted themselves — not because
/// the CPU was actually too hot to safely monitor, but because
/// DarkTask's own three redundant pollers were queuing up behind each
/// other on one shared, effectively single-threaded backend.
///
/// The fix is one shared poll instead of three competing ones: whoever
/// currently needs CPU temperature calls [acquire] when their test
/// starts and [release] when it ends (ref-counted, so it keeps polling
/// as long as at least one test is watching, and stops entirely once
/// none are); every 2-second tick, each active test just reads
/// [latest]/[lastSuccessAt] — a plain field read, never a sensor call
/// of its own — so three concurrent tests cost exactly the same one
/// `readCpu()` call every 2 seconds that a single test running alone
/// already made.
class BenchmarkCpuTempFeed {
  BenchmarkCpuTempFeed(this._sensors);
  final SystemSensorService _sensors;

  static const pollInterval = Duration(seconds: 2);

  /// How long a reading may be missing before a caller should treat
  /// the feed as stale — matches the per-call timeout the old
  /// per-test pollers used, so a caller's own "3 stale ticks in a row"
  /// escalation logic sees roughly the same timing it did before.
  static const staleAfter = Duration(seconds: 5);

  int _refCount = 0;
  Timer? _timer;
  bool _polling = false;

  CpuSample? _latest;
  DateTime? _lastSuccessAt;

  CpuSample? get latest => _latest;
  DateTime? get lastSuccessAt => _lastSuccessAt;

  /// True once [lastSuccessAt] is either unset, or older than
  /// [staleAfter] — i.e. this tick should count as a failed reading
  /// for whatever "N consecutive failures" escalation the caller runs.
  bool get isStale {
    final at = _lastSuccessAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > staleAfter;
  }

  /// Registers one more consumer. The first caller to acquire starts
  /// the shared timer (and fires an immediate poll rather than waiting
  /// out the first interval); later callers just bump the ref count
  /// and read whatever's already being kept fresh.
  void acquire() {
    _refCount++;
    if (_refCount == 1) {
      unawaited(_poll());
      _timer = Timer.periodic(pollInterval, (_) => _poll());
    }
  }

  /// Unregisters one consumer. Once the last one releases, the timer
  /// stops — no point polling CPU temperature in the background when
  /// nothing running is actually watching it.
  void release() {
    if (_refCount > 0) _refCount--;
    if (_refCount == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _poll() async {
    // Coalesce rather than pile up: if the previous tick's read is
    // still in flight when this one fires (readCpu() itself being
    // slow under full load is exactly the scenario this class exists
    // to protect against), skip starting a second one on top of it.
    if (_polling) return;
    _polling = true;
    try {
      final cpu = await _sensors.readCpu().timeout(staleAfter);
      _latest = cpu;
      _lastSuccessAt = DateTime.now();
    } catch (_) {
      // Leave the previous _latest/_lastSuccessAt in place — [isStale]
      // is what callers check, not an exception from here.
    } finally {
      _polling = false;
    }
  }
}
