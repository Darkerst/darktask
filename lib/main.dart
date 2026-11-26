import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/logging/app_logger.dart';
import 'services/alert_monitor_service.dart';
import 'services/benchmark_history_store.dart';
import 'services/sensors/linux_sensor_service.dart';
import 'services/sensors/system_sensor_service.dart';
import 'services/sensors/windows/native_elevation_check.dart';
import 'services/sensors/windows/windows_sensor_service.dart';
import 'services/power_context.dart';
import 'services/settings_service.dart';
import 'services/tray_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.instance.info('main', 'DarkTask starting up');
  // Logs once, immediately, whether this process is actually running
  // elevated — a definitive, direct answer straight from Windows
  // itself, rather than inferring it from how the app was launched.
  // Safe no-op on Linux (returns null without logging anything).
  NativeElevationCheck.isElevated();

  final SystemSensorService sensors = Platform.isWindows ? WindowsSensorService() : LinuxSensorService();

  // Fire-and-forget, not awaited by anything — this app used to hold a
  // splash screen up behind a spinner until this resolved (see
  // warmUpSensors's and DarkTaskApp's doc in app.dart for why that was
  // removed). Still worth starting here, as early as possible and in
  // parallel with SettingsService.load() below, purely for the free
  // cache-warming overlap with Flutter's own engine/first-frame
  // startup — by the time the home screen's own first poll runs a
  // moment later, some of this may already be warm.
  unawaited(warmUpSensors(sensors));

  // Warmt PowerContext.capture() alvast op bij app-start (fire-and-forget),
  // zodat het Linux-only fork()-moment (powerprofilesctl) nooit meer
  // precies samenvalt met de start van een benchmarktest — zie
  // power_context.dart voor de volledige, geverifieerde uitleg.
  unawaited(PowerContext.capture());

  // Fire-and-forget, same reasoning as warmUpSensors above: on a
  // launch where this process is already running elevated, silently
  // installs/starts whatever this platform's sensors still need (the
  // LHM DLL, the PawnIO driver, the background sensor feed) instead
  // of leaving that for the person to notice via a diagnostic box and
  // press a button — see SystemSensorService.autoProvisionSensorDependencies's
  // doc for the full reasoning and why it's conditioned on elevation.
  // A genuine no-op on Linux and on a non-elevated Windows launch.
  unawaited(sensors.autoProvisionSensorDependencies());

  await SettingsService.instance.load();
  // Fire-and-forget, same reasoning as warmUpSensors above: the
  // Benchmarks screen's "Geschiedenis" view just shows an empty list
  // until this resolves (typically well under a frame), rather than
  // the whole app waiting on a history-file read before its first
  // frame.
  unawaited(BenchmarkHistoryStore.instance.load());

  // Tray icon / close-to-tray, and the background CPU-temp/disk-space
  // alerts that ride on top of it (see TrayService's and
  // AlertMonitorService's own docs) — Windows/Linux only, and
  // deliberately not awaited: neither should hold up the first frame,
  // and both are best-effort (a missing system tray in a minimal Linux
  // desktop environment just means no tray icon, never a crash).
  if (Platform.isWindows || Platform.isLinux) {
    unawaited(TrayService.instance.init());
    AlertMonitorService.instance.start(sensors);
  }

  runApp(DarkTaskApp(sensors: sensors));
}
