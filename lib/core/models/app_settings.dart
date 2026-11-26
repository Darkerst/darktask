/// Accent color / "phosphor" presets — a nod to the retro-terminal
/// color schemes (green, amber) that classic system monitors and this
/// app's TUI-adjacent aesthetic both draw on, alongside more neutral
/// modern options.
enum AppAccentTheme { cyan, green, amber, blue, mono }

/// Light/dark mode preference. "system" follows the OS setting live —
/// Flutter's MaterialApp re-evaluates this automatically when the OS
/// theme changes while the app is running, no restart needed.
enum AppThemeMode { system, light, dark }

/// Graph/metric identity color palettes — distinct from [AppAccentTheme]
/// above. The accent theme colors buttons, selection highlights, and
/// other one-off UI chrome; a graph palette instead assigns a consistent
/// identity color to each *metric* (CPU, memory, disk, ...) across every
/// chart, gauge, and sparkline that shows it, so "what's this line" stays
/// answerable at a glance no matter which screen you're on.
enum GraphPalette { standard, green, amber, blue, mono }

/// How process rows in the Processes screen are ordered.
enum ProcessSortBy { cpu, memory, name }

/// User-configurable app settings, persisted to disk by
/// [SettingsService]. Kept as one small, flat, immutable value class so
/// every setting has an explicit default and every read is a plain
/// field access — no scattered hardcoded constants across the codebase
/// that a person changing a setting would have no way to find.
class AppSettings {
  /// How often the live monitoring screens (Summary, Performance,
  /// Power & Freq) poll their sensors, in seconds. 0 means paused —
  /// those screens stop refreshing entirely until this is changed back.
  /// Kept to a short, deliberate set of options rather than a free-form
  /// field: sub-1s polling would mostly just measure polling overhead
  /// itself, and anything slower than 5s stops feeling "live".
  final int pollIntervalSeconds;

  /// Whether to show a confirmation dialog before killing a process or
  /// stopping/disabling a systemd service. Deliberately does NOT cover
  /// the Installed Apps uninstall dialog — that one always shows the
  /// exact command and an extra dependency-risk warning for system
  /// packages, regardless of this setting, since removing a package
  /// (unlike killing a process or restarting a service) isn't
  /// trivially undone.
  final bool confirmDestructiveActions;

  /// CPU temperature (°C) at which a running CPU benchmark aborts
  /// itself rather than pushing the hardware further. Configurable
  /// within a safety-conscious range (see [minCpuSafetyCutoffC] /
  /// [maxCpuSafetyCutoffC]) rather than editable to any value, so a
  /// person can tune it for their own cooling setup without being able
  /// to disable the safety cutoff outright.
  final double cpuSafetyCutoffC;

  /// Accent color used throughout the app's Material theme.
  final AppAccentTheme accentTheme;

  /// Light/dark mode preference. Defaults to dark — the app's original
  /// (and only, before this setting existed) look — so upgrading users
  /// see no change unless they deliberately switch it.
  final AppThemeMode themeMode;

  /// Global text scale multiplier, applied app-wide via MediaQuery.
  final double textScale;

  /// Whether the Performance screen's CPU detail view shows a
  /// per-logical-processor breakdown grid, or just the aggregate gauge.
  /// Turning this off is mainly useful on machines with a very high
  /// core count, where dozens of tiny per-core tiles add more visual
  /// noise than insight.
  final bool showPerCoreCpu;

  /// Which sidebar screen the app opens on at startup. Stored as the
  /// same flat index _HomeShellState uses internally.
  final int defaultStartupTabIndex;

  /// Sort order for the Processes screen's process list.
  final ProcessSortBy processSortBy;

  /// Identity-color palette applied to every metric graph, gauge, and
  /// sparkline app-wide (see [GraphPalette]).
  final GraphPalette graphPalette;

  /// Multiplies each palette color's HSL saturation before painting —
  /// 1.0 leaves colors as designed, lower values gradually desaturate
  /// everything toward gray while keeping hue and lightness intact.
  /// Deliberately capped at 1.0 rather than allowing values above it:
  /// most of these accent colors are already near-maximum saturation,
  /// so "boosting" further would mostly just clip rather than do
  /// anything visible.
  final double colorSaturation;

