import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/startup_app_entry.dart';

const _logSource = 'StartupAppsService';

/// Reads and toggles autostart entries.
///
/// **Linux**: .desktop files, following the freedesktop.org XDG
/// autostart specification:
/// https://specifications.freedesktop.org/autostart-spec/
/// - System-wide entries live in /etc/xdg/autostart/*.desktop
/// - User entries live in ~/.config/autostart/*.desktop
/// - A user entry with the same filename as a system one overrides it
///   entirely (that's how enabling/disabling a system entry works —
///   you don't edit /etc/xdg/autostart, you create/edit a same-named
///   file in your own ~/.config/autostart)
/// - An entry is disabled if Hidden=true or
///   X-GNOME-Autostart-enabled=false is set
///
/// **Windows**: the registry `Run` keys (`HKCU` for the current user,
/// `HKLM` for all users) plus shortcuts in the Startup folder
/// (`shell:startup`). Windows' own Task Manager > Startup tab uses a
/// separate `StartupApproved` registry key (a binary blob per entry
/// name) to disable an entry without removing it — reproducing that
/// exact binary format wasn't attempted here without a Windows machine
/// to verify the byte layout against, so **disabling a Windows entry
/// here actually removes it** rather than toggling a hidden flag the
/// way the Linux/XDG side does. Re-enabling therefore isn't offered
/// for previously-removed Windows entries; this is a real, deliberate
/// scope-narrowing versus Linux's non-destructive toggle, not a bug.
class StartupAppsService {
  Future<List<StartupAppEntry>> listEntries() {
    return Platform.isWindows ? _listEntriesWindows() : _listEntriesLinux();
  }

  Future<bool> setEnabled(StartupAppEntry entry, bool enabled) {
    return Platform.isWindows ? _setEnabledWindows(entry, enabled) : _setEnabledLinux(entry, enabled);
  }

  // --- Windows -----------------------------------------------------------

  static const _hkcuRunKey = r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _hklmRunKey = r'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';

  Future<List<StartupAppEntry>> _listEntriesWindows() async {
    final entries = <StartupAppEntry>[];
    try {
      entries.addAll(await _readRunKey(_hkcuRunKey, isUserEntry: true));
      entries.addAll(await _readRunKey(_hklmRunKey, isUserEntry: false));
      entries.addAll(await _readStartupFolder());
      entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return entries;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list startup apps (Windows): $e\n$st');
      return [];
    }
  }

  Future<List<StartupAppEntry>> _readRunKey(String registryPath, {required bool isUserEntry}) async {
    try {
      // Get-Item (not Get-ItemProperty) + .Property gives just the
      // value NAMES under the key, which become each entry's
      // "filePath" identifier for later toggling — Get-ItemProperty's
      // output mixes in PowerShell's own PS*Path metadata properties,
      // which would need filtering out first.
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "if (Test-Path '$registryPath') { "
            "\$key = Get-Item '$registryPath'; "
            "\$key.Property | ForEach-Object { "
            "[PSCustomObject]@{ Name = \$_; Command = \$key.GetValue(\$_) } "
            "} | ConvertTo-Json -Compress "
            "}",
      ]).timeout(const Duration(seconds: 10));

      final output = (result.stdout as String?)?.trim() ?? '';
      if (output.isEmpty) return [];

      final decoded = jsonDecode(output);
      final rows = decoded is List ? decoded : [decoded];

