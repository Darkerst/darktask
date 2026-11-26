import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/process_info.dart';
import '../core/models/process_priority.dart';
import 'sensors/windows/native_process_control.dart';
import 'sensors/windows/powershell_session.dart';
import 'sensors/windows/process_snapshot_reader.dart';

const _logSource = 'ProcessService';

/// Lists running processes. Linux uses `ps` (matches the level of
/// complexity Hardware Tester's Applications test already uses for
/// process detection); Windows uses direct Win32 APIs (see
/// [ProcessSnapshotReader]) for process/CPU%/memory — the same specific
/// approach Dave Plummer's own open-source `tm` console task manager
/// uses, confirmed from that project's README rather than assumed —
/// with owner/responsiveness enrichment layered on top via a separately
/// (and less frequently) cached PowerShell call, since that specific
/// data changes far less often than CPU%/memory do.
class ProcessService {
  final ProcessSnapshotReader _windowsSnapshot = ProcessSnapshotReader();
  final NativeProcessControl _windowsProcessControl = NativeProcessControl();

  // Lazily created only on Windows, and only once — spawning a fresh
  // powershell.exe per poll would cost ~200-500ms every single time,
  // noticeable at this app's ~1-2s poll cadence (same reasoning as
  // WindowsSensorService's shared session). Used only for the
  // owner/responsiveness enrichment below now — the process/CPU%/
  // memory data itself no longer goes through PowerShell at all.
  PowerShellSession? _windowsShell;

  // Owner/responsiveness genuinely changes far less often than CPU%/
  // memory — a process's user and whether its window is responding
  // are stable for most of a process's life, unlike load figures that
  // move every second. Cached longer than a single poll interval so
  // most polls skip this PowerShell round-trip entirely and just reuse
  // the last-known values, while the native snapshot above still
  // refreshes CPU%/memory every single call.
  Map<int, ({String? userName, bool? responding})>? _windowsOwnerCache;
  DateTime? _windowsOwnerCacheTime;
  static const _windowsOwnerCacheTtl = Duration(seconds: 5);

  Future<List<ProcessInfo>> listProcesses() {
    return Platform.isWindows ? _listProcessesWindows() : _listProcessesLinux();
  }

  Future<List<ProcessInfo>> _listProcessesLinux() async {
    try {
      final result = await Process.run('ps', [
        '-eo',
        'pid,user,pcpu,rss,stat,comm',
        '--no-headers',
      ]);

      if (result.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'ps exited with ${result.exitCode}: ${result.stderr}');
        return [];
      }

      final lines = (result.stdout as String).split('\n').where((l) => l.trim().isNotEmpty);
      final processes = <ProcessInfo>[];

      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 6) continue;

        final pid = int.tryParse(parts[0]);
        final user = parts[1];
        final cpu = double.tryParse(parts[2]);
        final rssKiB = int.tryParse(parts[3]);
        final state = parts[4];
        final name = parts.sublist(5).join(' ');

        if (pid == null || cpu == null || rssKiB == null) continue;