  /// Intensity of an optional soft glow drawn behind graph lines, 0
  /// (off, the default/original look) to 1 (strongest). Purely a
  /// rendering flourish — never affects the data itself.
  final double glowIntensity;

  /// Whether the splash screen has already offered (Windows-only) to
  /// set up `BackgroundSensorFeed`, the one-time Task-Scheduler-based
  /// background service that gives instant CPU temperature/power on
  /// every future launch instead of a fresh LibreHardwareMonitor
  /// cold-start each time. Recorded the first time the offer is shown,
  /// regardless of whether the person accepted — this is a one-time
  /// offer, not a nag, so it's never shown a second time. Always false
  /// on Linux, which has no equivalent concept; harmless there since
  /// nothing ever reads it on that platform.
  final bool backgroundFeedSetupOffered;

  /// Whether closing the main window hides it to the system tray
  /// instead of quitting the app outright (Windows/Linux only — see
  /// TrayService's class doc). Off means the close button quits, same
  /// as before this feature existed.
  final bool minimizeToTrayEnabled;

  /// Whether the one-time "DarkTask is nog actief in het systeemvak"
  /// explainer notification has already been shown. Same
  /// shown-at-most-once pattern as [backgroundFeedSetupOffered] — a
  /// person who already knows how this works shouldn't see it again
  /// on every subsequent close-to-tray.
  final bool trayMinimizeExplained;

  /// Whether a background notification fires when CPU temperature
  /// reaches [cpuTempAlertC]. Off by default — an unwanted warning
  /// popping up mid-benchmark or mid-game is worse than no warning, so
  /// this is opt-in rather than assuming a threshold that fits every
  /// machine's cooling.
  final bool cpuTempAlertEnabled;

  /// CPU temperature (°C) that triggers the alert above, once. Re-arms
  /// once the reading drops 5°C below this (see AlertMonitorService)
  /// so a temperature hovering right at the line doesn't re-notify
  /// every poll.
  final double cpuTempAlertC;

  /// Whether a background notification fires when a disk's free space
  /// percentage drops below [diskSpaceAlertFreePercent]. Off by
  /// default, same reasoning as [cpuTempAlertEnabled].
  final bool diskSpaceAlertEnabled;

  /// Free-space percentage (of total, not just used) below which the
  /// disk-space alert fires, per mount point.
  final double diskSpaceAlertFreePercent;

  /// Whether a background notification fires when RAM usage rises above
  /// [memoryAlertPercent]. Off by default, same reasoning as
  /// [cpuTempAlertEnabled] — a browser tab spike shouldn't page anyone.
  final bool memoryAlertEnabled;

  /// Memory-used percentage (of total physical RAM) that triggers the
  /// alert above, once. Re-arms once usage drops
  /// [AlertMonitorService]'s hysteresis below this, same pattern as
  /// [cpuTempAlertC].
  final double memoryAlertPercent;

  /// Whether a background notification fires when a GPU's temperature
  /// reaches [gpuTempAlertC]. Off by default, same reasoning as
  /// [cpuTempAlertEnabled]. Applies to every GPU DarkTask can read a
  /// temperature for — a machine with more than one alerts on each
  /// independently, mirroring how [diskSpaceAlertEnabled] tracks every
  /// mount point independently rather than just the first one found.
  final bool gpuTempAlertEnabled;

  /// GPU temperature (°C) that triggers the alert above, once per GPU.
  final double gpuTempAlertC;

  /// Whether a background notification fires when combined network
  /// throughput (received + sent, summed across every active
  /// interface) rises above [networkAlertMBps]. Off by default, same
  /// reasoning as [cpuTempAlertEnabled] — useful for spotting
  /// unexpected heavy background traffic (an update downloading, a
  /// sync tool gone rogue) rather than normal browsing.
  final bool networkAlertEnabled;

  /// Combined network throughput (MB/s) that triggers the alert above,
  /// once. Re-arms once throughput drops a relative 20% below this
  /// (see [AlertMonitorService]) rather than a fixed absolute amount —
  /// a flat "-5 MB/s" hysteresis gap would be meaningless at both a
  /// 2 MB/s threshold and a 200 MB/s one.
  final double networkAlertMBps;

