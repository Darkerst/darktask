import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

import '../core/logging/app_logger.dart';
import 'settings_service.dart';

const _logSource = 'TrayService';

/// System tray icon, right-click menu, and "close hides instead of
/// quits" window behavior — Windows and Linux only (mirrors every
/// other platform split in this codebase; macOS was never a target).
///
/// This is a deliberately separate feature from the auto-update idea
/// floated alongside it: this one needs no network access at all
/// (tray_manager/window_manager/local_notifier are all purely local —
/// drawing an icon, reading a click, showing an OS-native toast), so
/// it doesn't touch the zero-network-calls design principle documented
/// on the sensor services. That's why this got built immediately once
/// asked for ("tray/notificaties dit wel"), while auto-update is still
/// waiting on a hosting decision.
///
/// Singleton, same pattern as [SettingsService]/`AppLogger` — one
/// instance for the app's whole lifetime, initialized once from
/// `main()`. `TrayListener`/`WindowListener` are plain mixins with
/// override points (not tied to any particular Widget), so this can be
/// a singleton service object rather than needing to live inside a
/// State — it just has to stay alive and registered for as long as the
/// app runs, which a singleton naturally does.
class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;
  bool _notifierReady = false;

  static const _menuKeyShow = 'show';
  static const _menuKeyQuit = 'quit';

  /// True only while a deliberate "actually quit" is in flight (Afsluiten
  /// menu item, or the setting being off at close time) — lets
  /// [onWindowClose] tell that apart from an ordinary close-button
  /// press without needing to touch window_manager's own prevent-close
  /// flag twice in a row.
  bool _quitting = false;

  bool get isSupported => Platform.isWindows || Platform.isLinux;

  /// Sets up the tray icon, its context menu, and the close→hide
  /// interception. Safe to call more than once (no-ops after the
  /// first) and a no-op entirely on unsupported platforms. Best-effort
  /// throughout — a tray/window-manager failure (e.g. no system tray
  /// present in a minimal Linux desktop environment) logs and leaves
  /// the app working exactly as it did before this feature existed,
  /// never a reason to crash startup.
  Future<void> init() async {
    if (_initialized || !isSupported) return;
    _initialized = true;

    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      // Always intercepted at the window_manager level; the setting
      // itself is only consulted inside onWindowClose below, so
      // toggling it in Settings takes effect on the very next close
      // without needing to re-register anything here.
      await windowManager.setPreventClose(true);
    } catch (e) {
      AppLogger.instance.error(_logSource, 'window_manager init failed: $e');
    }

    try {
      final iconPath = Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png';
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('DarkTask');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: _menuKeyShow, label: 'Toon DarkTask'),
        MenuItem.separator(),
        MenuItem(key: _menuKeyQuit, label: 'Afsluiten'),
      ]));
      trayManager.addListener(this);
      AppLogger.instance.info(
        _logSource,
        'Systeemvakicoon actief. Sluitknop verbergt naar systeemvak wanneer dat in Settings is '
        'ingeschakeld (standaard aan).',
      );
    } catch (e) {
      AppLogger.instance.error(_logSource, 'tray_manager init failed: $e');
    }

    try {
      await localNotifier.setup(appName: 'DarkTask');
      _notifierReady = true;
      AppLogger.instance.info(_logSource, 'Achtergrondmeldingen (local_notifier) actief.');
    } catch (e) {
      AppLogger.instance.error(_logSource, 'local_notifier init failed: $e');
    }
  }

  /// Shows a native desktop notification (Windows toast / Linux
  /// libnotify via local_notifier). Best-effort: a platform with no
  /// notification daemon running (some minimal Linux setups) just logs
  /// and drops it — never surfaced to the user as an error, since a
  /// missed background alert isn't worth interrupting anything for.
  Future<void> showNotification({required String title, required String body}) async {
    if (!_notifierReady) return;
    try {
      final notification = LocalNotification(title: title, body: body);
      await notification.show();
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to show notification "$title": $e');
    }
  }

  Future<void> _showAndFocus() async {
    try {
      // show() already gives the window focus (per window_manager's own
      // docs) — no separate focus() call needed.
      await windowManager.show();
      if (Platform.isLinux) {
        // Linux/GTK-specifieke workaround: na hide() + show() bleef het
        // venster soms een zwart vlak tonen totdat er een resize-event
        // binnenkwam — Flutter/GTK "vergeet" blijkbaar opnieuw te
        // tekenen na het simpelweg weer zichtbaar maken (bevestigd: het
        // venster handmatig een klein beetje resizen liet de echte
        // inhoud alsnog verschijnen). Deze onzichtbare resize-nudge (1
        // pixel erbij en meteen weer terug) dwingt diezelfde repaint af
        // zonder dat de gebruiker het zelf hoeft te doen.
        final size = await windowManager.getSize();
        await windowManager.setSize(Size(size.width + 1, size.height));
        // Zonder deze korte pauze volgen de twee setSize()-aanroepen
        // elkaar te snel op om GTK er daadwerkelijk een frame tussenin
        // te laten tekenen — dan is het netto effect "geen zichtbare
        // resize" en dus ook geen repaint, precies zoals we zagen (geen
        // verbetering zonder deze pauze).
        await Future.delayed(const Duration(milliseconds: 100));
        await windowManager.setSize(size);
      }
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Failed to show window: $e');
    }
  }

  /// Actually exits the app, bypassing the hide-to-tray interception —
  /// the only path that should ever call `windowManager.destroy()`.
  Future<void> _quit() async {
    _quitting = true;
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (_) {
      // Best-effort cleanup only — a failed tray teardown is not a
      // reason to keep the app alive against the user's explicit
      // "Afsluiten" request.
    }
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    await windowManager.destroy();
  }

  // --- WindowListener ---

  @override
  void onWindowClose() async {
    if (_quitting) return;
    if (SettingsService.instance.current.minimizeToTrayEnabled) {
      await windowManager.hide();
      if (!SettingsService.instance.current.trayMinimizeExplained) {
        await SettingsService.instance.update((s) => s.copyWith(trayMinimizeExplained: true));
        unawaited(showNotification(
          title: 'DarkTask draait nog',
          body: 'Het venster is verborgen, maar DarkTask blijft actief in het systeemvak. '
              'Klik op het icoon om het weer te openen, of gebruik "Afsluiten" om te stoppen.',
        ));
      }
    } else {
      await _quit();
    }
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() {
    unawaited(_showAndFocus());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuKeyShow:
        unawaited(_showAndFocus());
        break;
      case _menuKeyQuit:
        unawaited(_quit());
        break;
    }
  }
}
