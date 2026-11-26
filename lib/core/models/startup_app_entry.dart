/// A single autostart entry, parsed from a .desktop file under
/// ~/.config/autostart (user-specific) or /etc/xdg/autostart
/// (system-wide).
class StartupAppEntry {
  final String name;
  final String? comment;
  final String? execCommand;
  final String? iconName;
  final bool enabled;
  final bool isUserEntry; // true = ~/.config/autostart, false = system-wide
  final String filePath;

  const StartupAppEntry({
    required this.name,
    this.comment,
    this.execCommand,
    this.iconName,
    required this.enabled,
    required this.isUserEntry,
    required this.filePath,
  });
}