  /// Whether a background notification fires when swap/pagefile usage
  /// (distinct from [memoryAlertPercent], which tracks physical RAM)
  /// rises above [swapAlertPercent]. Off by default, same reasoning as
  /// [cpuTempAlertEnabled] — heavy swap use points at genuine memory
  /// pressure in a way high RAM usage alone doesn't always.
  final bool swapAlertEnabled;

  /// Swap/pagefile-used percentage (of total swap/pagefile size) that
  /// triggers the alert above, once.
  final double swapAlertPercent;

  /// Whether a background notification fires when the battery level
  /// drops to or below [batteryAlertPercent] *while discharging* — a
  /// laptop that's plugged in and charging back up through that same
  /// percentage deliberately does not notify (see
  /// [AlertMonitorService]'s battery check for why). Off by default,
  /// same reasoning as [cpuTempAlertEnabled]; always false in effect
  /// on a desktop with no battery, since there's nothing to read.
  final bool batteryAlertEnabled;

  /// Battery percentage that triggers the alert above, once, only
  /// while discharging.
  final double batteryAlertPercent;

  /// Whether a background notification fires when any single CPU core
  /// reaches [perCoreCpuAlertPercent] — distinct from a plain overall
  /// CPU-load alert, which this app doesn't have: on a machine with
  /// many cores, one core pegged at 100% (a runaway single-threaded
  /// process) can look unremarkable in the *total* CPU percentage,
  /// exactly the case this is meant to catch. Off by default, same
  /// reasoning as [cpuTempAlertEnabled].
  final bool perCoreCpuAlertEnabled;

  /// Per-core load percentage that triggers the alert above, once per
  /// core — mirrors how [diskSpaceAlertEnabled] and [gpuTempAlertEnabled]
  /// track each disk/GPU independently rather than just the first one.
  final double perCoreCpuAlertPercent;

  const AppSettings({
    this.pollIntervalSeconds = 1,
    this.confirmDestructiveActions = true,
    this.cpuSafetyCutoffC = 95.0,
    this.accentTheme = AppAccentTheme.cyan,
    this.themeMode = AppThemeMode.dark,
    this.textScale = 1.0,
    this.showPerCoreCpu = true,
    this.defaultStartupTabIndex = 0,
    this.processSortBy = ProcessSortBy.cpu,
    this.graphPalette = GraphPalette.standard,
    this.colorSaturation = 1.0,
    this.glowIntensity = 0.0,
    this.backgroundFeedSetupOffered = false,
    this.minimizeToTrayEnabled = true,
    this.trayMinimizeExplained = false,
    this.cpuTempAlertEnabled = false,
    this.cpuTempAlertC = 85.0,
    this.diskSpaceAlertEnabled = false,
    this.diskSpaceAlertFreePercent = 10.0,
    this.memoryAlertEnabled = false,
    this.memoryAlertPercent = 90.0,
    this.gpuTempAlertEnabled = false,
    this.gpuTempAlertC = 85.0,
    this.networkAlertEnabled = false,
    this.networkAlertMBps = 10.0,
    this.swapAlertEnabled = false,
    this.swapAlertPercent = 80.0,
    this.batteryAlertEnabled = false,
    this.batteryAlertPercent = 20.0,
    this.perCoreCpuAlertEnabled = false,
    this.perCoreCpuAlertPercent = 95.0,
  });

  static const defaults = AppSettings();

  /// Allowed poll intervals, in seconds, for the poll-interval picker.
  /// 0 is the "Gepauzeerd" (paused) option.
  static const availablePollIntervals = [0, 1, 2, 5];

  static const minCpuSafetyCutoffC = 80.0;
  static const maxCpuSafetyCutoffC = 100.0;

  static const availableTextScales = [0.9, 1.0, 1.15];

  static const minColorSaturation = 0.2;
  static const maxColorSaturation = 1.0;

  static const minCpuTempAlertC = 50.0;
  static const maxCpuTempAlertC = 100.0;

  static const minDiskSpaceAlertFreePercent = 1.0;
  static const maxDiskSpaceAlertFreePercent = 50.0;