        processes.add(ProcessInfo(
          pid: pid,
          name: name,
          cpuPercent: cpu,
          memoryKiB: rssKiB,
          user: user,
          state: state,
        ));
      }

      processes.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
      return processes;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list processes: $e\n$st');
      return [];
    }
  }

  /// [ProcessSnapshotReader] gives process identity, CPU%, and memory
  /// directly from Win32 — no WMI/PowerShell round-trip for this part
  /// at all anymore. Owner/responsiveness (which genuinely doesn't
  /// change often — see [_windowsOwnerCacheTtl]'s own doc) is merged in
  /// from a separately-cached PowerShell call.
  Future<List<ProcessInfo>> _listProcessesWindows() async {
    final snapshot = _windowsSnapshot.readAll();
    if (snapshot == null) {
      // The native reader disabled itself (or genuinely can't run on
      // this machine) — rather than returning nothing, this is exactly
      // the kind of total-fallback situation worth having a second
      // path for. PowerShell/WMI, slower but independent of whatever
      // made the native path fail, still works here as a last resort.
      return _listProcessesWindowsViaWmiFallback();
    }

    final ownerByPid = await _windowsOwnerInfo();

    final processes = <ProcessInfo>[];
    for (final p in snapshot) {
      final owner = ownerByPid[p.pid];
      // A NULL UserName from Get-Process (as opposed to a missing map
      // entry) genuinely happens for protected system processes even
      // when elevated (e.g. some Windows services running as SYSTEM/
      // LOCAL SERVICE report no owner via this cmdlet) — kept as a
      // dash rather than a fabricated guess.
      final user = owner?.userName ?? '—';
      // Windows has no single-letter run-state column the way Linux's
      // `ps` STAT field does — Responding (whether a GUI process'
      // message loop is answering) is the closest available signal,
      // shown for processes that have one; most background/console
      // processes have no message pump at all, so Responding is
      // trivially true for them and not meaningfully different from
      // "no information" — shown as a dash there rather than a
      // falsely-precise "Actief" for something that was never actually
      // checked in any meaningful sense.
      final state = owner?.responding == false ? 'Reageert niet' : (owner?.responding == true ? 'Actief' : '—');

      processes.add(ProcessInfo(
        pid: p.pid,
        name: p.name,
        cpuPercent: p.cpuPercent,
        memoryKiB: (p.workingSetBytes / 1024).round(),
        user: user,
        state: state,
      ));
    }

    processes.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
    return processes;
  }

  /// PID -> (username, responding), refreshed at most once every
  /// [_windowsOwnerCacheTtl] — a single `Get-Process -IncludeUserName`
  /// call covers every process' owner and responsiveness in one pass,
  /// same reasoning as before, just now decoupled from the (now much
  /// faster, no-longer-PowerShell-based) core process list refresh
  /// rate.
  Future<Map<int, ({String? userName, bool? responding})>> _windowsOwnerInfo() async {
    final cached = _windowsOwnerCache;
    final cachedAt = _windowsOwnerCacheTime;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _windowsOwnerCacheTtl) {
      return cached;
    }

    try {
      _windowsShell ??= PowerShellSession();
      final result = await _windowsShell!.run(
        "Get-Process -IncludeUserName -ErrorAction SilentlyContinue | "
        "Select-Object Id, UserName, Responding | ConvertTo-Json -Compress",
      );
      if (result == null) return cached ?? {};
      final trimmed = result.trim();
      if (trimmed.isEmpty) return cached ?? {};

      final decoded = jsonDecode(trimmed);
      final rows = decoded is List ? decoded : [decoded];

      final ownerByPid = <int, ({String? userName, bool? responding})>{};
      for (final o in rows) {
        final map = o as Map<String, dynamic>;
        final pid = (map['Id'] as num?)?.toInt();
        if (pid == null) continue;
        ownerByPid[pid] = (userName: map['UserName'] as String?, responding: map['Responding'] as bool?);
      }

      _windowsOwnerCache = ownerByPid;
      _windowsOwnerCacheTime = DateTime.now();
      return ownerByPid;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to read process owner info: $e\n$st');
      return cached ?? {};
    }
  }

  /// Only reached if [ProcessSnapshotReader] itself is unavailable
  /// (disabled after a binding failure, or somehow not on Windows) —
  /// the original WMI-based approach, kept as a complete, independent
  /// fallback rather than removed outright.
  Future<List<ProcessInfo>> _listProcessesWindowsViaWmiFallback() async {
    try {
      _windowsShell ??= PowerShellSession();
      final result = await _windowsShell!.run(
        "Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | "
        "Where-Object { \$_.Name -ne '_Total' -and \$_.Name -ne 'Idle' } | "
        "Select-Object Name, IDProcess, PercentProcessorTime, WorkingSetPrivate | ConvertTo-Json -Compress",
      );
      if (result == null) return [];
      final trimmed = result.trim();
      if (trimmed.isEmpty) return [];

      final decoded = jsonDecode(trimmed);
      final rows = decoded is List ? decoded : [decoded];
      final coreCount = Platform.numberOfProcessors;
      final ownerByPid = await _windowsOwnerInfo();

      final processes = <ProcessInfo>[];
      for (final row in rows) {
        final map = row as Map<String, dynamic>;
        final pid = (map['IDProcess'] as num?)?.toInt();
        if (pid == null || pid == 0) continue;

        var name = (map['Name'] as String?) ?? '?';
        name = name.replaceAll(RegExp(r'#\d+$'), '');

        final rawCpu = (map['PercentProcessorTime'] as num?)?.toDouble() ?? 0;
        final cpu = coreCount > 0 ? rawCpu / coreCount : rawCpu;
        final memBytes = (map['WorkingSetPrivate'] as num?)?.toDouble() ?? 0;

        final owner = ownerByPid[pid];
        final user = owner?.userName ?? '—';
        final state = owner?.responding == false ? 'Reageert niet' : (owner?.responding == true ? 'Actief' : '—');

        processes.add(ProcessInfo(
          pid: pid,
          name: name,
          cpuPercent: cpu,
          memoryKiB: (memBytes / 1024).round(),
          user: user,
          state: state,
        ));
      }

      processes.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
      return processes;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list processes (Windows, WMI fallback): $e\n$st');
      return [];
    }
  }

  /// Current scheduling priority, or null if it couldn't be read (a
  /// protected process, one that's already exited, or — on Linux —
  /// `ps` itself failing).
  Future<ProcessPriority?> getPriority(int pid) async {
    if (Platform.isWindows) {
      final value = _windowsProcessControl.getPriorityClass(pid);
      if (value == null) return null;
      return ProcessPriorityMapping.fromWindowsPriorityClass(value);
    }
    try {
      final result = await Process.run('ps', ['-o', 'ni=', '-p', pid.toString()]);
      if (result.exitCode != 0) return null;
      final nice = int.tryParse((result.stdout as String).trim());
      return nice == null ? null : ProcessPriorityMapping.fromLinuxNiceValue(nice);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon nice-waarde niet lezen voor PID $pid: $e');
      return null;
    }
  }

  /// Attempts to change [pid]'s scheduling priority to [priority].
  /// Returns false (never throws) on failure — most commonly access
  /// denied, for a process running as a different/more privileged
  /// user, or one of the handful Windows itself protects outright.
  /// Callers should confirm with the user before invoking this,
  /// same as [killProcess] — same reasoning: this changes a process
  /// that may not be theirs to freely reconfigure.
  Future<bool> setPriority(int pid, ProcessPriority priority) async {
    if (Platform.isWindows) {
      final ok = _windowsProcessControl.setPriorityClass(pid, priority.windowsPriorityClass);
      AppLogger.instance.info(
        _logSource,
        'SetPriorityClass PID $pid -> ${priority.label} (${ok ? 'gelukt' : 'mislukt, waarschijnlijk toegang geweigerd'})',
      );
      return ok;
    }
    try {
      // renice can only LOWER a process' priority (raise its nice
      // value) without root — going the other way (a negative nice
      // value, i.e. "Above normal"/"High"/"Realtime" here) needs
      // CAP_SYS_NICE, which this app doesn't request/escalate for,
      // consistent with killProcess never using pkexec either. That
      // attempt will simply fail with a permission error below rather
      // than silently no-op, so the UI still gets an honest false.
      final result =
          await Process.run('renice', ['-n', priority.linuxNiceValue.toString(), '-p', pid.toString()]);
      AppLogger.instance.info(
        _logSource,
        'renice -n ${priority.linuxNiceValue} -p $pid (exit ${result.exitCode})',
      );
      return result.exitCode == 0;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to renice PID $pid: $e');
      return false;
    }
  }

  /// `(processMask, systemMask)` — which logical CPUs this process is
  /// allowed to run on, and which logical CPUs exist at all. Null if
  /// unavailable. On Linux, bit `i` of each mask corresponds to CPU
  /// `i` as reported by `taskset`, matching the Windows bitmask shape
  /// exactly so the UI's checkbox row needs no platform-specific code.
  Future<({int process, int system})?> getAffinity(int pid) async {
    if (Platform.isWindows) {
      return _windowsProcessControl.getAffinityMasks(pid);
    }
    try {
      final result = await Process.run('taskset', ['-p', pid.toString()]);
      if (result.exitCode != 0) return null;
      // Output looks like: "pid 1234's current affinity mask: 3"
      final match = RegExp(r'mask:\s*([0-9a-fA-F]+)').firstMatch(result.stdout as String);
      if (match == null) return null;
      final processMask = int.parse(match.group(1)!, radix: 16);
      final systemMask = (1 << Platform.numberOfProcessors) - 1;
      return (process: processMask, system: systemMask);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon CPU-affinity niet lezen voor PID $pid: $e');
      return null;
    }
  }

  /// Attempts to restrict [pid] to the logical CPUs set in [mask] (one
  /// bit per CPU). Same confirm-before-calling expectation and
  /// failure semantics as [setPriority].
  Future<bool> setAffinity(int pid, int mask) async {
    if (Platform.isWindows) {
      final ok = _windowsProcessControl.setAffinityMask(pid, mask);
      AppLogger.instance.info(
        _logSource,
        'SetProcessAffinityMask PID $pid -> 0x${mask.toRadixString(16)} (${ok ? 'gelukt' : 'mislukt'})',
      );
      return ok;
    }
    try {
      final result =
          await Process.run('taskset', ['-p', mask.toRadixString(16), pid.toString()]);
      AppLogger.instance.info(
        _logSource,
        'taskset -p ${mask.toRadixString(16)} $pid (exit ${result.exitCode})',
      );
      return result.exitCode == 0;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to set affinity for PID $pid: $e');
      return false;
    }
  }

  /// Sends SIGTERM to a process on Linux (mirrors Hardware Tester's
  /// "safe PID-only termination" convention), or the closest Windows
  /// equivalent otherwise. Callers should confirm with the user before
  /// invoking this either way.
  Future<bool> killProcess(int pid) async {
    if (Platform.isWindows) {
      try {
        // Windows has no SIGTERM equivalent invocable from the command
        // line for arbitrary processes — `taskkill /PID <pid>` without
        // /F only politely asks GUI processes with a message loop to
        // close, and silently fails for everything else. /F (force) is
        // the only option that reliably works across process types,
        // at the cost of being closer to Linux's SIGKILL than SIGTERM
        // in how abrupt it is.
        final result = await Process.run('taskkill', ['/PID', pid.toString(), '/F']);
        AppLogger.instance.info(_logSource, 'taskkill /PID $pid /F (exit ${result.exitCode})');
        return result.exitCode == 0;
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Failed to kill PID $pid: $e');
        return false;
      }
    }
    try {
      final result = await Process.run('kill', ['-TERM', pid.toString()]);
      AppLogger.instance.info(_logSource, 'Sent SIGTERM to PID $pid (exit ${result.exitCode})');
      return result.exitCode == 0;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to kill PID $pid: $e');
      return false;
    }
  }
}
