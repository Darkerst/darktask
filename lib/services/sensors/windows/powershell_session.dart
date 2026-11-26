import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';

const _logSource = 'PowerShellSession';

/// Most extra time a queued command may wait for slower commands ahead
/// of it, on top of its own timeout.
const _maxQueueAllowance = Duration(seconds: 30);

/// One-line PowerShell function definition, written to the session's
/// stdin at startup. See the comment where it is written.
const _invokeScOemFunction =
    r'function global:Invoke-ScOem { $prev = [Console]::OutputEncoding; try { '
    r'[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage); '
    r'& sc.exe @args 2>&1 } finally { [Console]::OutputEncoding = $prev } }'
    '\n';

/// A long-lived PowerShell process that commands are fed to over stdin,
/// with each command's output read back from stdout — avoiding the
/// ~200-500ms startup cost of spawning a fresh `powershell.exe` process
/// for every single poll (the same reasoning as this app's Linux side
/// keeping a persistent `intel_gpu_top` process alive instead of
/// spawning/killing it every second — see GpuSensorMixin).
///
/// **Verification note**: this class was written without access to an
/// actual Windows machine to test against. The PowerShell invocation,
/// stdin-command framing, and encoding handling below are believed
/// correct based on documented PowerShell behavior, but this is the
/// single highest-risk piece of the Windows port to verify first if
/// something doesn't work — start by running the app with a terminal
/// visible and checking the Log screen for "PowerShellSession" entries.
///
/// Framing: each command's output is followed by a unique sentinel line
/// (`___DARKTASK_END_<n>___`) so this class can tell where one
/// response ends and the next begins in the continuous stdout stream —
/// PowerShell itself has no built-in request/response protocol for
/// this, so the sentinel is a minimal hand-rolled one. Only one command
/// is in flight at a time (a simple FIFO queue), which keeps this
/// framing unambiguous at the cost of not pipelining requests — fine
/// for a monitoring poll cadence of ~1 request/second.
class PowerShellSession {
  Process? _process;
  bool _starting = false;
  int _requestCounter = 0;
  final _queue = <_PendingRequest>[];
  StringBuffer _stdoutBuffer = StringBuffer();
  bool _disposed = false;

  /// Runs [script] (any valid PowerShell, typically ending in
  /// `ConvertTo-Json -Compress` so the result can be parsed directly)
  /// and returns its raw stdout text for that command only. Returns
  /// null if the session couldn't be started/kept alive (e.g.
  /// PowerShell isn't on PATH) — callers should treat that the same as
  /// "this sensor is unavailable," not crash.
  ///
  /// [timeout] is how long this command itself may take (default 8 s).
  /// A command queued behind slower ones is additionally allowed to wait
  /// for them — see the deadline calculation below — so a heavy command
  /// (e.g. the LibreHardwareMonitor init) no longer makes every command
  /// queued behind it time out at the same moment.
  Future<String?> run(String script, {Duration timeout = const Duration(seconds: 8)}) async {
    if (_disposed) return null;
    if (_process == null && !_starting) {
      final started = await _start();
      if (!started) return null;
    }
    // If another caller's _start() is in flight, wait for it rather
    // than racing to spawn a second PowerShell process.
    while (_starting) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    if (_process == null) return null;

    final id = _requestCounter++;
    final completer = Completer<String?>();

    // The session runs one command at a time, so this command cannot
    // even start until every earlier one has finished. Counting its
    // timeout from the moment it is written to stdin made everything
    // queued behind a slow command (seen at app start: the
    // LibreHardwareMonitor init taking >8 s) time out too, although
    // PowerShell would have answered a moment later. The deadline
    // therefore also includes the budgets of the commands ahead of it
    // that have not timed out yet, capped so a genuinely hung session
    // is still detected in a bounded time.
    var deadline = timeout;
    for (final ahead in _queue) {
      if (!ahead.expired) deadline += ahead.budget;
    }
    final maxDeadline = timeout + _maxQueueAllowance;
    if (deadline > maxDeadline) deadline = maxDeadline;

    final pending = _PendingRequest(id, completer, timeout);
    _queue.add(pending);

    final sentinel = '___DARKTASK_END_${id}___';
    // Errors inside `script` shouldn't kill the whole session — wrap in
    // try/catch so a single bad query just yields empty output for
    // that one call rather than desyncing the stdin/stdout framing.
    final wrapped = 'try { $script } catch { } \nWrite-Output "$sentinel"\n';
    try {
      _process!.stdin.write(wrapped);
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to write to PowerShell stdin: $e');
      _queue.remove(pending);
      return null;
    }

    return completer.future.timeout(
      deadline,
      onTimeout: () {
        pending.expired = true;
        // Only the start of the script is logged: some commands are
        // several kilobytes long and used to flood the log.
        final oneLine = script.replaceAll(RegExp(r'\s+'), ' ').trim();
        final shown = oneLine.length > 200 ? '${oneLine.substring(0, 200)}… (+${oneLine.length - 200} tekens)' : oneLine;
        AppLogger.instance.debug(_logSource, 'PowerShell command timed out (na ${deadline.inSeconds}s): $shown');
        return null;
      },
    );
  }