  static const minMemoryAlertPercent = 50.0;
  static const maxMemoryAlertPercent = 98.0;

  static const minGpuTempAlertC = 50.0;
  static const maxGpuTempAlertC = 100.0;

  static const minNetworkAlertMBps = 1.0;
  static const maxNetworkAlertMBps = 500.0;

  static const minSwapAlertPercent = 20.0;
  static const maxSwapAlertPercent = 95.0;

  static const minBatteryAlertPercent = 5.0;
  static const maxBatteryAlertPercent = 50.0;

  static const minPerCoreCpuAlertPercent = 50.0;
  static const maxPerCoreCpuAlertPercent = 100.0;

  /// Highest valid sidebar index — must be kept in sync with
  /// `_HomeShellState._buildScreen`'s switch in app.dart (15 items,
  /// indices 0–14). A mismatch only affects the startup-tab picker
  /// falling back to Summary, never a crash, since the picker itself
  /// only offers valid indices and fromJson clamps out-of-range values.
  static const maxStartupTabIndex = 14;

  AppSettings copyWith({
    int? pollIntervalSeconds,
    bool? confirmDestructiveActions,
    double? cpuSafetyCutoffC,
    AppAccentTheme? accentTheme,
    AppThemeMode? themeMode,
    double? textScale,
    bool? showPerCoreCpu,
    int? defaultStartupTabIndex,
    ProcessSortBy? processSortBy,
    GraphPalette? graphPalette,
    double? colorSaturation,
    double? glowIntensity,
    bool? backgroundFeedSetupOffered,
    bool? minimizeToTrayEnabled,
    bool? trayMinimizeExplained,
    bool? cpuTempAlertEnabled,
    double? cpuTempAlertC,
    bool? diskSpaceAlertEnabled,
    double? diskSpaceAlertFreePercent,
    bool? memoryAlertEnabled,
    double? memoryAlertPercent,
    bool? gpuTempAlertEnabled,
    double? gpuTempAlertC,
    bool? networkAlertEnabled,
    double? networkAlertMBps,
    bool? swapAlertEnabled,
    double? swapAlertPercent,
    bool? batteryAlertEnabled,
    double? batteryAlertPercent,
    bool? perCoreCpuAlertEnabled,
    double? perCoreCpuAlertPercent,
  }) {
    return AppSettings(
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      confirmDestructiveActions: confirmDestructiveActions ?? this.confirmDestructiveActions,
      cpuSafetyCutoffC: cpuSafetyCutoffC ?? this.cpuSafetyCutoffC,
      accentTheme: accentTheme ?? this.accentTheme,
      themeMode: themeMode ?? this.themeMode,
      textScale: textScale ?? this.textScale,
      showPerCoreCpu: showPerCoreCpu ?? this.showPerCoreCpu,
      defaultStartupTabIndex: defaultStartupTabIndex ?? this.defaultStartupTabIndex,
      processSortBy: processSortBy ?? this.processSortBy,
      graphPalette: graphPalette ?? this.graphPalette,
      colorSaturation: colorSaturation ?? this.colorSaturation,
      glowIntensity: glowIntensity ?? this.glowIntensity,
      backgroundFeedSetupOffered: backgroundFeedSetupOffered ?? this.backgroundFeedSetupOffered,
      minimizeToTrayEnabled: minimizeToTrayEnabled ?? this.minimizeToTrayEnabled,
      trayMinimizeExplained: trayMinimizeExplained ?? this.trayMinimizeExplained,
      cpuTempAlertEnabled: cpuTempAlertEnabled ?? this.cpuTempAlertEnabled,
      cpuTempAlertC: cpuTempAlertC ?? this.cpuTempAlertC,
      diskSpaceAlertEnabled: diskSpaceAlertEnabled ?? this.diskSpaceAlertEnabled,
      diskSpaceAlertFreePercent: diskSpaceAlertFreePercent ?? this.diskSpaceAlertFreePercent,
      memoryAlertEnabled: memoryAlertEnabled ?? this.memoryAlertEnabled,
      memoryAlertPercent: memoryAlertPercent ?? this.memoryAlertPercent,
      gpuTempAlertEnabled: gpuTempAlertEnabled ?? this.gpuTempAlertEnabled,
      gpuTempAlertC: gpuTempAlertC ?? this.gpuTempAlertC,
      networkAlertEnabled: networkAlertEnabled ?? this.networkAlertEnabled,
      networkAlertMBps: networkAlertMBps ?? this.networkAlertMBps,
      swapAlertEnabled: swapAlertEnabled ?? this.swapAlertEnabled,
      swapAlertPercent: swapAlertPercent ?? this.swapAlertPercent,
      batteryAlertEnabled: batteryAlertEnabled ?? this.batteryAlertEnabled,
      batteryAlertPercent: batteryAlertPercent ?? this.batteryAlertPercent,
      perCoreCpuAlertEnabled: perCoreCpuAlertEnabled ?? this.perCoreCpuAlertEnabled,
      perCoreCpuAlertPercent: perCoreCpuAlertPercent ?? this.perCoreCpuAlertPercent,
    );
  }

