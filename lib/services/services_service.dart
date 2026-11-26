import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/service_info.dart';
import 'sensors/windows/native_service_reader.dart';

const _logSource = 'ServicesService';

class ServicesService {
  final NativeServiceReader _windowsNativeServices = NativeServiceReader();

  /// Whether a service-management backend is available on this system
  /// at all — used to show a clear message instead of a confusing
  /// empty list. On Linux this means systemd specifically (some Alpine/
  /// Devuan/Artix setups use something else); on Windows the Service
  /// Control Manager is always present, so this only ever returns
  /// false there if something is very wrong with the machine.
  Future<bool> isSystemdAvailable() async {
    if (Platform.isWindows) {
      try {
        final result = await Process.run('powershell.exe', ['-NoProfile', '-Command', 'Get-Service | Select-Object -First 1 | Out-Null; exit 0']);
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    try {
      final result = await Process.run('systemctl', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<List<ServiceInfo>> listServices() =>
      Platform.isWindows ? _listServicesWindows() : _listServicesLinux();

  Future<List<ServiceInfo>> _listServicesLinux() async {
    try {
      final unitsResult = await Process.run(
        'systemctl',
        ['list-units', '--type=service', '--all', '--no-legend', '--no-pager', '--plain'],
      );
      if (unitsResult.exitCode != 0) {
        AppLogger.instance.error(
          _logSource,
          'systemctl list-units exited with ${unitsResult.exitCode}: ${unitsResult.stderr}',
        );
        return [];
      }

      final enabledStates = await _readEnabledStatesLinux();

      final services = <ServiceInfo>[];
      for (final rawLine in (unitsResult.stdout as String).split('\n')) {
        // Failed units are prefixed with a "●" marker in some systemd
        // versions — strip it before splitting on whitespace.
        final line = rawLine.trim().replaceFirst(RegExp(r'^●\s*'), '');
        if (line.isEmpty) continue;

        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 4) continue;

        final unitName = parts[0];
        final loadState = parts[1];
        final activeState = parts[2];
        final subState = parts[3];
        final description = parts.length > 4 ? parts.sublist(4).join(' ') : '';

        services.add(ServiceInfo(
          unitName: unitName,
          loadState: loadState,
          activeState: activeState,
          subState: subState,
          description: description,
          enabledState: enabledStates[unitName] ?? 'unknown',
        ));
      }

      services.sort((a, b) => a.unitName.toLowerCase().compareTo(b.unitName.toLowerCase()));
      return services;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list services: $e\n$st');
      return [];
    }
  }

  Future<Map<String, String>> _readEnabledStatesLinux() async {
    final result = <String, String>{};
    try {
      final filesResult = await Process.run(
        'systemctl',
        ['list-unit-files', '--type=service', '--no-legend', '--no-pager', '--plain'],
      );
      if (filesResult.exitCode != 0) return result;

      for (final rawLine in (filesResult.stdout as String).split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        result[parts[0]] = parts[1];
      }
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read unit-file enabled states: $e');
    }
    return result;
  }

  /// Fast path first: [NativeServiceReader] needs no PowerShell/WMI
  /// round-trip at all (and, unlike the WMI fallback below, doesn't
  /// even spawn a process) — see its class doc for the full reasoning.
  /// Falls through to the WMI-based reading on any failure, including
  /// the reader permanently disabling itself.
  Future<List<ServiceInfo>> _listServicesWindows() async {
    final nativeRows = _windowsNativeServices.read();
    if (nativeRows != null) {
      final services = <ServiceInfo>[];
      for (final row in nativeRows) {
        final name = row['name'] as String;
        final isRunning = row['isRunning'] as bool;
        final startType = row['startType'] as String;
        final description = row['description'] as String;
        final displayName = row['displayName'] as String;
        services.add(ServiceInfo(
          unitName: name,
          loadState: 'loaded',
          activeState: isRunning ? 'active' : 'inactive',
          subState: row['state'] as String,
          description: description.isNotEmpty ? description : displayName,
          enabledState: startType,
        ));
      }
      services.sort((a, b) => a.unitName.toLowerCase().compareTo(b.unitName.toLowerCase()));
      return services;
    }
    return _listServicesWindowsViaWmiFallback();
  }

  /// Only reached if [NativeServiceReader] itself is unavailable
  /// (disabled after a binding failure) — the original WMI-based
  /// approach, kept as a complete, independent fallback rather than
  /// removed outright. Win32_Service already reports both live state
  /// (Running/Stopped/Paused, in `State`) and startup configuration
  /// (Auto/Manual/Disabled, in `StartMode`) in one query — no separate
  /// "list units" plus "list unit files" round-trip the way systemd
  /// needs, since Windows' Service Control Manager keeps both facts
  /// about the same object rather than splitting live vs. configured
  /// state across two different query surfaces.
  Future<List<ServiceInfo>> _listServicesWindowsViaWmiFallback() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-CimInstance Win32_Service | '
            'Select-Object Name, DisplayName, Description, State, StartMode | ConvertTo-Json -Compress',
      ]);
      if (result.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'Get-CimInstance Win32_Service failed: ${result.stderr}');
        return [];
      }
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return [];

      final decoded = jsonDecode(output);
      final rows = decoded is List ? decoded : [decoded];

      final services = <ServiceInfo>[];
      for (final row in rows) {
        final map = row as Map<String, dynamic>;
        final name = (map['Name'] as String?) ?? '?';
        // Windows Service Control Manager state strings ("Running",
        // "Stopped", "Paused", ...) — mapped onto the same
        // active/inactive vocabulary ServiceInfo already uses for
        // systemd, so the shared UI (colors, filters) doesn't need to
        // know which platform it's looking at. Windows has no single
        // "failed" concept the way systemd does (a service that
        // crashed just shows as "Stopped"), so that distinction is
        // genuinely not available here, not an oversight.
        final state = (map['State'] as String?) ?? 'Unknown';
        final activeState = state.toLowerCase() == 'running' ? 'active' : 'inactive';

        // StartMode: Boot/System/Auto/Manual/Disabled — mapped onto
        // systemd's enabled/disabled/static vocabulary. "Manual" maps
        // to "static" (systemd's term for "not auto-started, but can
        // be started on demand") since that's the closest conceptual
        // equivalent, not an exact match.
        final startMode = (map['StartMode'] as String?) ?? 'Unknown';
        final enabledState = switch (startMode.toLowerCase()) {
          'auto' || 'boot' || 'system' => 'enabled',
          'disabled' => 'disabled',
          'manual' => 'static',
          _ => 'unknown',
        };

        final description = (map['Description'] as String?)?.trim();
        final displayName = (map['DisplayName'] as String?)?.trim();

        services.add(ServiceInfo(
          unitName: name,
          loadState: 'loaded', // Windows services always "exist" once queried — no separate load-state concept
          activeState: activeState,
          subState: state,
          description: (description != null && description.isNotEmpty) ? description : (displayName ?? ''),
          enabledState: enabledState,
        ));
      }

      services.sort((a, b) => a.unitName.toLowerCase().compareTo(b.unitName.toLowerCase()));
      return services;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list services (Windows): $e\n$st');
      return [];
    }
  }

  /// Runs a privileged systemctl action (start/stop/restart/enable/
  /// disable) via pkexec — the normal Linux authentication dialog
  /// appears, same pattern as the GPU permission fix elsewhere in the
  /// app. Returns (success, stderr-if-any).
  Future<({bool success, String message})> runAction(String action, String unitName) =>
      Platform.isWindows ? _runActionWindows(action, unitName) : _runActionLinux(action, unitName);

  Future<({bool success, String message})> _runActionLinux(String action, String unitName) async {
    AppLogger.instance.info(_logSource, 'Running "$action" on $unitName via pkexec');
    try {
      final result = await Process.run('pkexec', ['systemctl', action, unitName]);
      final success = result.exitCode == 0;
      final stderrText = (result.stderr as String).trim();
      AppLogger.instance.info(
        _logSource,
        success
            ? '$action $unitName succeeded'
            : '$action $unitName failed (exit ${result.exitCode}): $stderrText',
      );
      return (success: success, message: success ? '' : stderrText);
    } catch (e) {
      AppLogger.instance.error(_logSource, 'pkexec call failed for $action $unitName: $e');
      return (success: false, message: '$e');
    }
  }

  /// Windows equivalent of the pkexec flow above. Most system services
  /// need Administrator rights to start/stop/reconfigure — rather than
  /// always pre-emptively elevating (which would mean a UAC prompt for
  /// every single click, even on the services a normal user *can*
  /// control), this tries the plain command first and only falls back
  /// to one elevated attempt if that specific attempt was rejected for
  /// being unprivileged. Same "ask only when actually needed" spirit
  /// as pkexec's own authentication prompt.
  Future<({bool success, String message})> _runActionWindows(String action, String unitName) async {
    final nameEscaped = unitName.replaceAll("'", "''");
    final command = switch (action) {
      'start' => "Start-Service -Name '$nameEscaped' -ErrorAction Stop",
      'stop' => "Stop-Service -Name '$nameEscaped' -Force -ErrorAction Stop",
      'restart' => "Restart-Service -Name '$nameEscaped' -Force -ErrorAction Stop",
      'enable' => "Set-Service -Name '$nameEscaped' -StartupType Automatic -ErrorAction Stop",
      'disable' => "Set-Service -Name '$nameEscaped' -StartupType Disabled -ErrorAction Stop",
      _ => null,
    };
    if (command == null) return (success: false, message: 'Onbekende actie: $action');

    AppLogger.instance.info(_logSource, 'Running "$action" on $unitName');
    try {
      final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command]);
      if (result.exitCode == 0) {
        AppLogger.instance.info(_logSource, '$action $unitName succeeded');
        return (success: true, message: '');
      }

      final stderrText = (result.stderr as String).trim();
      // "Access is denied" / "toegang geweigerd" is PowerShell's own
      // phrasing for exactly the "this needs elevation" case — not a
      // guess based on exit code alone, which Windows service cmdlets
      // don't use consistently enough to branch on by itself.
      final looksLikePermissionIssue =
          stderrText.toLowerCase().contains('access is denied') || stderrText.toLowerCase().contains('geweigerd');

      if (!looksLikePermissionIssue) {
        AppLogger.instance.info(_logSource, '$action $unitName failed (not a permission issue): $stderrText');
        return (success: false, message: stderrText);
      }

      AppLogger.instance.info(_logSource, '$action $unitName needs elevation, retrying via UAC prompt');
      final elevatedResult = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "try { \$p = Start-Process -FilePath 'powershell.exe' "
            "-ArgumentList '-NoProfile -NonInteractive -Command \"$command\"' "
            "-Verb RunAs -Wait -PassThru -WindowStyle Hidden; "
            "if (\$p.ExitCode -eq 0) { Write-Output 'DARKTASK_ACTION_OK' } "
            "else { Write-Output ('DARKTASK_ACTION_ERROR: exit code ' + \$p.ExitCode) } "
            "} catch { Write-Output ('DARKTASK_ACTION_ERROR: ' + \$_.Exception.Message) }",
      ]);
      final elevatedOutput = '${elevatedResult.stdout}\n${elevatedResult.stderr}';
      final success = elevatedOutput.contains('DARKTASK_ACTION_OK');
      AppLogger.instance.info(
        _logSource,
        success ? '$action $unitName succeeded (elevated)' : '$action $unitName failed (elevated): $elevatedOutput',
      );
      return (
        success: success,
        message: success ? '' : (RegExp(r'DARKTASK_ACTION_ERROR:\s*(.+)').firstMatch(elevatedOutput)?.group(1)?.trim() ?? 'Verhoging geweigerd of mislukt'),
      );
    } catch (e) {
      AppLogger.instance.error(_logSource, 'PowerShell call failed for $action $unitName: $e');
      return (success: false, message: '$e');
    }
  }
}
