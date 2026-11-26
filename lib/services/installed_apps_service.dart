import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import '../core/models/installed_app.dart';
import '../core/models/uninstall_plan.dart';

const _logSource = 'InstalledAppsService';

class InstalledAppsService {
  Future<List<String>> _searchDirs() async {
    final home = Platform.environment['HOME'];
    return [
      '/usr/share/applications',
      '/usr/local/share/applications',
      if (home != null) '$home/.local/share/applications',
      '/var/lib/flatpak/exports/share/applications',
      if (home != null) '$home/.local/share/flatpak/exports/share/applications',
      '/var/lib/snapd/desktop/applications',
    ];
  }

  AppSource _sourceForDir(String dir) {
    if (dir.contains('flatpak')) return AppSource.flatpak;
    if (dir.contains('snapd')) return AppSource.snap;
    if (dir.startsWith('/usr') || dir.startsWith('/var')) return AppSource.system;
    return AppSource.user;
  }

  /// Lists installed GUI applications by scanning the standard XDG
  /// application directories (system-wide, user-local, Flatpak, Snap)
  /// for .desktop files with Type=Application. Entries marked
  /// NoDisplay=true or Hidden=true are skipped — those are background
  /// helpers/integration entries that don't normally show in an app
  /// menu either, so a "list of apps you have installed" screen
  /// shouldn't show them.
  Future<List<InstalledApp>> listApps() => Platform.isWindows ? _listAppsWindows() : _listAppsLinux();

  Future<List<InstalledApp>> _listAppsLinux() async {
    try {
      final dirs = await _searchDirs();
      final apps = <String, InstalledApp>{}; // keyed by name to naturally dedupe
      final iconIndex = await _buildIconIndex();

      for (final dirPath in dirs) {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;

        List<FileSystemEntity> entries;
        try {
          entries = await dir.list().toList();
        } catch (_) {
          continue; // unreadable directory — skip, not fatal
        }

        for (final entity in entries) {
          if (entity is! File || !entity.path.endsWith('.desktop')) continue;
          final app = await _parseDesktopFile(entity.path, _sourceForDir(dirPath), iconIndex);
          if (app != null) apps[app.name] = app;
        }
      }

      final result = apps.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return result;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list installed apps: $e\n$st');
      return [];
    }
  }