  Map<String, dynamic> toJson() => {
        'pollIntervalSeconds': pollIntervalSeconds,
        'confirmDestructiveActions': confirmDestructiveActions,
        'cpuSafetyCutoffC': cpuSafetyCutoffC,
        'accentTheme': accentTheme.name,
        'themeMode': themeMode.name,
        'textScale': textScale,
        'showPerCoreCpu': showPerCoreCpu,
        'defaultStartupTabIndex': defaultStartupTabIndex,
        'processSortBy': processSortBy.name,
        'graphPalette': graphPalette.name,
        'colorSaturation': colorSaturation,
        'glowIntensity': glowIntensity,
        'backgroundFeedSetupOffered': backgroundFeedSetupOffered,
        'minimizeToTrayEnabled': minimizeToTrayEnabled,
        'trayMinimizeExplained': trayMinimizeExplained,
        'cpuTempAlertEnabled': cpuTempAlertEnabled,
        'cpuTempAlertC': cpuTempAlertC,
        'diskSpaceAlertEnabled': diskSpaceAlertEnabled,
        'diskSpaceAlertFreePercent': diskSpaceAlertFreePercent,
        'memoryAlertEnabled': memoryAlertEnabled,
        'memoryAlertPercent': memoryAlertPercent,
        'gpuTempAlertEnabled': gpuTempAlertEnabled,
        'gpuTempAlertC': gpuTempAlertC,
        'networkAlertEnabled': networkAlertEnabled,
        'networkAlertMBps': networkAlertMBps,
        'swapAlertEnabled': swapAlertEnabled,
        'swapAlertPercent': swapAlertPercent,
        'batteryAlertEnabled': batteryAlertEnabled,
        'batteryAlertPercent': batteryAlertPercent,
        'perCoreCpuAlertEnabled': perCoreCpuAlertEnabled,
        'perCoreCpuAlertPercent': perCoreCpuAlertPercent,
      };

  /// Builds from decoded JSON, falling back field-by-field to defaults
  /// for anything missing or malformed rather than rejecting the whole
  /// file — so a settings file from an older version with fewer fields,
  /// or one a person hand-edited slightly wrong, still loads sensibly.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawInterval = json['pollIntervalSeconds'];
    final interval = rawInterval is int && availablePollIntervals.contains(rawInterval)
        ? rawInterval
        : defaults.pollIntervalSeconds;

    final rawCutoff = json['cpuSafetyCutoffC'];
    final cutoff = rawCutoff is num
        ? rawCutoff.toDouble().clamp(minCpuSafetyCutoffC, maxCpuSafetyCutoffC)
        : defaults.cpuSafetyCutoffC;

    final rawConfirm = json['confirmDestructiveActions'];
    final confirm = rawConfirm is bool ? rawConfirm : defaults.confirmDestructiveActions;

    final rawAccent = json['accentTheme'];
    final accent = rawAccent is String
        ? AppAccentTheme.values.firstWhere(
            (v) => v.name == rawAccent,
            orElse: () => defaults.accentTheme,
          )
        : defaults.accentTheme;

