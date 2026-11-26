import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/user_session.dart';

const _logSource = 'UsersService';

class UsersService {
  static final _whoLinePattern = RegExp(
    r'^(\S+)\s+(\S+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})(?:\s+(\S+))?(?:\s+(\d+))?(?:\s+\(([^)]+)\))?',
  );

  /// Lists currently logged-in sessions: `who -u` on Linux, `query
  /// user` (a built-in Windows CLI command, no PowerShell needed) on
  /// Windows.
  Future<List<UserSession>> listSessions() {
    return Platform.isWindows ? _listSessionsWindows() : _listSessionsLinux();
  }

  /// `query user`'s columns are locale-translated (same class of issue
  /// as `lscpu` elsewhere in this app) but that only affects the
  /// header row, which this skips entirely — the data rows themselves
  /// (username, session name, numeric ID, ...) aren't translated, so
  /// positional parsing after the header is safe.
  Future<List<UserSession>> _listSessionsWindows() async {
    try {
      final result = await Process.run('query', ['user']);
      final output = (result.stdout as String?) ?? '';
      if (output.trim().isEmpty) {
        if (result.exitCode != 0) {
          AppLogger.instance.debug(
              _logSource, 'query user exited with ${result.exitCode}: ${result.stderr}');
        }
        return [];
      }

      final lines = output.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.length < 2) return []; // header only — nobody logged in besides system accounts

      final sessions = <UserSession>[];
      for (final rawLine in lines.skip(1)) {
        // The active/current session is marked with a leading '>'
        // instead of a space in column 1 — strip it before splitting,
        // or it gets absorbed into the username field.
        final line = rawLine.startsWith('>') ? rawLine.substring(1) : rawLine;
        final fields = line.trim().split(RegExp(r'\s{2,}'));
        if (fields.isEmpty || fields[0].trim().isEmpty) continue;

        sessions.add(UserSession(
          username: fields[0].trim(),
          terminal: fields.length > 1 ? fields[1].trim() : '?',
          // LOGON TIME's exact format varies by Windows locale/regional
          // settings — kept as the raw trailing text rather than
          // parsed into a structured value, since guessing the format
          // wrong would show something actively misleading instead of
          // just unparsed-but-readable.
          loginTime: fields.length > 4 ? fields.sublist(4).join(' ').trim() : '',
          idle: fields.length > 3 ? fields[3].trim() : null,
          // `query user` doesn't report a remote host or a session
          // leader PID the way `who -u` does — left null rather than
          // guessed.
          host: null,
          pid: null,
        ));
      }
      // No per-user CPU/memory aggregation on Windows yet (the Linux
      // side's `ps`-based aggregate below has no direct equivalent
      // without a further WMI round-trip per user) — sessions show
      // with processCount/cpuPercent/memoryKiB at their zero defaults.
      return sessions;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list user sessions (Windows): $e\n$st');
      return [];
    }
  }

  /// Lists currently logged-in user sessions via `who -u`, enriched
  /// with each user's aggregate CPU%, memory, and process count via a
  /// single `ps` call (avoids per-user process listing round-trips).
  Future<List<UserSession>> _listSessionsLinux() async {
    try {
      final whoResult = await Process.run('who', ['-u']);
      if (whoResult.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'who exited with ${whoResult.exitCode}: ${whoResult.stderr}');
        return [];
      }

      final sessions = <UserSession>[];
      for (final line in (whoResult.stdout as String).split('\n')) {
        if (line.trim().isEmpty) continue;
        final match = _whoLinePattern.firstMatch(line);
        if (match == null) {
          AppLogger.instance.debug(_logSource, 'Unrecognized who line: $line');
          continue;
        }
        final username = match.group(1)!;
        final terminal = match.group(2)!;
        final loginTime = '${match.group(3)} ${match.group(4)}';
        final idle = match.group(5);
        final pid = match.group(6) != null ? int.tryParse(match.group(6)!) : null;
        final host = match.group(7);

        sessions.add(UserSession(
          username: username,
          terminal: terminal,
          loginTime: loginTime,
          host: host,
          idle: idle,
          pid: pid,
        ));
      }

      if (sessions.isEmpty) return sessions;

      // Aggregate CPU%/memory/process-count per username via one `ps`
      // call, then merge into the sessions above — cheaper than
      // querying per-session.
      final aggregates = await _aggregateByUser();
      final enriched = sessions.map((s) {
        final agg = aggregates[s.username];
        if (agg == null) return s;
        return UserSession(
          username: s.username,
          terminal: s.terminal,
          loginTime: s.loginTime,
          host: s.host,
          idle: s.idle,
          pid: s.pid,
          processCount: agg.processCount,
          cpuPercent: agg.cpuPercent,
          memoryKiB: agg.memoryKiB,
        );
      }).toList();

      return enriched;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list user sessions: $e\n$st');
      return [];
    }
  }

  Future<Map<String, _UserAggregate>> _aggregateByUser() async {
    final result = <String, _UserAggregate>{};
    try {
      final psResult = await Process.run('ps', ['-eo', 'user,pcpu,rss', '--no-headers']);
      if (psResult.exitCode != 0) return result;

      for (final line in (psResult.stdout as String).split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 3) continue;
        final user = parts[0];
        final cpu = double.tryParse(parts[1]) ?? 0;
        final rss = int.tryParse(parts[2]) ?? 0;

        final existing = result[user];
        if (existing == null) {
          result[user] = _UserAggregate(processCount: 1, cpuPercent: cpu, memoryKiB: rss);
        } else {
          result[user] = _UserAggregate(
            processCount: existing.processCount + 1,
            cpuPercent: existing.cpuPercent + cpu,
            memoryKiB: existing.memoryKiB + rss,
          );
        }
      }
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to aggregate per-user process stats: $e');
    }
    return result;
  }
}

class _UserAggregate {
  final int processCount;
  final double cpuPercent;
  final int memoryKiB;
  const _UserAggregate({required this.processCount, required this.cpuPercent, required this.memoryKiB});
}
