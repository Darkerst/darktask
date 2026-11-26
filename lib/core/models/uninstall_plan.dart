/// How to remove a given installed app — resolved per-app since it
/// depends on where the .desktop file came from and, for
/// system-packaged apps, which package owns it (found via a reverse
/// package-manager lookup).
enum UninstallMethod {
  flatpak,
  snap,
  systemPackage,
  desktopFileOnly, // just delete the user's own .desktop file
  // Windows-specific: run the exact UninstallString/QuietUninstallString
  // already recorded in the app's own registry entry. Unlike the Linux
  // methods above, this needs no reverse-lookup to determine — the
  // uninstall command is registered alongside the app's own metadata
  // at install time, which is precisely what Control Panel's "Programs
  // and Features" itself reads to build its own Uninstall button.
  windowsUninstaller,
  unknown, // couldn't determine a safe removal method
}

class UninstallPlan {
  final UninstallMethod method;
  final String? packageOrId;
  final String? displayCommand; // human-readable, shown in the confirmation dialog
  final String? executable; // actual command to run, e.g. "pkexec" or "flatpak"
  final List<String>? commandArgs; // actual args, kept separate from displayCommand on purpose
  final bool requiresRoot;

  const UninstallPlan({
    required this.method,
    this.packageOrId,
    this.displayCommand,
    this.executable,
    this.commandArgs,
    this.requiresRoot = false,
  });
}