    final rawThemeMode = json['themeMode'];
    final themeMode = rawThemeMode is String
        ? AppThemeMode.values.firstWhere(
            (v) => v.name == rawThemeMode,
            orElse: () => defaults.themeMode,
          )
        : defaults.themeMode;

    final rawScale = json['textScale'];
    final scale = rawScale is num && availableTextScales.contains(rawScale.toDouble())
        ? rawScale.toDouble()
        : defaults.textScale;

    final rawPerCore = json['showPerCoreCpu'];
    final perCore = rawPerCore is bool ? rawPerCore : defaults.showPerCoreCpu;

    final rawStartupTab = json['defaultStartupTabIndex'];
    final startupTab = rawStartupTab is int && rawStartupTab >= 0 && rawStartupTab <= maxStartupTabIndex
        ? rawStartupTab
        : defaults.defaultStartupTabIndex;

    final rawSortBy = json['processSortBy'];
    final sortBy = rawSortBy is String
        ? ProcessSortBy.values.firstWhere(
            (v) => v.name == rawSortBy,
            orElse: () => defaults.processSortBy,
          )
        : defaults.processSortBy;

    final rawPalette = json['graphPalette'];
    final palette = rawPalette is String
        ? GraphPalette.values.firstWhere(
            (v) => v.name == rawPalette,
            orElse: () => defaults.graphPalette,
          )
        : defaults.graphPalette;

    final rawSaturation = json['colorSaturation'];
    final saturation = rawSaturation is num
        ? rawSaturation.toDouble().clamp(minColorSaturation, maxColorSaturation)
        : defaults.colorSaturation;

    final rawGlow = json['glowIntensity'];
    final glow = rawGlow is num ? rawGlow.toDouble().clamp(0.0, 1.0) : defaults.glowIntensity;

    final rawFeedOffered = json['backgroundFeedSetupOffered'];
    final feedOffered = rawFeedOffered is bool ? rawFeedOffered : defaults.backgroundFeedSetupOffered;

    final rawMinimizeToTray = json['minimizeToTrayEnabled'];
    final minimizeToTray = rawMinimizeToTray is bool ? rawMinimizeToTray : defaults.minimizeToTrayEnabled;

    final rawTrayExplained = json['trayMinimizeExplained'];
    final trayExplained = rawTrayExplained is bool ? rawTrayExplained : defaults.trayMinimizeExplained;

    final rawCpuAlertEnabled = json['cpuTempAlertEnabled'];
    final cpuAlertEnabled = rawCpuAlertEnabled is bool ? rawCpuAlertEnabled : defaults.cpuTempAlertEnabled;

    final rawCpuAlertC = json['cpuTempAlertC'];
    final cpuAlertC = rawCpuAlertC is num
        ? rawCpuAlertC.toDouble().clamp(minCpuTempAlertC, maxCpuTempAlertC)
        : defaults.cpuTempAlertC;

    final rawDiskAlertEnabled = json['diskSpaceAlertEnabled'];
    final diskAlertEnabled = rawDiskAlertEnabled is bool ? rawDiskAlertEnabled : defaults.diskSpaceAlertEnabled;

    final rawDiskAlertPercent = json['diskSpaceAlertFreePercent'];
    final diskAlertPercent = rawDiskAlertPercent is num
        ? rawDiskAlertPercent.toDouble().clamp(minDiskSpaceAlertFreePercent, maxDiskSpaceAlertFreePercent)
        : defaults.diskSpaceAlertFreePercent;

    final rawMemAlertEnabled = json['memoryAlertEnabled'];
    final memAlertEnabled = rawMemAlertEnabled is bool ? rawMemAlertEnabled : defaults.memoryAlertEnabled;

    final rawMemAlertPercent = json['memoryAlertPercent'];
    final memAlertPercent = rawMemAlertPercent is num
        ? rawMemAlertPercent.toDouble().clamp(minMemoryAlertPercent, maxMemoryAlertPercent)
        : defaults.memoryAlertPercent;

    final rawGpuAlertEnabled = json['gpuTempAlertEnabled'];
    final gpuAlertEnabled = rawGpuAlertEnabled is bool ? rawGpuAlertEnabled : defaults.gpuTempAlertEnabled;

