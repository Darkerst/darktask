import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/network_connection.dart';

const _logSource = 'ConnectionsService';

class ConnectionsService {
  static final _processInfoPattern = RegExp(r'\(\("([^"]+)",pid=(\d+)');

  /// Whether a connections-listing backend is available at all — `ss`
  /// on Linux, or the `NetTCPIP` PowerShell module's cmdlets on
  /// Windows (built in since Windows 8 / Server 2012, so this should
  /// only ever return false there if something is very wrong with the
  /// machine).
  Future<bool> isSsAvailable() async {
    if (Platform.isWindows) {
      try {
        final result = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', 'Get-Command Get-NetTCPConnection -ErrorAction Stop | Out-Null; exit 0'],
        );
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    try {
      final result = await Process.run('ss', ['-V']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Lists active TCP/UDP connections. Process ownership (name/PID) is
  /// only visible for sockets the current user can see — typically
  /// your own processes, unless the app itself is running with
  /// elevated privileges. Connections without visible process info are
  /// still shown, just with processName/pid left null, rather than
  /// hidden.
  Future<List<NetworkConnection>> listConnections() =>
      Platform.isWindows ? _listConnectionsWindows() : _listConnectionsLinux();

  Future<List<NetworkConnection>> _listConnectionsLinux() async {
    try {
      final result = await Process.run('ss', ['-tunap']);
      if (result.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'ss exited with ${result.exitCode}: ${result.stderr}');
        return [];
      }

      final connections = <NetworkConnection>[];
      final lines = (result.stdout as String).split('\n');

      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        // Header line starts with "Netid" — skip it.
        if (line.startsWith('Netid')) continue;

        final parsed = _parseLine(line);
        if (parsed != null) connections.add(parsed);
      }

      return connections;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list connections: $e\n$st');
      return [];
    }
  }

  /// `Get-NetTCPConnection`/`Get-NetUDPEndpoint` return structured
  /// objects rather than text to parse the way `ss`'s output does —
  /// genuinely simpler and less fragile on this side, at the cost of
  /// needing two separate queries (TCP and UDP are exposed via
  /// entirely separate cmdlets on Windows, unlike `ss` which lists
  /// both together in one pass) plus a third to resolve owning PIDs to
  /// process names, since neither connection cmdlet includes that
  /// directly.
  Future<List<NetworkConnection>> _listConnectionsWindows() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue | '
            r'Select-Object @{N="proto";E={"tcp"}}, @{N="State";E={$_.State.ToString()}}, LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess; '
            r'$udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | '
            r'Select-Object @{N="proto";E={"udp"}}, @{N="State";E={"UNCONN"}}, LocalAddress, LocalPort, '
            r'@{N="RemoteAddress";E={"*"}}, @{N="RemotePort";E={"*"}}, OwningProcess; '
            r'$procs = Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName; '
            r'[PSCustomObject]@{ connections = @($tcp) + @($udp); procs = $procs } | ConvertTo-Json -Compress -Depth 4',
      ]);
      if (result.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'Get-NetTCPConnection/Get-NetUDPEndpoint failed: ${result.stderr}');
        return [];
      }
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return [];

      final decoded = jsonDecode(output) as Map<String, dynamic>;
      final procRows = decoded['procs'];
      final procList = procRows is List ? procRows : (procRows != null ? [procRows] : []);
      final pidToName = <int, String>{};
      for (final p in procList) {
        final map = p as Map<String, dynamic>;
        final id = (map['Id'] as num?)?.toInt();
        final name = map['ProcessName']?.toString();
        if (id != null && name != null) pidToName[id] = name;
      }

      final connRows = decoded['connections'];
      final connList = connRows is List ? connRows : (connRows != null ? [connRows] : []);

      final connections = <NetworkConnection>[];
      for (final c in connList) {
        final map = c as Map<String, dynamic>;
        final pid = (map['OwningProcess'] as num?)?.toInt();
        connections.add(NetworkConnection(
          protocol: map['proto']?.toString() ?? '?',
          // Windows' state names (Listen, Established, TimeWait, ...)
          // mapped onto the exact vocabulary the shared UI already
          // filters and colors by ('ESTAB', 'LISTEN', 'TIME-WAIT',
          // 'CLOSE-WAIT', 'UNCONN') — matched case-insensitively since
          // Get-NetTCPConnection's State values aren't consistently
          // cased the same way ss's are. Uses toString() rather than a
          // direct String cast: State is a .NET enum on the PowerShell
          // side, and even with the explicit .ToString() this script
          // now applies at the source (see above), defending against
          // it arriving as the raw integer ordinal is cheap insurance
          // against exactly the crash this was hit by in testing.
          state: _mapWindowsState(map['State']?.toString() ?? ''),
          localAddress: map['LocalAddress']?.toString() ?? '',
          localPort: map['LocalPort']?.toString() ?? '',
          peerAddress: map['RemoteAddress']?.toString() ?? '',
          peerPort: map['RemotePort']?.toString() ?? '',
          processName: pid != null ? pidToName[pid] : null,
          pid: pid,
        ));
      }
      return connections;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list connections (Windows): $e\n$st');
      return [];
    }
  }

  String _mapWindowsState(String state) {
    switch (state.toLowerCase()) {
      case 'established':
        return 'ESTAB';
      // PowerShell's Get-NetTCPConnection uses 'Listen' for this state;
      // 'bound' (a distinct .NET TcpState value) maps to the same UI
      // bucket since neither has a meaningfully different treatment
      // here.
      case 'listen':
      case 'bound':
        return 'LISTEN';
      case 'timewait':
        return 'TIME-WAIT';
      case 'closewait':
        return 'CLOSE-WAIT';
      case 'closed':
        return 'CLOSED';
      case 'synsent':
        return 'SYN-SENT';
      case 'synreceived':
        return 'SYN-RECV';
      case 'finwait1':
      case 'finwait2':
        return 'FIN-WAIT';
      case 'unconn':
        return 'UNCONN';
      default:
        // Anything not explicitly mapped is shown as-is rather than
        // silently hidden — an unrecognized state is still real,
        // useful information, just not one this app has a specific
        // color/filter rule for.
        return state.isEmpty ? 'UNKNOWN' : state.toUpperCase();
    }
  }

  NetworkConnection? _parseLine(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 5) return null;

    final protocol = parts[0];
    final state = parts[1];
    // parts[2]/parts[3] are Recv-Q/Send-Q — not currently surfaced in
    // the UI, skipped here.
    final local = parts[4];
    final peer = parts.length > 5 ? parts[5] : '';
    final processInfo = parts.length > 6 ? parts.sublist(6).join(' ') : '';

    final localSplit = _splitAddressPort(local);
    final peerSplit = _splitAddressPort(peer);

    final procMatch = _processInfoPattern.firstMatch(processInfo);
    final processName = procMatch?.group(1);
    final pid = procMatch != null ? int.tryParse(procMatch.group(2)!) : null;

    return NetworkConnection(
      protocol: protocol,
      state: state,
      localAddress: localSplit.$1,
      localPort: localSplit.$2,
      peerAddress: peerSplit.$1,
      peerPort: peerSplit.$2,
      processName: processName,
      pid: pid,
    );
  }

  /// Splits "address:port" into its two parts, handling IPv6 addresses
  /// in brackets (e.g. "[::1]:8080") and wildcard ports ("0.0.0.0:*").
  (String, String) _splitAddressPort(String input) {
    final bracketMatch = RegExp(r'^\[(.+)\]:(\S+)$').firstMatch(input);
    if (bracketMatch != null) {
      return (bracketMatch.group(1)!, bracketMatch.group(2)!);
    }
    final lastColon = input.lastIndexOf(':');
    if (lastColon == -1) return (input, '');
    return (input.substring(0, lastColon), input.substring(lastColon + 1));
  }
}