  /// Windows' equivalent of a package database query: the same
  /// registry keys (`...\CurrentVersion\Uninstall\*`) that Control
  /// Panel's "Programs and Features" and the Settings app's "Apps"
  /// list both read from. Three locations are queried together since
  /// Windows splits entries across them by architecture and scope:
  /// native 64-bit apps and per-machine installs under
  /// `HKLM\...\Uninstall`, 32-bit apps on 64-bit Windows under the
  /// `WOW6432Node` mirror, and per-user installs under
  /// `HKCU\...\Uninstall`.
  ///
  /// `SystemComponent = 1` is Windows' own documented way of marking
  /// an entry as a background/redistributable component rather than a
  /// user-facing app — filtering on it is the direct equivalent of
  /// skipping `NoDisplay=true`/`Hidden=true` .desktop entries on
  /// Linux, not a guess at undocumented behavior. `ParentKeyName`
  /// presence marks an entry as an update/patch belonging to another
  /// product rather than a standalone install, filtered out for the
  /// same "this isn't really its own app" reason.
  Future<List<InstalledApp>> _listAppsWindows() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$paths = @('
            r'"HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*", '
            r'"HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", '
            r'"HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"'
            r'); '
            r'Get-ItemProperty $paths -ErrorAction SilentlyContinue | '
            r'Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } | '
            r'Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, DisplayIcon, '
            r'UninstallString, QuietUninstallString, PSPath, PSChildName | '
            r'ConvertTo-Json -Compress -Depth 3',
      ]);
      if (result.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'Reading Uninstall registry keys failed: ${result.stderr}');
        return [];
      }
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return [];

      final decoded = jsonDecode(output);
      final rows = decoded is List ? decoded : [decoded];

      final apps = <String, InstalledApp>{}; // keyed by name to naturally dedupe, same as the Linux path
      for (final row in rows) {
        final map = row as Map<String, dynamic>;
        final name = map['DisplayName']?.toString();
        if (name == null || name.isEmpty) continue;

        final version = map['DisplayVersion']?.toString();
        final publisher = map['Publisher']?.toString();
        // A comment field for context, same spirit as .desktop's
        // Comment= — Windows' uninstall registry has no free-text
        // description, so this is synthesized from what it does have
        // rather than left as a fabricated sentence.
        final comment = [publisher, version].where((s) => s != null && s.isNotEmpty).join(' · ');

        // PSPath looks like
        // "Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\..."
        // for per-user entries, or HKEY_LOCAL_MACHINE for the other
        // two search roots — used to map onto this app's existing
        // system/user distinction rather than adding a new AppSource
        // value, since "installed machine-wide" vs. "installed for
        // this user only" is genuinely the same underlying concept
        // Linux's /usr vs. ~/.local split represents.
        final psPath = map['PSPath']?.toString() ?? '';
        final source = psPath.contains('HKEY_CURRENT_USER') ? AppSource.user : AppSource.system;

        apps[name] = InstalledApp(
          name: name,
          comment: comment.isEmpty ? null : comment,
          execCommand: null, // no direct "how to launch this" data in the Uninstall registry
          iconName: map['DisplayIcon']?.toString(),
          // DisplayIcon is almost always a .exe or .ico path (with an
          // optional ",N" icon-index suffix) — Flutter can't render
          // either format directly, so this is left null here rather
          // than pointed at a file the UI can't display yet.
          // extractIconsWindows (see its own doc) fills this in
          // afterward, as a deliberately separate, deferred step —
          // not because it can't be resolved at all, but because doing
          // real icon-rasterization work for every installed app
          // shouldn't block this list from rendering first.
          resolvedIconPath: null,
          categories: const [],
          source: source,
          // Used later as this app's identity for the uninstall-plan
          // lookup below — the full registry key path (via PSChildName,
          // the key's own name, typically a GUID or an app-chosen
          // string) rather than a filesystem path, since there's no
          // .desktop-file equivalent to anchor to on Windows.
          filePath: map['PSChildName']?.toString() ?? name,
        );
      }

      final sortedApps = apps.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return sortedApps;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to list installed apps (Windows): $e\n$st');
      return [];
    }
  }

  /// Builds a one-shot index of icon-name -> file path by scanning a
  /// small, prioritized set of icon directories once, rather than
  /// searching the filesystem per app. Only PNG/XPM are indexed — SVG
  /// icons exist too (and are actually the most common format for
  /// modern apps) but Flutter's Image widget can't render them without
  /// an extra package, so those apps simply fall back to the generic
  /// icon rather than being left unindexed and silently broken.
  Future<Map<String, String>> _buildIconIndex() async {
    final index = <String, String>{};
    // Order matters: earlier entries win when the same icon name
    // exists in multiple directories (first-match-wins below).
    const candidateDirs = [
      '/usr/share/icons/hicolor/48x48/apps',
      '/usr/share/icons/hicolor/64x64/apps',
      '/usr/share/icons/hicolor/128x128/apps',
      '/usr/share/icons/hicolor/32x32/apps',
      '/usr/share/pixmaps',
    ];

    for (final dirPath in candidateDirs) {
      try {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;
        final entries = await dir.list().toList();
        for (final entity in entries) {
          if (entity is! File) continue;
          final baseName = entity.path.split('/').last;
          final dotIndex = baseName.lastIndexOf('.');
          if (dotIndex == -1) continue;
          final ext = baseName.substring(dotIndex + 1).toLowerCase();
          if (ext != 'png' && ext != 'xpm') continue;
          final nameNoExt = baseName.substring(0, dotIndex);
          index.putIfAbsent(nameNoExt, () => entity.path);
        }
      } catch (e) {
        AppLogger.instance.debug(_logSource, 'Failed to scan icon dir $dirPath: $e');
      }
    }
    return index;
  }

  /// Resolves a .desktop file's Icon= value to an actual file path, if
  /// possible. Returns null (not a guess) when the icon can't be
  /// found or is in an unsupported format (SVG) — the UI falls back to
  /// a generic icon in that case rather than showing nothing.
  String? _resolveIconPath(String? iconName, Map<String, String> index) {
    if (iconName == null || iconName.isEmpty) return null;

    if (iconName.startsWith('/')) {
      final ext = iconName.split('.').last.toLowerCase();
      if (ext == 'png' || ext == 'xpm' || ext == 'jpg' || ext == 'jpeg') return iconName;
      return null; // absolute path but an unsupported format (e.g. .svg)
    }

    var name = iconName;
    for (final ext in ['.png', '.xpm', '.svg']) {
      if (name.endsWith(ext)) {
        name = name.substring(0, name.length - ext.length);
        break;
      }
    }
    return index[name];
  }

  Future<InstalledApp?> _parseDesktopFile(
    String path,
    AppSource source,
    Map<String, String> iconIndex,
  ) async {
    try {
      final lines = await File(path).readAsLines();
      String? name;
      String? comment;
      String? exec;
      String? icon;
      String? type;
      var noDisplay = false;
      var hidden = false;
      var categories = <String>[];
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
          case 'Type':
            type = value;
            break;
          case 'NoDisplay':
            noDisplay = value.toLowerCase() == 'true';
            break;
          case 'Hidden':
            hidden = value.toLowerCase() == 'true';
            break;
          case 'Categories':
            categories = value.split(';').where((c) => c.isNotEmpty).toList();
            break;
        }
      }

      if (name == null) return null;
      if (type != null && type != 'Application') return null;
      if (noDisplay || hidden) return null;

      return InstalledApp(
        name: name,
        comment: comment,
        execCommand: exec,
        iconName: icon,
        resolvedIconPath: _resolveIconPath(icon, iconIndex),
        categories: categories,
        source: source,
        filePath: path,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to parse $path: $e');
      return null;
    }
  }

  // -----------------------------------------------------------------
  // Uninstall: detection + execution. Resolved on demand (only when
  // the user actually opens the uninstall action for one app), not
  // eagerly for the whole list — reverse package-manager lookups are
  // real subprocess calls and doing that for hundreds of apps upfront
  // would be slow for no benefit.
  // -----------------------------------------------------------------

  Future<UninstallPlan> resolveUninstallPlan(InstalledApp app) async {
    if (Platform.isWindows) return _resolveWindowsPlan(app);

    switch (app.source) {
      case AppSource.flatpak:
        return _resolveFlatpakPlan(app);
      case AppSource.snap:
        return _resolveSnapPlan(app);
      case AppSource.system:
        return _resolveSystemPackagePlan(app);
      case AppSource.user:
        return UninstallPlan(
          method: UninstallMethod.desktopFileOnly,
          displayCommand: 'Bureaubladbestand verwijderen: ${app.filePath}',
        );
    }
  }

  /// Unlike the Linux methods above, this needs no reverse-lookup:
  /// the exact uninstall command was already read alongside this
  /// app's other metadata in [_listAppsWindows] (stored in
  /// [InstalledApp.execCommand]... actually stored separately, see
  /// below) — re-queries this one registry entry by its key name
  /// rather than threading the raw UninstallString through the
  /// InstalledApp model, keeping that model's shape shared with Linux.
  Future<UninstallPlan> _resolveWindowsPlan(InstalledApp app) async {
    try {
      // Built with normal (non-raw) string interpolation, unlike most
      // PowerShell snippets elsewhere in this app — this one genuinely
      // needs to interpolate a Dart value (the registry key name) into
      // the middle of a path, which raw strings can't do. The key name
      // itself is escaped for safe embedding inside a PowerShell
      // single-quoted string the same way every other script in this
      // codebase escapes single quotes.
      final keyEscaped = app.filePath.replaceAll("'", "''");
      final script = "\$paths = @("
          "'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$keyEscaped', "
          "'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$keyEscaped', "
          "'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$keyEscaped'"
          "); "
          "Get-ItemProperty \$paths -ErrorAction SilentlyContinue | "
          "Select-Object -First 1 UninstallString, QuietUninstallString | ConvertTo-Json -Compress";

      final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script]);
      if (result.exitCode != 0) return const UninstallPlan(method: UninstallMethod.unknown);
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return const UninstallPlan(method: UninstallMethod.unknown);

      final decoded = jsonDecode(output) as Map<String, dynamic>;
      // Prefer the silent variant when the installer publishes one —
      // this app is running the uninstaller on the person's behalf
      // after they've already confirmed via this app's own dialog, so
      // a second, separate confirmation prompt from the uninstaller
      // itself would be redundant rather than an extra safety check.
      final command = (decoded['QuietUninstallString'] as String?) ?? (decoded['UninstallString'] as String?);
      if (command == null || command.isEmpty) return const UninstallPlan(method: UninstallMethod.unknown);

      return UninstallPlan(
        method: UninstallMethod.windowsUninstaller,
        packageOrId: app.filePath,
        displayCommand: command,
      );
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to resolve Windows uninstall plan for "${app.name}": $e');
      return const UninstallPlan(method: UninstallMethod.unknown);
    }
  }

  UninstallPlan _resolveFlatpakPlan(InstalledApp app) {
    // Flatpak .desktop files are conventionally named <app-id>.desktop.
    final filename = app.filePath.split('/').last;
    final appId = filename.endsWith('.desktop')
        ? filename.substring(0, filename.length - '.desktop'.length)
        : filename;
    final isUserScope = app.filePath.contains('/.local/share/flatpak/');

    final scopeArgs = isUserScope ? ['--user'] : ['--system'];
    return UninstallPlan(
      method: UninstallMethod.flatpak,
      packageOrId: appId,
      requiresRoot: !isUserScope,
      executable: isUserScope ? 'flatpak' : 'pkexec',
      commandArgs: isUserScope
          ? ['uninstall', '-y', ...scopeArgs, appId]
          : ['flatpak', 'uninstall', '-y', ...scopeArgs, appId],
      displayCommand: isUserScope
          ? 'flatpak uninstall -y --user $appId'
          : 'pkexec flatpak uninstall -y --system $appId',
    );
  }

  UninstallPlan _resolveSnapPlan(InstalledApp app) {
    // Snap .desktop files are typically named <snap>_<id>.desktop, or
    // just <snap>.desktop for the primary app in the snap.
    final filename = app.filePath.split('/').last;
    final withoutExt =
        filename.endsWith('.desktop') ? filename.substring(0, filename.length - '.desktop'.length) : filename;
    final snapName = withoutExt.contains('_') ? withoutExt.split('_').first : withoutExt;

    return UninstallPlan(
      method: UninstallMethod.snap,
      packageOrId: snapName,
      requiresRoot: true,
      executable: 'pkexec',
      commandArgs: ['snap', 'remove', snapName],
      displayCommand: 'pkexec snap remove $snapName',
    );
  }

  Future<UninstallPlan> _resolveSystemPackagePlan(InstalledApp app) async {
    // Try each package manager's reverse-lookup (which file belongs to
    // which package) in turn — whichever is actually installed and
    // recognizes the file wins. Only one of these will typically be
    // present on a given distro.
    final dpkgPackage = await _tryDpkgOwner(app.filePath);
    if (dpkgPackage != null) {
      return UninstallPlan(
        method: UninstallMethod.systemPackage,
        packageOrId: dpkgPackage,
        requiresRoot: true,
        executable: 'pkexec',
        commandArgs: ['apt-get', 'remove', '-y', dpkgPackage],
        displayCommand: 'pkexec apt-get remove -y $dpkgPackage',
      );
    }

    final rpmPackage = await _tryRpmOwner(app.filePath);
    if (rpmPackage != null) {
      final dnfAvailable = await _commandExists('dnf');
      final manager = dnfAvailable ? 'dnf' : 'yum';
      return UninstallPlan(
        method: UninstallMethod.systemPackage,
        packageOrId: rpmPackage,
        requiresRoot: true,
        executable: 'pkexec',
        commandArgs: [manager, 'remove', '-y', rpmPackage],
        displayCommand: 'pkexec $manager remove -y $rpmPackage',
      );
    }

    final pacmanPackage = await _tryPacmanOwner(app.filePath);
    if (pacmanPackage != null) {
      return UninstallPlan(
        method: UninstallMethod.systemPackage,
        packageOrId: pacmanPackage,
        requiresRoot: true,
        executable: 'pkexec',
        commandArgs: ['pacman', '-R', '--noconfirm', pacmanPackage],
        displayCommand: 'pkexec pacman -R --noconfirm $pacmanPackage',
      );
    }

    return const UninstallPlan(method: UninstallMethod.unknown);
  }

  Future<bool> _commandExists(String command) async {
    try {
      final result = await Process.run('which', [command]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _tryDpkgOwner(String filePath) async {
    try {
      final result = await Process.run('dpkg', ['-S', filePath]);
      if (result.exitCode != 0) return null;
      final output = (result.stdout as String).trim();
      final colonIndex = output.indexOf(':');
      if (colonIndex == -1) return null;
      // Multiple packages can own the same path in rare cases
      // (diversions); take the first one listed.
      return output.substring(0, colonIndex).split(',').first.trim();
    } catch (_) {
      return null; // dpkg not installed — expected on non-Debian distros
    }
  }

  Future<String?> _tryRpmOwner(String filePath) async {
    try {
      final result = await Process.run('rpm', ['-qf', '--queryformat', '%{NAME}', filePath]);
      if (result.exitCode != 0) return null;
      final name = (result.stdout as String).trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null; // rpm not installed — expected on non-RPM distros
    }
  }

  Future<String?> _tryPacmanOwner(String filePath) async {
    try {
      final result = await Process.run('pacman', ['-Qo', filePath]);
      if (result.exitCode != 0) return null;
      final output = (result.stdout as String).trim();
      // Format: "<path> is owned by <pkg> <version>"
      final match = RegExp(r'is owned by (\S+)').firstMatch(output);
      return match?.group(1);
    } catch (_) {
      return null; // pacman not installed — expected outside Arch-based distros
    }
  }

  /// Executes an uninstall plan. Returns (success, message).
  Future<({bool success, String message})> executeUninstall(InstalledApp app, UninstallPlan plan) async {
    AppLogger.instance.info(_logSource, 'Uninstalling "${app.name}" via ${plan.method.name}: ${plan.displayCommand}');
    try {
      switch (plan.method) {
        case UninstallMethod.desktopFileOnly:
          await File(app.filePath).delete();
          AppLogger.instance.info(_logSource, 'Deleted desktop file ${app.filePath}');
          return (success: true, message: '');

        case UninstallMethod.flatpak:
        case UninstallMethod.snap:
        case UninstallMethod.systemPackage:
          if (plan.executable == null || plan.commandArgs == null) {
            return (success: false, message: 'Geen commando bepaald om uit te voeren.');
          }
          final result = await Process.run(plan.executable!, plan.commandArgs!);
          return _resultToOutcome(result);

        case UninstallMethod.windowsUninstaller:
          if (plan.displayCommand == null || plan.displayCommand!.isEmpty) {
            return (success: false, message: 'Geen uninstall-commando gevonden voor dit programma.');
          }
          // UninstallString/QuietUninstallString values are full
          // command lines the installer itself registered (often with
          // embedded quotes and arguments, e.g. "MsiExec.exe /X{GUID}"
          // or '"C:\Program Files\App\uninstall.exe" /S') — handing
          // the whole string to cmd.exe /c to parse and run is exactly
          // how Windows' own Control Panel invokes these, rather than
          // this app trying to split it into a program/args pair
          // itself and risk getting the quoting wrong.
          final result = await Process.run('cmd.exe', ['/c', plan.displayCommand!]);
          return _resultToOutcome(result);

        case UninstallMethod.unknown:
          return (success: false, message: 'Kon geen bijbehorend pakket vinden om te verwijderen.');
      }
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Uninstall failed for "${app.name}": $e');
      return (success: false, message: '$e');
    }
  }

  ({bool success, String message}) _resultToOutcome(ProcessResult result) {
    final success = result.exitCode == 0;
    final stderrText = (result.stderr as String).trim();
    return (success: success, message: success ? '' : stderrText);
  }

  // -----------------------------------------------------------------
  // Windows icon extraction: deliberately a separate, deferred step
  // from _listAppsWindows, not part of it. Extracting and rasterizing
  // an icon from every app's .exe/.ico (via .NET's System.Drawing,
  // below) is real, non-trivial work multiplied across however many
  // apps are installed — potentially 100+. Folding that into the list
  // load itself would mean the whole screen stays blank until every
  // single icon finishes, when showing the list immediately (icon-less
  // at first, exactly as it already renders today) and filling icons
  // in afterward is both faster to first content and a fundamentally
  // safer failure mode: if icon extraction hits a problem, the person
  // still has a complete, usable app list either way.
  // -----------------------------------------------------------------

  /// Extracts and caches a PNG icon for every app in [apps] that has
  /// an [InstalledApp.iconName] but no [InstalledApp.resolvedIconPath]
  /// yet, in one batched PowerShell/.NET call rather than one process
  /// spawn per app. Returns `{app.filePath: pngPath}` for whichever
  /// icons were successfully extracted — apps not present in the
  /// result simply couldn't be extracted (a missing source file, an
  /// unreadable format) and should keep falling back to the generic
  /// icon, not be treated as an error.
  ///
  /// Icons are cached to disk under `%LOCALAPPDATA%\DarkTask\app_icons`
  /// and reused indefinitely once extracted — re-extracting on every
  /// visit to this screen would repeat real, non-trivial work for
  /// icons that essentially never change between one visit and the
  /// next.
  Future<Map<String, String>> extractIconsWindows(List<InstalledApp> apps) async {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null) return {};
    final iconDir = '$localAppData\\DarkTask\\app_icons';

    final candidates = apps.where((a) => a.iconName != null && a.iconName!.isNotEmpty).toList();
    if (candidates.isEmpty) return {};

    try {
      // Each app's own registry key name becomes its cache filename,
      // sanitized to strip characters Windows filenames can't contain
      // — done in Dart rather than PowerShell so the exact same
      // sanitized name can be used both to build the PowerShell script
      // below and to read the resulting files back afterward, with no
      // risk of the two ever disagreeing on what a given app's
      // sanitized name is.
      final sanitizedKeys = <String, String>{};
      for (final app in candidates) {
        sanitizedKeys[app.filePath] = app.filePath.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      }

      final entries = candidates
          .map((a) => {'key': sanitizedKeys[a.filePath], 'iconPath': a.iconName})
          .toList();
      final entriesJson = jsonEncode(entries).replaceAll("'", "''");

      final script = "Add-Type -AssemblyName System.Drawing; "
          "\$iconDir = '${iconDir.replaceAll("'", "''")}'; "
          "New-Item -ItemType Directory -Force -Path \$iconDir | Out-Null; "
          "\$entries = '$entriesJson' | ConvertFrom-Json; "
          "\$done = @(); "
          "foreach (\$entry in \$entries) { "
          "  try { "
          // DisplayIcon values often end in ",N" (an icon-index into a
          // multi-icon file) — ExtractAssociatedIcon only needs the
          // file path itself, so that suffix is stripped first.
          "    \$cleanPath = \$entry.iconPath -replace ',-?\\d+\$', ''; "
          "    \$outPath = Join-Path \$iconDir (\$entry.key + '.png'); "
          "    if ((Test-Path \$outPath) -or -not (Test-Path \$cleanPath)) { continue } "
          "    \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon(\$cleanPath); "
          "    if (\$icon) { "
          "      \$bitmap = \$icon.ToBitmap(); "
          "      \$bitmap.Save(\$outPath, [System.Drawing.Imaging.ImageFormat]::Png); "
          "      \$bitmap.Dispose(); \$icon.Dispose(); "
          "      \$done += \$entry.key; "
          "    } "
          "  } catch { } "
          "}; "
          "\$done | ConvertTo-Json -Compress";

      final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script]);
      if (result.exitCode != 0) {
        AppLogger.instance.debug(_logSource, 'Icon extraction failed: ${result.stderr}');
        return {};
      }

      final output = (result.stdout as String).trim();
      final extractedKeys = <String>{};
      if (output.isNotEmpty) {
        final decoded = jsonDecode(output);
        final list = decoded is List ? decoded : [decoded];
        extractedKeys.addAll(list.map((e) => e.toString()));
      }

      // Files this run's script skipped because they were already
      // cached from an earlier visit still count as available — only
      // a genuinely missing file means "not available."
      final results = <String, String>{};
      for (final app in candidates) {
        final sanitized = sanitizedKeys[app.filePath]!;
        final pngPath = '$iconDir\\$sanitized.png';
        if (extractedKeys.contains(sanitized) || await File(pngPath).exists()) {
          results[app.filePath] = pngPath;
        }
      }
      return results;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Icon extraction failed: $e\n$st');
      return {};
    }
  }
}
