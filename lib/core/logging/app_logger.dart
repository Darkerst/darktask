import 'dart:collection';

/// Severity levels for log entries.
enum LogLevel { debug, info, warning, error }

/// A single log entry captured by [AppLogger].
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String source;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  String get levelLabel {
    switch (level) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  String format() {
    final ts = timestamp.toIso8601String();
    return '[$ts] [$levelLabel] [$source] $message';
  }
}

/// App-wide logging singleton. Every service/feature in DarkTask should
/// route its activity through here so the in-app "Master Log" screen
/// (see features/monitoring or a dedicated log viewer) can show a single
/// unified, copyable/saveable history — matching the logging convention
/// already used in Hardware Tester.
class AppLogger {
  AppLogger._internal();
  static final AppLogger instance = AppLogger._internal();

  static const int _maxEntries = 5000;
  final Queue<LogEntry> _entries = Queue<LogEntry>();
  final List<void Function(LogEntry)> _listeners = [];

  UnmodifiableListView<LogEntry> get entries => UnmodifiableListView(_entries);

  void addListener(void Function(LogEntry) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(LogEntry) listener) {
    _listeners.remove(listener);
  }

  void _log(LogLevel level, String source, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      source: source,
      message: message,
    );
    _entries.addLast(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    for (final listener in _listeners) {
      listener(entry);
    }
  }

  void debug(String source, String message) => _log(LogLevel.debug, source, message);
  void info(String source, String message) => _log(LogLevel.info, source, message);
  void warning(String source, String message) => _log(LogLevel.warning, source, message);
  void error(String source, String message) => _log(LogLevel.error, source, message);

  /// Full log as plain text, newest last — used by copy/save actions.
  String exportAsText() {
    return _entries.map((e) => e.format()).join('\n');
  }

  void clear() {
    _entries.clear();
  }
}