    final rawGpuAlertC = json['gpuTempAlertC'];
    final gpuAlertC = rawGpuAlertC is num
        ? rawGpuAlertC.toDouble().clamp(minGpuTempAlertC, maxGpuTempAlertC)
        : defaults.gpuTempAlertC;

    final rawNetAlertEnabled = json['networkAlertEnabled'];
    final netAlertEnabled = rawNetAlertEnabled is bool ? rawNetAlertEnabled : defaults.networkAlertEnabled;

    final rawNetAlertMBps = json['networkAlertMBps'];
    final netAlertMBps = rawNetAlertMBps is num
        ? rawNetAlertMBps.toDouble().clamp(minNetworkAlertMBps, maxNetworkAlertMBps)
        : defaults.networkAlertMBps;

    final rawSwapAlertEnabled = json['swapAlertEnabled'];
    final swapAlertEnabledVal = rawSwapAlertEnabled is bool ? rawSwapAlertEnabled : defaults.swapAlertEnabled;

    final rawSwapAlertPercent = json['swapAlertPercent'];
    final swapAlertPercentVal = rawSwapAlertPercent is num
        ? rawSwapAlertPercent.toDouble().clamp(minSwapAlertPercent, maxSwapAlertPercent)
        : defaults.swapAlertPercent;

    final rawBatteryAlertEnabled = json['batteryAlertEnabled'];
    final batteryAlertEnabledVal =
        rawBatteryAlertEnabled is bool ? rawBatteryAlertEnabled : defaults.batteryAlertEnabled;

    final rawBatteryAlertPercent = json['batteryAlertPercent'];
    final batteryAlertPercentVal = rawBatteryAlertPercent is num
        ? rawBatteryAlertPercent.toDouble().clamp(minBatteryAlertPercent, maxBatteryAlertPercent)
        : defaults.batteryAlertPercent;

    final rawPerCoreCpuAlertEnabled = json['perCoreCpuAlertEnabled'];
    final perCoreCpuAlertEnabledVal =
        rawPerCoreCpuAlertEnabled is bool ? rawPerCoreCpuAlertEnabled : defaults.perCoreCpuAlertEnabled;

    final rawPerCoreCpuAlertPercent = json['perCoreCpuAlertPercent'];
    final perCoreCpuAlertPercentVal = rawPerCoreCpuAlertPercent is num
        ? rawPerCoreCpuAlertPercent.toDouble().clamp(minPerCoreCpuAlertPercent, maxPerCoreCpuAlertPercent)
        : defaults.perCoreCpuAlertPercent;

    return AppSettings(
      pollIntervalSeconds: interval,
      confirmDestructiveActions: confirm,
      cpuSafetyCutoffC: cutoff,
      accentTheme: accent,
      themeMode: themeMode,
      textScale: scale,
      showPerCoreCpu: perCore,
      defaultStartupTabIndex: startupTab,
      processSortBy: sortBy,
      graphPalette: palette,
      colorSaturation: saturation,
      glowIntensity: glow,
      backgroundFeedSetupOffered: feedOffered,
      minimizeToTrayEnabled: minimizeToTray,
      trayMinimizeExplained: trayExplained,
      cpuTempAlertEnabled: cpuAlertEnabled,
      cpuTempAlertC: cpuAlertC,
      diskSpaceAlertEnabled: diskAlertEnabled,
      diskSpaceAlertFreePercent: diskAlertPercent,
      memoryAlertEnabled: memAlertEnabled,
      memoryAlertPercent: memAlertPercent,
      gpuTempAlertEnabled: gpuAlertEnabled,
      gpuTempAlertC: gpuAlertC,
      networkAlertEnabled: netAlertEnabled,
      networkAlertMBps: netAlertMBps,
      swapAlertEnabled: swapAlertEnabledVal,
      swapAlertPercent: swapAlertPercentVal,
      batteryAlertEnabled: batteryAlertEnabledVal,
      batteryAlertPercent: batteryAlertPercentVal,
      perCoreCpuAlertEnabled: perCoreCpuAlertEnabledVal,
      perCoreCpuAlertPercent: perCoreCpuAlertPercentVal,
    );
  }
}
