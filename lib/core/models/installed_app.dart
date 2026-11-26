/// Where an installed application's .desktop file came from — useful
/// context since Flatpak/Snap apps are sandboxed differently than
/// system-packaged ones.
enum AppSource { system, user, flatpak, snap }

/// A single installed (GUI) application, parsed from a .desktop file
/// under one of the standard XDG application directories.
class InstalledApp {
  final String name;
  final String? comment;
  final String? execCommand;
  final String? iconName;
  final String? resolvedIconPath; // absolute path to a PNG/XPM file, if found
  final List<String> categories;
  final AppSource source;
  final String filePath;

  const InstalledApp({
    required this.name,
    this.comment,
    this.execCommand,
    this.iconName,
    this.resolvedIconPath,
    this.categories = const [],
    required this.source,
    required this.filePath,
  });

  /// Returns a copy with [resolvedIconPath] filled in — used on
  /// Windows to merge in icons extracted from .exe/.ico files after
  /// the app list itself has already loaded and rendered (see
  /// InstalledAppsService.extractIconsWindows's doc for why that's a
  /// separate, deferred step rather than part of listApps() itself).
  InstalledApp withResolvedIconPath(String? path) => InstalledApp(
        name: name,
        comment: comment,
        execCommand: execCommand,
        iconName: iconName,
        resolvedIconPath: path,
        categories: categories,
        source: source,
        filePath: filePath,
      );
}
