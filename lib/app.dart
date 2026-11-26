import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/models/app_settings.dart';
import 'core/models/battery_sample.dart';
import 'core/models/cpu_sample.dart';
import 'core/models/disk_sample.dart';
import 'core/models/gpu_sample.dart';
import 'core/models/memory_sample.dart';
import 'core/models/network_sample.dart';
import 'core/models/system_info_sample.dart';
import 'core/theming/accent_theme.dart';
import 'core/theming/app_theme.dart';
import 'features/benchmarks/benchmarks_screen.dart';
import 'features/colors/colors_screen.dart';
import 'features/connections/connections_screen.dart';
import 'features/disk_space/disk_space_screen.dart';
import 'features/installed_apps/installed_apps_screen.dart';
import 'features/logs/log_viewer_screen.dart';
import 'features/monitoring/monitoring_dashboard.dart';
import 'features/performance/performance_screen.dart';
import 'features/power_freq/power_freq_screen.dart';
import 'features/processes/process_list_screen.dart';
import 'features/services/services_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/startup_apps/startup_apps_screen.dart';
import 'features/system_info/system_info_screen.dart';
import 'features/users/users_screen.dart';
import 'services/sensors/system_sensor_service.dart';
import 'services/settings_service.dart';

class DarkTaskApp extends StatefulWidget {
  // Created in main() — its warm-up (see warmUpSensors's doc) is fired
  // there too, but deliberately unawaited and not threaded through
  // here at all any more. This app used to hold a splash screen up
  // behind a spinner until that warm-up finished (a `_SplashScreen`
  // widget, now removed) — worthwhile back when it also *had* to wait
  // several real seconds for LibreHardwareMonitor's cold start, but
  // now that CPU/GPU/network reads no longer block on that (see the
  // background-refresh changes in WindowsSensorService and
  // LibreHardwareMonitorBridge), the wait was mostly just idle
  // spinner time. `_HomeShell` now mounts immediately, showing its
  // usual empty-state placeholders (0%, "N/A", "—") for the brief
  // moment before its own first poll — already fired from initState,
  // typically well under a second — fills them in with real numbers.
  // Same "show what's available, backfill the rest" approach already
  // used by, e.g., the Disk Space screen's own space-vs-SMART split.
  final SystemSensorService sensors;

  const DarkTaskApp({super.key, required this.sensors});

  @override
  State<DarkTaskApp> createState() => _DarkTaskAppState();
}

class _DarkTaskAppState extends State<DarkTaskApp> {
  @override
  void initState() {
    super.initState();
    // Rebuild the MaterialApp (theme + text scale) whenever a setting
    // changes — accent color and text scale are the two settings that
    // affect the app shell itself rather than a single screen.
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance.current;
    final seedColor = settings.accentTheme.seedColor;
    return MaterialApp(
      title: 'DarkTask',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light, seedColor: seedColor),
      darkTheme: buildAppTheme(brightness: Brightness.dark, seedColor: seedColor),
      themeMode: settings.themeMode.flutterThemeMode,
      builder: (context, child) {
        // App-wide text scale — one central override rather than
        // threading a scale factor through every Text widget.
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(settings.textScale),
          ),
          child: child!,
        );
      },
      home: _HomeShell(sensors: widget.sensors),
    );
  }
}

/// A single sidebar entry. Screens are matched to nav items purely by
/// index into the flat _screens list below, so this only needs to
/// describe the row itself.
class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavItem({required this.icon, required this.selectedIcon, required this.label});
}

/// Runs every sensor read a visible screen needs, in parallel, purely
/// to warm caches/native-init-once-paths (PDH, LibreHardwareMonitor,
/// PowerShell's per-core CPU counters, ...) as early as possible.
/// Called from `main()` — immediately after `WidgetsFlutterBinding.
/// ensureInitialized()`, in parallel with `SettingsService.load()` —
/// and deliberately fire-and-forget (`unawaited`) there: nothing in
/// the UI waits on this any more (see `DarkTaskApp`'s doc for why the
/// splash screen that used to gate on it was removed). Its return
/// value is intentionally discarded — `_HomeShell` mounts immediately
/// and each screen's own first poll (already fired from its own
/// `initState`) fetches and displays the same data on its own, so
/// there's nothing left to hand this result to.
///
/// Still genuinely useful to kick off this early despite that: it's
/// what warms the disk/battery/system-info caches other screens read
/// from (so Disk Space/System Info/Power & Freq feel instant the first
/// time they're opened), and starting the CPU/GPU/memory/network reads
/// here too means whatever head start they get overlaps with Flutter's
/// own engine/first-frame startup — by the time `_HomeShell`'s own
/// first poll runs a moment later, some of this may already be warm
/// (PDH initialized, LibreHardwareMonitor's `Computer.Open()` chain
/// under way in the background — see the background-refresh changes
/// in `WindowsSensorService`/`LibreHardwareMonitorBridge` for why that
/// chain no longer blocks anything either way).
///
/// **Bounded, not indefinite.** A hardware/driver combination this
/// wasn't tested against could make the warm-up take unusually long, or
/// never finish — a hard timeout below just stops this function from
/// hanging around forever; it was never load-bearing for the UI to
/// begin with now, so there's nothing further downstream to unblock.
Future<void> warmUpSensors(SystemSensorService sensors) async {
  const warmUpTimeout = Duration(seconds: 6);

  await Future.wait([
    sensors.readCpu().catchError((_) => CpuSample.empty()),
    sensors.readCpuPowerWatts().catchError((_) => null),
    sensors.readMemory().catchError((_) => MemorySample.empty()),
    sensors.readNetwork().catchError((_) => <NetworkSample>[]),
    sensors.readGpus().catchError((_) => <GpuSample>[]),
  ]).timeout(warmUpTimeout, onTimeout: () => const []);

  // Same reasoning as the five above — warms the cache, result
  // otherwise unused. Kept as its own (unawaited-by-the-caller, since
  // this whole function is already fired unawaited from main())
  // Future.wait rather than merged into the one above so a slow
  // disk/battery/system-info read can't hold up the timeout on the
  // more time-sensitive CPU/GPU/memory/network group.
  unawaited(Future.wait([
    sensors.readDisks().catchError((_) => <DiskSample>[]),
    sensors.readBattery().catchError((_) => BatterySample.absent()),
    sensors.readSystemInfo().catchError((_) => SystemInfoSample.unknown()),
  ]));
}

