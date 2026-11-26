/// One sensor's running minimum/maximum/average since the app was
/// launched (or since [SensorStatsTracker.reset] was last called) —
/// the same "since start" min/max/avg columns HWiNFO64 shows next to
/// every live sensor reading, which is the concrete feature this class
/// exists to support (see [SensorStatsTracker]'s own doc).
///
/// Deliberately just a running sum/count/min/max, not a stored sample
/// history — HWiNFO64's own min/max/avg is a single running summary
/// across the whole session, not a windowed graph (this app's existing
/// `Queue<double>` histories in `PerformanceScreen` already cover the
/// graph use case, at a bounded length that wouldn't be honest to
/// present as an all-time minimum/maximum). O(1) memory and update
/// cost regardless of how long the app has been running.
class RunningSensorStat {
  double? _min;
  double? _max;
  double _sum = 0;
  int _count = 0;

  double? get min => _min;
  double? get max => _max;
  double? get average => _count == 0 ? null : _sum / _count;
  int get count => _count;

  void record(double value) {
    // NaN/infinite readings are a sign something upstream misread a
    // sensor, not a real value — silently ignored here rather than
    // corrupting the running min/max/average for the rest of the
    // session (the same "an implausible value means a bug, not a
    // reading" principle this app's native readers already apply).
    if (value.isNaN || value.isInfinite) return;
    if (_min == null || value < _min!) _min = value;
    if (_max == null || value > _max!) _max = value;
    _sum += value;
    _count++;
  }

  void reset() {
    _min = null;
    _max = null;
    _sum = 0;
    _count = 0;
  }
}

/// App-lifetime singleton tracking min/max/average for every sensor any
/// screen chooses to feed into it — deliberately not its own polling
/// loop. Every screen that already reads a sensor value for its own
/// live display or graph (see `PerformanceScreen._poll()`'s existing
/// `_pushHistory` calls) additionally calls [record] with the same
/// value, so there is no extra sensor polling anywhere in the app just
/// for this feature: this class is purely a passive recorder fed by
/// work that was already happening.
///
/// Because this is a singleton rather than per-screen state, the
/// running stats survive navigating away from and back to a screen
/// (screens are mounted/unmounted as the user switches tabs — see
/// `_HomeShellState._buildScreen`), matching what "since app start"
/// should mean rather than accidentally meaning "since this tab was
/// last opened".
///
/// Keys are free-form strings the caller picks (e.g. `'cpuLoad'`,
/// `'cpuTempC'`, `'gpuLoad:<id>'`) — no fixed enum, since the set of
/// GPUs (and therefore GPU-keyed stats) isn't known until runtime.
class SensorStatsTracker {
  SensorStatsTracker._();
  static final SensorStatsTracker instance = SensorStatsTracker._();

  final Map<String, RunningSensorStat> _stats = {};

  void record(String key, double? value) {
    if (value == null) return;
    _stats.putIfAbsent(key, () => RunningSensorStat()).record(value);
  }

  /// Returns the running stat for [key], or null if nothing has been
  /// recorded under that key yet (e.g. right after app launch, before
  /// the first poll completes).
  RunningSensorStat? operator [](String key) => _stats[key];

  /// Clears every tracked stat — offered for a future "reset stats"
  /// action (mirroring HWiNFO64's own "Reset Min/Max Peaks" button);
  /// not wired to any UI yet.
  void resetAll() {
    for (final stat in _stats.values) {
      stat.reset();
    }
  }
}
