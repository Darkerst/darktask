/// A single logged-in user session (from `who`), enriched with
/// aggregate resource usage across that user's processes (from `ps`).
class UserSession {
  final String username;
  final String terminal;
  final String loginTime; // as reported by `who`, e.g. "2026-08-31 10:15"
  final String? host; // remote host or display, e.g. ":0" or an IP
  final String? idle;
  final int? pid; // PID of the login shell/session leader, if reported

  final int processCount;
  final double cpuPercent;
  final int memoryKiB;

  const UserSession({
    required this.username,
    required this.terminal,
    required this.loginTime,
    this.host,
    this.idle,
    this.pid,
    this.processCount = 0,
    this.cpuPercent = 0,
    this.memoryKiB = 0,
  });
}