class _HomeShell extends StatefulWidget {
  // Created in main() — see DarkTaskApp's own doc for why this is
  // handed down directly rather than a fresh instance being created
  // here (this exact class used to be built by a `_SplashScreen`
  // instead, now removed).
  final SystemSensorService sensors;

  const _HomeShell({required this.sensors});

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  late int _selectedIndex = SettingsService.instance.current.defaultStartupTabIndex;

  // Created in main() (see DarkTaskApp's own doc) and passed in here
  // directly — not created fresh in this State object. Several
  // screens (Summary, Performance, System
  // Info, Power & Freq, Disk Space, Benchmarks) all read from the same
  // sensor service, and since _buildScreen below constructs a
  // brand-new screen widget on every tab switch (see the comment on
  // that method), a screen-owned instance would be torn down and
  // rebuilt from scratch on every navigation — restarting persistent
  // background processes (Linux's intel_gpu_top, Windows' PowerShell
  // session), re-scanning for GPUs, and resetting every delta-based
  // reading (RAPL power, disk I/O rate, fdinfo GPU load) right when you
  // switch tabs. One shared, long-lived instance here avoids all of
  // that churn.
  SystemSensorService get _sensors => widget.sensors;

  @override
  void initState() {
    super.initState();
    // Offered here, right after this shell's first frame, instead of
    // gating a splash screen on it the way this app used to (see
    // DarkTaskApp's doc) — addPostFrameCallback so the dialog (which
    // needs a BuildContext already attached to the tree, and a
    // Navigator/ScaffoldMessenger above it) doesn't fire before the
    // very first frame has actually been built and painted.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOfferBackgroundFeedSetup());
  }