      return rows.map((row) {
        final map = row as Map<String, dynamic>;
        final name = (map['Name'] as String?) ?? '?';
        final command = map['Command'] as String?;
        return StartupAppEntry(
          name: name,
          execCommand: command,
          enabled: true, // present in the Run key at all == enabled, on this simplified model
          isUserEntry: isUserEntry,
          // Encodes enough to reverse the lookup for setEnabled: which
          // registry hive + the value name to remove.
          filePath: '$registryPath\\$name',
        );
      }).toList();
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read $registryPath: $e');
      return [];
    }
  }

  Future<List<StartupAppEntry>> _readStartupFolder() async {
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) return [];
      final dir = Directory('$appData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup');
      if (!await dir.exists()) return [];

      final entries = <StartupAppEntry>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split('\\').last;
        if (!name.toLowerCase().endsWith('.lnk') && !name.toLowerCase().endsWith('.exe')) continue;
        entries.add(StartupAppEntry(
          name: name.replaceAll(RegExp(r'\.(lnk|exe)$', caseSensitive: false), ''),
          execCommand: entity.path,
          enabled: true,
          isUserEntry: true,
          filePath: entity.path,
        ));
      }
      return entries;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read Startup folder: $e');
      return [];
    }
  }

  Future<bool> _setEnabledWindows(StartupAppEntry entry, bool enabled) async {
    // Startup-folder shortcuts: "disabling" means deleting the
    // shortcut file; there's no separate hidden state to restore to,
    // so re-enabling isn't offered for these either.
    if (entry.filePath.toLowerCase().endsWith('.lnk') || entry.filePath.toLowerCase().endsWith('.exe')) {
      if (enabled) {
        AppLogger.instance.error(
            _logSource, 'Kan Startup-map-snelkoppeling "${entry.name}" niet opnieuw inschakelen — verwijderd bestanden kunnen hier niet worden hersteld.');
        return false;
      }
      try {
        await File(entry.filePath).delete();
        AppLogger.instance.info(_logSource, 'Verwijderd uit Startup-map: "${entry.name}"');
        return true;
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Failed to delete "${entry.filePath}": $e');
        return false;
      }
    }

    // Registry Run-key entries: see class doc — disabling removes the
    // value outright (no non-destructive hidden-flag equivalent
    // attempted here); re-enabling a previously-removed entry isn't
    // possible without the original command, which is gone once removed.
    if (!enabled) {
      final lastBackslash = entry.filePath.lastIndexOf('\\');
      final registryPath = entry.filePath.substring(0, lastBackslash);
      final valueName = entry.filePath.substring(lastBackslash + 1);
      try {
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Remove-ItemProperty -Path '$registryPath' -Name '$valueName' -ErrorAction Stop",
        ]).timeout(const Duration(seconds: 10));
        final success = result.exitCode == 0;
        AppLogger.instance.info(
          _logSource,
          success
              ? 'Verwijderd uit opstartregistry: "${entry.name}"'
              : 'Verwijderen mislukt: ${(result.stderr as String?)?.trim()}',
        );
        return success;
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Failed to remove "${entry.name}" from registry: $e');
        return false;
      }
    }

    AppLogger.instance.error(
        _logSource, 'Kan verwijderde opstartregistry-waarde "${entry.name}" niet herstellen — de oorspronkelijke opdracht is niet bewaard.');
    return false;
  }

  // --- Linux ---------------------------------------------------------

  Future<String> _userAutostartDir() async {
    final home = Platform.environment['HOME'];
    if (home == null) throw StateError('HOME environment variable not set');
    return '$home/.config/autostart';
  }

  static const _systemAutostartDir = '/etc/xdg/autostart';

  Future<List<StartupAppEntry>> _listEntriesLinux() async {
    try {
      final userDir = await _userAutostartDir();
      final userFiles = await _listDesktopFiles(userDir);
      final systemFiles = await _listDesktopFiles(_systemAutostartDir);

      // User entries override system entries with the same filename —
      // build the result starting from system entries, then let user
      // files replace or add to that by filename.
      final byFilename = <String, StartupAppEntry>{};

      for (final path in systemFiles) {
        final entry = await _parseDesktopFile(path, isUserEntry: false);
        if (entry != null) byFilename[_basename(path)] = entry;
      }
      for (final path in userFiles) {
        final entry = await _parseDesktopFile(path, isUserEntry: true);
        if (entry != null) byFilename[_basename(path)] = entry;
      }

      final entries = byFilename.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return entries;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list startup apps: $e\n$st');
      return [];
    }
  }

  Future<List<String>> _listDesktopFiles(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return [];
      final entries = await dir.list().toList();
      return entries.whereType<File>().map((f) => f.path).where((p) => p.endsWith('.desktop')).toList();
    } catch (_) {
      return []; // directory unreadable — treat as no entries from that source
    }
  }

  String _basename(String path) => path.split('/').last;

  Future<StartupAppEntry?> _parseDesktopFile(String path, {required bool isUserEntry}) async {
    try {
      final lines = await File(path).readAsLines();
      String? name;
      String? comment;
      String? exec;
      String? icon;
      bool hidden = false;
      bool? gnomeEnabled;
      var inDesktopEntrySection = false;

      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.startsWith('[')) {
          inDesktopEntrySection = line == '[Desktop Entry]';
          continue;
        }
        if (!inDesktopEntrySection || line.isEmpty || line.startsWith('#')) continue;

        final eqIndex = line.indexOf('=');
        if (eqIndex == -1) continue;
        final key = line.substring(0, eqIndex).trim();
        final value = line.substring(eqIndex + 1).trim();

        switch (key) {
          case 'Name':
            name = value;
            break;
          case 'Comment':
            comment = value;
            break;
          case 'Exec':
            exec = value;
            break;
          case 'Icon':
            icon = value;
            break;
          case 'Hidden':
            hidden = value.toLowerCase() == 'true';
            break;
          case 'X-GNOME-Autostart-enabled':
            gnomeEnabled = value.toLowerCase() == 'true';
            break;
        }
      }

      if (name == null) return null; // not a valid Desktop Entry
      final enabled = !hidden && (gnomeEnabled ?? true);

      return StartupAppEntry(
        name: name,
        comment: comment,
        execCommand: exec,
        iconName: icon,
        enabled: enabled,
        isUserEntry: isUserEntry,
        filePath: path,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to parse $path: $e');
      return null;
    }
  }

  /// Enables or disables an entry, per the XDG override mechanism: if
  /// it's already a user entry, edit it in place; if it's a system
  /// entry, create a minimal override file in the user's own
  /// ~/.config/autostart with the same filename.
  Future<bool> _setEnabledLinux(StartupAppEntry entry, bool enabled) async {
    try {
      final userDir = await _userAutostartDir();
      final filename = _basename(entry.filePath);
      final userPath = '$userDir/$filename';

      if (entry.isUserEntry) {
        // Edit the existing user file in place: rewrite/add the
        // Hidden= line, leaving everything else untouched.
        final file = File(entry.filePath);
        final lines = await file.readAsLines();
        final newLines = <String>[];
        var wroteHidden = false;
        var inDesktopEntrySection = false;

        for (final rawLine in lines) {
          final line = rawLine.trim();
          if (line.startsWith('[')) {
            inDesktopEntrySection = line == '[Desktop Entry]';
            newLines.add(rawLine);
            continue;
          }
          if (inDesktopEntrySection && line.startsWith('Hidden=')) {
            newLines.add('Hidden=${!enabled}');
            wroteHidden = true;
            continue;
          }
          newLines.add(rawLine);
        }
        if (!wroteHidden) {
          // Insert right after the [Desktop Entry] header if present,
          // otherwise just append.
          final headerIndex = newLines.indexWhere((l) => l.trim() == '[Desktop Entry]');
          final insertAt = headerIndex == -1 ? newLines.length : headerIndex + 1;
          newLines.insert(insertAt, 'Hidden=${!enabled}');
        }
        await file.writeAsString('${newLines.join('\n')}\n');
      } else {
        // System entry: create a user-level override. Disabling needs
        // only a minimal Hidden=true stub; re-enabling a previously
        // system-hidden entry means removing that override (falls
        // back to the system file, which is enabled by default) —
        // but if the user is explicitly re-enabling here, write an
        // explicit Hidden=false override instead of guessing whether
        // deleting is safe.
        await Directory(userDir).create(recursive: true);
        final overrideContent = '[Desktop Entry]\nHidden=${!enabled}\n';
        await File(userPath).writeAsString(overrideContent);
      }

      AppLogger.instance.info(
        _logSource,
        '${enabled ? 'Enabled' : 'Disabled'} startup app "${entry.name}" ($filename)',
      );
      return true;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to toggle "${entry.name}": $e');
      return false;
    }
  }
}
