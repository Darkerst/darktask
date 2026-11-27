import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // TIJDELIJKE, MINIMALE REPRODUCTIE (los van alle normale app-logica:
  // geen sensors, geen AlertMonitorService, geen TrayService, geen
  // SettingsService/BenchmarkHistoryStore) om definitief vast te
  // stellen of het "reageert niet"-probleem puur zit in "veel Dart-
  // isolates met zware synchrone code spawnen in een Flutter Linux
  // GTK-app", losstaand van de rest van DarkTask's eigen code. Start
  // met: ./darktask --mini-isolate-test
  if (args.contains('--mini-isolate-test')) {
    runApp(const _MiniIsolateTestApp());
    return;
  }

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

/// Zie de toelichting bij de `--mini-isolate-test`-vlag in [main]
/// hierboven. Spawnt bij het indrukken van de knop net zoveel pure
/// busy-loop-isolates als er logische cores zijn (dus 12 op deze
/// machine) — exact dezelfde soort rekenlus als de echte CPU-test,
/// maar zonder enige van DarkTask's eigen services eromheen — en telt
/// elke seconde zichtbaar door op het scherm. Als dit venster blijft
/// doortellen zonder "reageert niet", zit het probleem ergens in
/// DarkTask's eigen code rondom de echte test (AlertMonitorService,
/// TrayService, sensors, enz.), niet in het kale isolate-mechanisme
/// zelf. Blijft de teller ook hier stilstaan / verschijnt ook hier
/// "reageert niet", dan is het puur een Flutter/Dart-op-Linux-
/// beperking, losstaand van al het andere in deze app.
class _MiniIsolateTestApp extends StatefulWidget {
  const _MiniIsolateTestApp();

  @override
  State<_MiniIsolateTestApp> createState() => _MiniIsolateTestAppState();
}

class _MiniIsolateTestAppState extends State<_MiniIsolateTestApp> {
  bool _started = false;
  String? _running;
  int _tick = 0;
  Timer? _timer;

  Future<void> _start(String label, {required int workerCount, required bool yield}) async {
    setState(() {
      _started = true;
      _running = label;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _tick++);
    });
    for (var i = 0; i < workerCount; i++) {
      await Isolate.spawn(yield ? _miniBusyLoopWithYield : _miniBusyLoop, i);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cores = Platform.numberOfProcessors;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _started
                    ? 'Bezig: $_running — teller: $_tick'
                    : 'Nog niet gestart ($cores cores gevonden)',
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _started
                    ? null
                    : () => _start('A: $cores isolates, geen yield', workerCount: cores, yield: false),
                child: Text('A: $cores isolates — zonder yield'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _started
                    ? null
                    : () => _start('B: $cores isolates, MET yield', workerCount: cores, yield: true),
                child: Text('B: $cores isolates — met yield'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _started ? null : () => _start('C: 6 isolates, geen yield', workerCount: 6, yield: false),
                child: const Text('C: 6 isolates — zonder yield'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pure, oneindige synchrone rekenlus — bewust zonder enige await/yield
/// — identiek qua aard aan wat de echte CPU-test tot voor kort deed,
/// om de kale isolate-situatie zo zuiver mogelijk na te bootsen.
void _miniBusyLoop(int seed) {
  var x = 1.000001 + seed * 0.00001;
  while (true) {
    for (var i = 0; i < 200000; i++) {
      x = x * 1.0000001 + 0.0000001;
      if (x > 1e6 || x.isNaN || x.isInfinite) x = 1.000001;
    }
  }
}

/// Zelfde rekenlus als [_miniBusyLoop], maar nu met exact dezelfde
/// `await Future<void>.delayed(Duration.zero);`-yield die ook al in de
/// echte CPU-/crypto-workers zit — hier getest in de meest kale,
/// geïsoleerde vorm mogelijk.
void _miniBusyLoopWithYield(int seed) async {
  var x = 1.000001 + seed * 0.00001;
  while (true) {
    for (var i = 0; i < 200000; i++) {
      x = x * 1.0000001 + 0.0000001;
      if (x > 1e6 || x.isNaN || x.isInfinite) x = 1.000001;
    }
    await Future<void>.delayed(Duration.zero);
  }
}