  /// Offers the one-time background-sensor-service setup (see
  /// `BackgroundSensorFeed`'s own class doc for the full "why" — it's
  /// the actual fix for the LibreHardwareMonitor cold-start existing at
  /// all, not just a way to hide it) right here at first run, instead
  /// of leaving it discoverable only as a button buried in the
  /// Performance screen. Windows-only, and asked at most once ever:
  /// `backgroundFeedSetupOffered` in settings remembers that this was
  /// already offered — whatever the person chose — so a "Niet nu"
  /// answer doesn't turn into a nag on every future launch.
  Future<void> _maybeOfferBackgroundFeedSetup() async {
    if (!Platform.isWindows) return;
    if (SettingsService.instance.current.backgroundFeedSetupOffered) return;

    final active = await _sensors.isBackgroundSensorFeedActive();
    if (!mounted) return;
    // Recorded regardless of what happens below — this is a one-time
    // offer, not a nag, so even "Niet nu" or a setup error means we
    // don't ask again on a future launch.
    await SettingsService.instance.update((s) => s.copyWith(backgroundFeedSetupOffered: true));
    if (active) return; // already set up (e.g. via Performance earlier) — nothing to offer

    final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Snellere opstart instellen?'),
            content: const Text(
              'DarkTask kan CPU-temperatuur en -vermogen voortaan via een eenmalige achtergronddienst '
              'ophalen, in plaats van bij elke opstart opnieuw PowerShell en LibreHardwareMonitor te '
              'starten — dat scheelt een paar seconden opstarttijd, elke keer. Hiervoor is nu één '
              'Windows-goedkeuringsvenster nodig; dat komt daarna niet meer terug. Dit kan ook later nog '
              'via Performance → "Achtergronddienst instellen".',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Niet nu')),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Instellen')),
            ],
          ),
        ) ??
        false;
    if (!accepted || !mounted) return;

    // A SnackBar, not the splash screen's old inline status-text swap
    // — there's no dedicated status area on this screen (it's the real
    // home shell, not a transient loading screen), so a transient
    // toast over whatever's already showing is the natural equivalent.
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Achtergronddienst wordt ingesteld…'), duration: Duration(seconds: 15)),
    );
    final error = await _sensors.setupBackgroundSensorFeed();
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error), duration: const Duration(seconds: 6)));
    }
  }

  // Builds only the currently selected screen — deliberately NOT an
  // IndexedStack keeping all 15 screens alive simultaneously. That
  // architecture (all screens built/laid-out every frame, only the
  // selected one painted) turned out to still trigger a Flutter
  // framework semantics-tree assertion crash even with polling paused
  // on the inactive ones, because IndexedStack's non-selected children
  // remain part of the live render/semantics tree regardless of
  // whether their own timers are running. Switching to "only the
  // active screen exists at all" removes that risk entirely, at the
  // cost of screens resetting their state (poll history, scroll
  // position) when you navigate away and back.
  Widget _buildScreen(int index) {
    switch (index) {
      case 0:
        return MonitoringDashboard(sensors: _sensors);
      case 1:
        return PerformanceScreen(sensors: _sensors);
      case 2:
        return ProcessListScreen(sensors: _sensors);
      case 3:
        return SystemInfoScreen(sensors: _sensors);
      case 4:
        return const StartupAppsScreen();
      case 5:
        return const UsersScreen();
      case 6:
        return const ServicesScreen();
      case 7:
        return PowerFreqScreen(sensors: _sensors);
      case 8:
        return const ConnectionsScreen();
      case 9:
        return const InstalledAppsScreen();
      case 10:
        return DiskSpaceScreen(sensors: _sensors);
      case 11:
        return BenchmarksScreen(sensors: _sensors);
      case 12:
        return const LogViewerScreen();
      case 13:
        return const SettingsScreen();
      case 14:
        return const ColorsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  static const _mainNavItems = [
    _NavItem(icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Summary'),
    _NavItem(icon: Icons.show_chart_outlined, selectedIcon: Icons.show_chart, label: 'Performance'),
    _NavItem(icon: Icons.list_alt_outlined, selectedIcon: Icons.list_alt, label: 'Processes'),
    _NavItem(icon: Icons.info_outline, selectedIcon: Icons.info, label: 'System Info'),
    _NavItem(icon: Icons.rocket_launch_outlined, selectedIcon: Icons.rocket_launch, label: 'Startup apps'),
    _NavItem(icon: Icons.people_outline, selectedIcon: Icons.people, label: 'Users'),
    _NavItem(icon: Icons.build_outlined, selectedIcon: Icons.build, label: 'Services'),
  ];

  static const _secondaryNavItems = [
    _NavItem(icon: Icons.bolt_outlined, selectedIcon: Icons.bolt, label: 'Power & Freq'),
    _NavItem(icon: Icons.lan_outlined, selectedIcon: Icons.lan, label: 'Connections'),
    _NavItem(icon: Icons.apps_outlined, selectedIcon: Icons.apps, label: 'Installed Apps'),
    _NavItem(icon: Icons.storage_outlined, selectedIcon: Icons.storage, label: 'Disk Space'),
    _NavItem(icon: Icons.speed_outlined, selectedIcon: Icons.speed, label: 'Benchmarks'),
    _NavItem(icon: Icons.terminal_outlined, selectedIcon: Icons.terminal, label: 'Log'),
  ];

  static const _bottomNavItems = [
    _NavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: 'Settings'),
    _NavItem(icon: Icons.palette_outlined, selectedIcon: Icons.palette, label: 'Colors'),
  ];

  @override
  void dispose() {
    // The one place the persistent intel_gpu_top process actually gets
    // stopped now: when the whole app shell goes away, not on every
    // per-tab screen dispose (see _sensors' doc comment above).
    _sensors.disposeIntelGpuTop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _buildSidebar(context),
          const VerticalDivider(width: 1),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(_selectedIndex),
              child: _buildScreen(_selectedIndex),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    return Container(
      width: 220,
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            for (var i = 0; i < _mainNavItems.length; i++) _buildNavRow(_mainNavItems[i], i),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(height: 1),
            ),
            for (var i = 0; i < _secondaryNavItems.length; i++)
              _buildNavRow(_secondaryNavItems[i], _mainNavItems.length + i),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(height: 1),
            ),
            for (var i = 0; i < _bottomNavItems.length; i++)
              _buildNavRow(_bottomNavItems[i], _mainNavItems.length + _secondaryNavItems.length + i),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.memory, size: 18, color: Colors.cyanAccent.shade100),
                  const SizedBox(width: 8),
                  Text(
                    'DarkTask',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavRow(_NavItem item, int index) {
    final selected = index == _selectedIndex;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? Theme.of(context).colorScheme.primary.withOpacity(0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _selectedIndex = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: 20,
                  color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      fontSize: 13.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
