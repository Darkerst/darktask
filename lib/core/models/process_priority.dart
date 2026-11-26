/// A process' scheduling priority, using the same six-level naming
/// Windows' own Task Manager uses (Idle/Below normal/Normal/Above
/// normal/High/Realtime) — familiar to anyone who's used it, and
/// mapped to the closest equivalent on Linux (see
/// [ProcessPriorityMapping.linuxNiceValue]'s doc for why that mapping
/// is an approximation, not an exact match).
enum ProcessPriority { idle, belowNormal, normal, aboveNormal, high, realtime }

extension ProcessPriorityLabel on ProcessPriority {
  String get label {
    switch (this) {
      case ProcessPriority.idle:
        return 'Idle';
      case ProcessPriority.belowNormal:
        return 'Lager dan normaal';
      case ProcessPriority.normal:
        return 'Normaal';
      case ProcessPriority.aboveNormal:
        return 'Hoger dan normaal';
      case ProcessPriority.high:
        return 'Hoog';
      case ProcessPriority.realtime:
        return 'Realtime';
    }
  }
}

extension ProcessPriorityMapping on ProcessPriority {
  /// The Win32 `*_PRIORITY_CLASS` constant (from `WinBase.h`) matching
  /// this level — passed straight to `SetPriorityClass`/compared
  /// against `GetPriorityClass`'s return value.
  int get windowsPriorityClass {
    switch (this) {
      case ProcessPriority.idle:
        return 0x00000040; // IDLE_PRIORITY_CLASS
      case ProcessPriority.belowNormal:
        return 0x00004000; // BELOW_NORMAL_PRIORITY_CLASS
      case ProcessPriority.normal:
        return 0x00000020; // NORMAL_PRIORITY_CLASS
      case ProcessPriority.aboveNormal:
        return 0x00008000; // ABOVE_NORMAL_PRIORITY_CLASS
      case ProcessPriority.high:
        return 0x00000080; // HIGH_PRIORITY_CLASS
      case ProcessPriority.realtime:
        return 0x00000100; // REALTIME_PRIORITY_CLASS
    }
  }

  /// Reverses [windowsPriorityClass] — used to show a process' current
  /// priority in the UI. Returns null for a value that doesn't match
  /// any of the six classes above (shouldn't happen for a value
  /// `GetPriorityClass` actually returned, but a process that exited
  /// between the read and the check could plausibly return 0).
  static ProcessPriority? fromWindowsPriorityClass(int value) {
    for (final p in ProcessPriority.values) {
      if (p.windowsPriorityClass == value) return p;
    }
    return null;
  }

  /// Linux has no discrete priority *classes* the way Windows does —
  /// `nice` is a continuous -20 (most favored) .. +19 (least favored)
  /// scale, and genuine realtime scheduling (SCHED_FIFO/SCHED_RR) is a
  /// completely different mechanism (`chrt`, needs CAP_SYS_NICE) that
  /// this app doesn't attempt to drive. This mapping picks a
  /// reasonable nice value for each Windows-style label so the same
  /// six-level picker works on both platforms — "Realtime" here still
  /// just means "the most aggressive regular-scheduler nice value,"
  /// not true realtime scheduling, and the Linux side of the app is
  /// explicit about that in its own doc/log text rather than silently
  /// pretending it's equivalent.
  int get linuxNiceValue {
    switch (this) {
      case ProcessPriority.idle:
        return 19;
      case ProcessPriority.belowNormal:
        return 10;
      case ProcessPriority.normal:
        return 0;
      case ProcessPriority.aboveNormal:
        return -5;
      case ProcessPriority.high:
        return -10;
      case ProcessPriority.realtime:
        return -20;
    }
  }

  /// Reverses [linuxNiceValue] approximately — picks whichever of the
  /// six levels' nice value is closest to [niceValue], since `nice` is
  /// continuous and a process may be sitting at a value none of the
  /// six presets produce (e.g. set by some other tool).
  static ProcessPriority fromLinuxNiceValue(int niceValue) {
    ProcessPriority closest = ProcessPriority.normal;
    var closestDistance = 999;
    for (final p in ProcessPriority.values) {
      final distance = (p.linuxNiceValue - niceValue).abs();
      if (distance < closestDistance) {
        closest = p;
        closestDistance = distance;
      }
    }
    return closest;
  }
}