  Future<bool> _start() async {
    _starting = true;
    try {
      // -NoLogo/-NoProfile: skip banner and user profile scripts (both
      // slow startup and irrelevant here). -NonInteractive: don't wait
      // for a TTY. -Command -: read commands from stdin as an ongoing
      // stream rather than executing one command and exiting.
      final process = await Process.start(
        'powershell.exe',
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '-'],
      );
      _process = process;

      // Force UTF-8 so non-ASCII (accented characters in device names,
      // etc.) round-trips correctly instead of getting mangled by
      // whatever the default console code page is.
      process.stdin.encoding = utf8;

      // Decoded as UTF-8 to match the `[Console]::OutputEncoding` set
      // below. Decoding with SystemEncoding (the ANSI code page)
      // instead garbled every non-ASCII character PowerShell wrote —
      // "°C" turned into "\uFFFDC" and "geïnstalleerd" into
      // "ge\uFFFDnstalleerd" in the log. allowMalformed keeps one bad
      // byte from killing the whole stream.
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
        _handleStdoutChunk,
        onError: (Object e) => AppLogger.instance.debug(_logSource, 'stdout stream error: $e'),
      );
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) AppLogger.instance.debug(_logSource, 'stderr: $trimmed');
      });

      unawaited(process.exitCode.then((code) {
        AppLogger.instance.info(_logSource, 'PowerShell session exited (code $code)');
        _process = null;
        // Fail every request still waiting rather than leaving them
        // hanging until their timeout.
        for (final pending in _queue) {
          if (!pending.completer.isCompleted) pending.completer.complete(null);
        }
        _queue.clear();
      }));

      process.stdin.write('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; \$OutputEncoding = [System.Text.Encoding]::UTF8\n');
      // sc.exe writes its (localized) messages in the OEM code page, not
      // UTF-8, so with the console output encoding forced to UTF-8
      // above, PowerShell would decode e.g. "geïnstalleerde" wrongly.
      // Invoke-ScOem switches the console encoding to the OEM code page
      // just for the duration of one sc.exe call and restores it after.
      process.stdin.write(_invokeScOemFunction);
      _starting = false;
      return true;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to start powershell.exe: $e');
      _process = null;
      _starting = false;
      return false;
    }
  }

  void _handleStdoutChunk(String chunk) {
    _stdoutBuffer.write(chunk);
    final text = _stdoutBuffer.toString();
    final lines = text.split('\n');
    // The last split segment may be a partial line (chunk boundary
    // landed mid-line) — keep it in the buffer for the next chunk
    // rather than treating it as complete.
    final complete = lines.sublist(0, lines.length - 1);
    _stdoutBuffer = StringBuffer(lines.last);

    for (final rawLine in complete) {
      final line = rawLine.trimRight();
      final sentinelMatch = RegExp(r'^___DARKTASK_END_(\d+)___$').firstMatch(line);
      if (sentinelMatch != null) {
        final id = int.parse(sentinelMatch.group(1)!);
        final index = _queue.indexWhere((p) => p.id == id);
        if (index == -1) continue; // stray/duplicate sentinel — ignore
        final pending = _queue.removeAt(index);
        if (!pending.completer.isCompleted) {
          pending.completer.complete(pending.output.toString());
        }
      } else if (_queue.isNotEmpty) {
        // Belongs to whichever request is oldest/still pending —
        // correct as long as only one command is in flight at a time
        // (enforced by run() awaiting completion before the next
        // caller's write, in practice — callers issue requests
        // sequentially since each is awaited).
        _queue.first.output.writeln(line);
      }
    }
  }

  /// Stops the background PowerShell process. Call when the owning
  /// service is disposed so it doesn't outlive the app.
  void dispose() {
    _disposed = true;
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
    for (final pending in _queue) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
    }
    _queue.clear();
  }
}

class _PendingRequest {
  final int id;
  final Completer<String?> completer;
  final StringBuffer output = StringBuffer();

  /// How long this command itself may take, and whether its caller has
  /// already given up on it (its own deadline passed). Used to work out
  /// how long commands queued behind it should be willing to wait.
  final Duration budget;
  bool expired = false;

  _PendingRequest(this.id, this.completer, this.budget);

  @override
  bool operator ==(Object other) => other is _PendingRequest && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
