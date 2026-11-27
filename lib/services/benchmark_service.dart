import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:path_provider/path_provider.dart';

import '../core/logging/app_logger.dart';
import '../core/models/benchmark_models.dart';
import '../core/models/gpu_sample.dart';
import 'benchmark_cpu_temp_feed.dart';
import '../core/models/battery_energy_sample.dart';
import 'benchmark_history_store.dart';
import 'power_context.dart';
import 'sensors/system_sensor_service.dart';
import 'sensors/windows/opencl_compute_reader.dart';
import 'settings_service.dart';

const _logSource = 'BenchmarkService';

/// A running (or just-finished) benchmark: a live progress stream plus a
/// future that resolves to the final result once the run ends, whether
/// by completing normally or being aborted (thermal cutoff, disk error,
/// or user cancellation).
class BenchmarkRun {
  final Stream<BenchmarkProgress> progress;
  final Future<BenchmarkResult> result;
  final void Function() cancel;

  const BenchmarkRun({required this.progress, required this.result, required this.cancel});
}

/// Same shape as [BenchmarkRun], but for the battery-drain test, which
/// resolves to a [BatteryTestResult] instead — a different measurement
/// shape (before/after capacity, not a comparable "higher is better"
/// score) that doesn't fit BenchmarkResult.
class BatteryTestRun {
  final Stream<BenchmarkProgress> progress;
  final Future<BatteryTestResult> result;
  final void Function() cancel;

  const BatteryTestRun({required this.progress, required this.result, required this.cancel});
}

class BenchmarkService {
  final SystemSensorService sensors;
  BenchmarkService(this.sensors) : _cpuTempFeed = BenchmarkCpuTempFeed(sensors);

  // Shared across the CPU, memory, and crypto tests' safety timers —
  // see BenchmarkCpuTempFeed's own doc for why: without this, running
  // several of them at once (as "Alles tegelijk" does) meant that many
  // independent Timer.periodic pollers all hitting the same CPU-temp
  // sensor pathway at once, which could — and, in testing, did —
  // starve each other out and trip the "sensor too slow" safety abort
  // on a CPU that was never actually in danger.
  final BenchmarkCpuTempFeed _cpuTempFeed;

  // Static, not tied to any one BenchmarkService instance (the
  // benchmarks screen creates its own fresh instance per visit — see
  // BenchmarksScreenState) — a true app-wide counter of how many of
  // the CPU/memory/crypto tests are currently pegging cores. Added
  // after a Windows-only report of the app "stagnating" often during
  // the CPU test specifically: AlertMonitorService's own 20s
  // background poll (started once in main(), never paused, reading
  // the same shared SystemSensorService/PowerShellSession every other
  // screen uses) kept issuing its own sensor reads the whole time a
  // CPU-pegging test ran. On Windows, a maxed-out CPU can itself starve
  // the single shared PowerShell helper session of scheduling time —
  // the exact problem BenchmarkCpuTempFeed's own doc already describes
  // for the three sub-tests competing with *each other* — but nothing
  // previously accounted for AlertMonitorService as a fourth,
  // always-on competitor for that same session, including during a
  // test it has nothing to do with. Every queued PowerShell command
  // waits for the ones ahead of it, so this doesn't just make
  // AlertMonitorService's own checks late — it compounds into longer
  // and longer waits for every other screen's sensor reads too, for as
  // long as the backlog takes to drain, which on a 10-minute duurtest
  // could be a long time. AlertMonitorService checks
  // [isCpuHeavyTestRunning] and simply skips its poll while it's true,
  // rather than adding to a queue it would only make worse.
  static int _activeCpuHeavyTests = 0;

  /// True while at least one CPU, memory, or crypto stress test is
  /// currently running somewhere in the app (see [_activeCpuHeavyTests]
  /// above for why this exists and why it's static).
  static bool get isCpuHeavyTestRunning => _activeCpuHeavyTests > 0;

  // Session-local run history, keyed by type+intensity — lets the
  // results screen show a genuine bar-chart comparison against your
  // own earlier runs on this machine (this session only; not
  // persisted). Deliberately NOT compared against any external
  // reference database, since we have no real data for that — showing
  // invented "typical CPU" scores would be presenting fabricated
  // numbers as real.
  final Map<String, List<BenchmarkResult>> _sessionHistory = {};

  String _historyKey(BenchmarkType type, BenchmarkIntensity intensity) =>
      '${type.name}_${intensity.name}';

  List<BenchmarkResult> historyFor(BenchmarkType type, BenchmarkIntensity intensity) =>
      List.unmodifiable(_sessionHistory[_historyKey(type, intensity)] ?? const []);

  /// Records a completed run into the session history. Public so the
  /// GPU test (whose result-building logic lives in the UI layer, not
  /// here) can participate in the same shared history as CPU/Disk.
  ///
  /// Also persists to [BenchmarkHistoryStore] so the run is still there
  /// after the app is closed and reopened — fire-and-forget (this
  /// method itself stays sync, matching every existing call site),
  /// since a failed history save is logged by the store itself and
  /// shouldn't block or fail the benchmark screen either way.
  void recordResult(BenchmarkResult result) {
    if (result.aborted || result.score == null) return; // nothing meaningful to compare
    final key = _historyKey(result.type, result.intensity);
    final list = _sessionHistory.putIfAbsent(key, () => []);
    list.add(result);
    unawaited(BenchmarkHistoryStore.instance.add(result));
  }

  /// Legt bij de start van een test vast onder welke stroomcondities hij
  /// draait (netstroom/accu + energieplan) en logt dat, zodat scores van
  /// dezelfde machine eerlijk vergeleken kunnen worden. Best-effort: gooit
  /// nooit.
  Future<PowerContext> _logPowerAtStart(String testName) async {
    final ctx = await PowerContext.capture();
    // "Alles tegelijk" start vijf tests binnen ~2 seconden met dezelfde
    // voedingscontext; die eenmalig loggen (de details van elk resultaat
    // bevatten de context sowieso apart).
    final line = 'voeding ${ctx.sourceLabel}, energieplan ${ctx.plan}';
    final now = DateTime.now();
    final lastAt = _lastPowerLogAt;
    final repeat = lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 10) &&
        _lastPowerLogLine == line;
    if (!repeat) {
      _lastPowerLogAt = now;
      _lastPowerLogLine = line;
      AppLogger.instance.info(_logSource, 'Voedingscontext bij start van $testName: $line');
      if (ctx.onAc == false) {
        AppLogger.instance.info(_logSource,
            'Op accu: CPU-boost en vermogenslimieten zijn dan vaak lager; '
            'vergelijk deze scores niet met runs op netstroom.');
      }
    }
    return ctx;
  }

  DateTime? _lastPowerLogAt;
  String? _lastPowerLogLine;

  /// Details voor het resultaat: de voedingscontext van de start, plus een
  /// waarschuwing (en logregel) als die tijdens de test veranderd is.
  Future<Map<String, String>> _powerDetails(PowerContext start) async {
    final end = await PowerContext.capture();
    final change = start.changeSince(end);
    if (change != null) {
      AppLogger.instance.info(_logSource, 'Let op: $change');
    }
    return {
      'voeding': start.sourceLabel,
      'energieplan': start.plan,
      if (change != null) 'let op': change,
    };
  }

  /// Same run history as [historyFor], but read from disk across app
  /// restarts rather than just this session — what the "Geschiedenis"
  /// view in the benchmarks screen shows.
  List<BenchmarkResult> persistentHistoryFor(BenchmarkType type, BenchmarkIntensity intensity) =>
      BenchmarkHistoryStore.instance.forType(type, intensity);

  // ---------------------------------------------------------------------
  // Los workerproces i.p.v. Dart-isolate voor "zwaar"/"duurtest" —
  // ROOT CAUSE EN WAAROM (bevestigd door het Dart-team zelf, zie
  // dart-lang/sdk#51254 en flutter/flutter#161224): de Dart VM staat
  // maar een vast, klein aantal isolates toe dat écht parallel mag
  // draaien BINNEN ÉÉN VM-INSTANTIE, ongeacht het aantal CPU-cores — en
  // spawnt daarbovenop nog eigen GC-hulpthreads
  // (marker_tasks/compactor_tasks) zodra er genoeg garbage is
  // opgebouwd, waardoor zelfs een voorzichtig aantal isolates die
  // limiet alsnog kan overschrijden. Een los OS-proces heeft zijn EIGEN
  // Dart VM-instantie, dus die limiet geldt daar niet overheen — exact
  // zoals stress-ng, AIDA64 en andere "echte" benchmarktools hun
  // workers als losse processen draaien i.p.v. threads/isolates binnen
  // één proces. Zie tools/benchmark_worker/ voor de broncode van dat
  // losse programma.
  //
  // Dit vereist wel dat die losse executable daadwerkelijk meegeleverd
  // is naast de hoofd-app (de CI-pipeline compileert en bundelt 'm als
  // "darktask_benchmark_worker") — ontbreekt hij (bijv. tijdens
  // "flutter run" in ontwikkeling, zonder die CI-stap), dan vallen
  // _cpuWorkerCountFor/_cryptoWorkerCountFor terug op de oude, veilige
  // isolate-cap van 3 workers, zodat de app ook dan nooit kan
  // vastlopen — alleen met een lagere score.
  //
  // Alleen relevant op Linux: dit "reageert niet"-probleem is
  // Linux-specifiek; de Windows-tests blijven ongewijzigd op isolates.
  File? get _benchmarkWorkerBinary {
    if (_benchmarkWorkerBinaryChecked) return _benchmarkWorkerBinaryCache;
    _benchmarkWorkerBinaryChecked = true;
    if (!Platform.isLinux) return null;
    final dir = File(Platform.resolvedExecutable).parent.path;
    final candidate = File('$dir${Platform.pathSeparator}darktask_benchmark_worker');
    _benchmarkWorkerBinaryCache = candidate.existsSync() ? candidate : null;
    return _benchmarkWorkerBinaryCache;
  }

  File? _benchmarkWorkerBinaryCache;
  bool _benchmarkWorkerBinaryChecked = false;

  // ---------------------------------------------------------------------
  // CPU test — real work: N isolates each run a bounded floating-point
  // busy loop for the test duration, reporting their operation counts
  // back periodically. The combined operations/sec across all isolates
  // is the score. Multiple isolates genuinely load multiple CPU cores,
  // unlike a single-threaded loop on the main isolate.
  // ---------------------------------------------------------------------

  int _cpuWorkerCountFor(BenchmarkIntensity intensity) {
    final cores = Platform.numberOfProcessors;
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 1;
      case BenchmarkIntensity.gemiddeld:
        return max(1, (cores / 2).round());
      case BenchmarkIntensity.zwaar:
      case BenchmarkIntensity.duurtest:
        // Vol aantal cores zodra het losse workerproces beschikbaar is
        // (zie _benchmarkWorkerBinary hierboven) — dan geldt de Dart
        // VM-isolate-limiet niet meer, want elk workerproces draait in
        // zijn eigen VM-instantie. Zonder dat losse programma (bijv.
        // tijdens "flutter run" in ontwikkeling) blijft de oude,
        // empirisch bevestigd veilige isolate-cap van 3 workers gelden,
        // zodat de app nooit kan vastlopen — wel met een lagere score.
        return _benchmarkWorkerBinary != null ? cores : min(3, cores);
    }
  }

  Duration _cpuDurationFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return const Duration(seconds: 15);
      case BenchmarkIntensity.gemiddeld:
        return const Duration(seconds: 30);
      case BenchmarkIntensity.zwaar:
        return const Duration(seconds: 45);
      case BenchmarkIntensity.duurtest:
        return const Duration(minutes: 10);
    }
  }

  BenchmarkRun startCpuTest(BenchmarkIntensity intensity, {int? workerCountOverride}) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;

    Future<void> run() async {
      final workerCount = workerCountOverride ?? _cpuWorkerCountFor(intensity);
      final duration = _cpuDurationFor(intensity);
      // Losse OS-processen (i.p.v. Dart-isolates) voor "zwaar"/"duurtest"
      // zodra het losse workerprogramma meegeleverd is — zie de
      // toelichting bij _benchmarkWorkerBinary hierboven voor de "waarom".
      final useProcessWorkers = (intensity == BenchmarkIntensity.zwaar ||
              intensity == BenchmarkIntensity.duurtest) &&
          _benchmarkWorkerBinary != null;
      final receivePort = useProcessWorkers ? null : ReceivePort();
      final isolates = <Isolate>[];
      final processes = <Process>[];
      final processSubs = <StreamSubscription<String>>[];
      final stopwatch = Stopwatch()..start();
      var totalOps = 0;
      var peakTemp = 0.0;
      var consecutiveSafetyTimeouts = 0;
      var throttleDetected = false;
      String? abortReason;

      // Track rate in three phases of the run to spot sustained thermal
      // throttling: if the combined op-rate in the final phase drops
      // well below the opening phase while all workers are still fully
      // loaded, that's the CPU clocking down under heat, not just
      // scheduling noise.
      final phaseOps = <int>[0, 0, 0];

      AppLogger.instance.info(_logSource,
          'CPU-test gestart: $workerCount worker(s), ${duration.inSeconds}s, intensiteit ${intensity.label}');
      final powerAtStart = await _logPowerAtStart('CPU-test');

      try {
        if (useProcessWorkers) {
          final binaryPath = _benchmarkWorkerBinary!.path;
          for (var i = 0; i < workerCount; i++) {
            processes.add(await Process.start(binaryPath, ['cpu', '${duration.inMilliseconds}']));
          }
        } else {
          for (var i = 0; i < workerCount; i++) {
            isolates.add(await Isolate.spawn(
                _cpuWorkerEntry, _CpuWorkerConfig(receivePort!.sendPort, duration)));
          }
        }
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Kon CPU-testworkers niet starten: $e');
        await controller.close();
        resultCompleter.complete(BenchmarkResult(
          type: BenchmarkType.cpu,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: true,
          abortReason: 'kon workers niet starten',
        ));
        return;
      }

      // Separate from `stopwatch` (which starts before the spawn loop
      // above, so its elapsed time also covers isolate-startup latency —
      // that's the right base for the abort/duration checks below,
      // which should honor the wall-clock budget the test was asked to
      // run for). Scoring by totalOps/stopwatch.elapsed would silently
      // divide by a slightly longer time than the workers actually
      // spent doing work (each worker's own internal loop only starts
      // once it's alive, for exactly `duration`), understating the
      // score — worse the more workers there are, since they're spawned
      // one at a time. workStopwatch starts right as the last worker
      // comes alive, so the final score reflects real throughput.
      final workStopwatch = Stopwatch()..start();

      var doneWorkers = 0;
      void registerOps(int ops) {
        totalOps += ops;
        final phase =
            (stopwatch.elapsed.inMilliseconds / duration.inMilliseconds * 3).floor().clamp(0, 2);
        phaseOps[phase] += ops;
      }

      final StreamSubscription? opsSub;
      if (useProcessWorkers) {
        opsSub = null;
        for (final process in processes) {
          processSubs.add(process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
            if (line == 'DONE') {
              doneWorkers++;
            } else if (line.startsWith('P ')) {
              final ops = int.tryParse(line.substring(2));
              if (ops != null) registerOps(ops);
            }
          }));
          processSubs.add(process.stderr
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) => AppLogger.instance.error(_logSource, 'CPU-workerproces: $line')));
        }
      } else {
        opsSub = receivePort!.listen((message) {
          if (message == 'done') {
            doneWorkers++;
            return;
          }
          if (message is int) registerOps(message);
        });
      }

      double? lastKnownLoad;
      double? lastKnownTemp;

      // Registers this test as a consumer of the shared CPU-temp feed
      // (see BenchmarkCpuTempFeed's doc) — released in the `finally`
      // block below alongside safetyTimer.cancel(). Acquiring here,
      // right before the safety timer starts reading it, means the
      // very first tick already has a fresh-ish reading rather than
      // whatever was left over from a previous test.
      _cpuTempFeed.acquire();
      _activeCpuHeavyTests++;

      final safetyTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        // TIJDELIJKE DIAGNOSE (weer verwijderen zodra we weten wat het is):
        // bewijst rechtstreeks of de hoofdisolate deze tick nog elke 2s
        // haalt tijdens "reageert niet".
        print('[DIAGNOSE] ${DateTime.now().toIso8601String()} CPU-test hoofdisolate-tick, nog actief');
        if (cancelled) return;
        // Reads the shared feed's cached last reading rather than
        // calling sensors.readCpu() itself — see BenchmarkCpuTempFeed's
        // doc for why: when memory-test and/or crypto-test are running
        // at the same time (as "Alles tegelijk" does), each having its
        // own independent poller here used to mean several concurrent
        // sensor calls competing for the same underlying Windows sensor
        // pathway, occasionally starving each other into a false-
        // positive "sensor too slow" abort even though the CPU itself
        // was never actually in danger. One shared poll, fed to
        // whichever tests are currently watching, doesn't have that
        // problem.
        //
        // A *stale* reading is handled separately from an outright
        // failure: maxing out every core (the whole point of this test)
        // can itself starve the shared feed's own background sensor
        // read of CPU scheduling time, so one stale tick under that
        // load is expected, not a sign of an actual problem — only
        // several in a row (a real, persistent failure) triggers a
        // safety-abort.
        //
        // Crucially, the progress update itself happens unconditionally
        // below, outside this block — fractionComplete only needs the
        // elapsed wall-clock time, not a fresh sensor read, so a stale
        // tick no longer means the progress bar visibly stops moving.
        if (!_cpuTempFeed.isStale) {
          consecutiveSafetyTimeouts = 0;
          final cpu = _cpuTempFeed.latest!;
          lastKnownLoad = cpu.overallLoadPercent;
          if (cpu.temperatureC != null) {
            lastKnownTemp = cpu.temperatureC;
            if (cpu.temperatureC! > peakTemp) peakTemp = cpu.temperatureC!;
            final safetyCutoffC = SettingsService.instance.current.cpuSafetyCutoffC;
            if (cpu.temperatureC! > safetyCutoffC) {
              abortReason = 'CPU-temperatuur te hoog (${cpu.temperatureC!.toStringAsFixed(0)}°C, '
                  'grens ${safetyCutoffC.toStringAsFixed(0)}°C)';
              cancelled = true;
            }
          }
        } else {
          consecutiveSafetyTimeouts++;
          AppLogger.instance.debug(
            _logSource,
            'Temperatuurcontrole is verouderd tijdens CPU-test (poging $consecutiveSafetyTimeouts/3) — '
            'waarschijnlijk doordat de volle CPU-belasting zelf de achtergrond-sensorlezing vertraagt.',
          );
          if (consecutiveSafetyTimeouts >= 3) {
            AppLogger.instance.error(
                _logSource, 'Temperatuurbewaking blijft te traag (3x op rij) tijdens CPU-test, test wordt uit voorzorg gestopt.');
            abortReason = 'temperatuurbewaking bleef te traag reageren';
            cancelled = true;
          }
        }

        final fraction = (stopwatch.elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        if (!controller.isClosed) {
          controller.add(BenchmarkProgress(
            fractionComplete: fraction,
            statusText: '${(fraction * 100).toStringAsFixed(0)}% · $workerCount cores actief',
            currentLoadPercent: lastKnownLoad,
            currentTemperatureC: lastKnownTemp,
          ));
        }
      });

      try {
        // Wait until either all workers report done, the duration
        // safety margin elapses, or the run is cancelled (thermal,
        // monitoring failure, or user abort).
        while (doneWorkers < workerCount &&
            stopwatch.elapsed < duration + const Duration(seconds: 5) &&
            !cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }

        // Throttle heuristic: final phase noticeably slower than
        // opening phase, on a run long enough for this to be
        // meaningful.
        if (phaseOps[0] > 0 && duration.inSeconds >= 20) {
          final dropRatio = phaseOps[2] / phaseOps[0];
          if (dropRatio < 0.85) throttleDetected = true;
        }

        final effectiveSeconds = workStopwatch.elapsed.inMilliseconds / 1000;
        final score = effectiveSeconds > 0 ? (totalOps / effectiveSeconds) / 1e6 : null;

        AppLogger.instance.info(
          _logSource,
          'CPU-test klaar: ${cancelled ? 'gestopt (${abortReason ?? 'onbekend'})' : 'voltooid'}, '
          'score ${score?.toStringAsFixed(2) ?? 'n/a'} Mops/s, piektemp ${peakTemp.toStringAsFixed(0)}°C',
        );

        final result = BenchmarkResult(
          type: BenchmarkType.cpu,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: cancelled,
          abortReason: abortReason,
          score: score,
          peakTemperatureC: peakTemp > 0 ? peakTemp : null,
          throttleDetected: throttleDetected,
          details: {'workers': '$workerCount', ...await _powerDetails(powerAtStart)},
        );
        recordResult(result);
        if (!resultCompleter.isCompleted) resultCompleter.complete(result);
      } catch (e) {
        // Belt-and-braces: any unexpected failure in the wait/scoring
        // logic above still needs to produce a result and release the
        // isolates below, rather than leaving BenchmarkRun.result
        // pending forever.
        AppLogger.instance.error(_logSource, 'CPU-test onverwacht mislukt: $e');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.cpu,
            intensity: intensity,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? '$e',
          ));
        }
      } finally {
        // Cleanup always runs, whether the run finished normally,
        // aborted, or hit an unexpected error above.
        safetyTimer.cancel();
        _cpuTempFeed.release();
        _activeCpuHeavyTests--;
        await opsSub?.cancel();
        for (final sub in processSubs) {
          await sub.cancel();
        }
        receivePort?.close();
        for (final isolate in isolates) {
          isolate.kill(priority: Isolate.immediate);
        }
        for (final process in processes) {
          process.kill();
        }
        if (!controller.isClosed) await controller.close();
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }

  // ---------------------------------------------------------------------
  // Disk test — real work: writes and reads a temp file in chunks,
  // measuring genuine throughput. Cleans up the file afterward
  // regardless of how the run ends.
  // ---------------------------------------------------------------------

  int _diskTotalBytesFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 128 * 1024 * 1024;
      case BenchmarkIntensity.gemiddeld:
        return 512 * 1024 * 1024;
      case BenchmarkIntensity.zwaar:
        return 1024 * 1024 * 1024;
      case BenchmarkIntensity.duurtest:
        return 2048 * 1024 * 1024;
    }
  }

  static const _diskChunkBytes = 16 * 1024 * 1024;

  /// Fixed 64 MiB region for the random-4K phase, independent of the
  /// sequential phase's intensity-scaled size — the random-IOPS number
  /// should be comparable across intensities (same file size, just more
  /// operations at higher intensity), not confounded by also changing
  /// how much of the disk's cache/FTL mapping table gets exercised.
  static const _diskRandom4kFileBytes = 64 * 1024 * 1024;
  static const _diskRandom4kBlockBytes = 4096;

  int _diskRandom4kOpsFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 300;
      case BenchmarkIntensity.gemiddeld:
        return 800;
      case BenchmarkIntensity.zwaar:
        return 2000;
      case BenchmarkIntensity.duurtest:
        return 8000;
    }
  }

  /// [targetMountPoint], if given, tests that specific mounted
  /// filesystem (e.g. a USB drive) instead of wherever the OS's default
  /// temp directory lives — the same safety check (refuse if it would
  /// eat most of the remaining free space) still applies to whichever
  /// disk ends up being used.
  BenchmarkRun startDiskTest(BenchmarkIntensity intensity, {String? targetMountPoint}) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;

    Future<void> run() async {
      final totalBytes = _diskTotalBytesFor(intensity);
      final stopwatch = Stopwatch()..start();
      String? abortReason;
      File? tempFile;
      File? random4kFile;

      AppLogger.instance.info(_logSource,
          'Disk-test gestart: ${(totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB, intensiteit ${intensity.label}'
          '${targetMountPoint != null ? ', doel $targetMountPoint' : ''}');
      final powerAtStart = await _logPowerAtStart('Disk-test');

      try {
        // Safety check: refuse to run if it would eat most of the
        // remaining free space on that disk.
        final disks = await sensors.readDisks();
        final tempDir = targetMountPoint != null ? Directory(targetMountPoint) : await getTemporaryDirectory();
        if (targetMountPoint != null && !await tempDir.exists()) {
          abortReason = 'gekozen locatie bestaat niet (meer): $targetMountPoint';
          throw StateError(abortReason);
        }
        int? relevantAvailable;
        var bestMatchLen = -1;
        for (final d in disks) {
          if (tempDir.path.startsWith(d.mountPoint) && d.mountPoint.length > bestMatchLen) {
            bestMatchLen = d.mountPoint.length;
            relevantAvailable = d.availableBytes;
          }
        }
        if (relevantAvailable != null && relevantAvailable < totalBytes * 2) {
          abortReason = 'onvoldoende vrije schijfruimte voor een veilige test';
          throw StateError(abortReason);
        }

        tempFile = File(
            '${tempDir.path}/darktask_disk_bench_${DateTime.now().millisecondsSinceEpoch}.tmp');
        final random = Random();
        // Uint8List + a plain fill loop — same approach already used
        // below for fillChunk/block4k/readBuf4k — instead of
        // List<int>.generate(...), which boxes every one of the 16
        // million elements individually and is dramatically slower for
        // a buffer this size.
        final chunk = Uint8List(_diskChunkBytes);
        for (var i = 0; i < chunk.length; i++) {
          chunk[i] = random.nextInt(256);
        }

        // --- Sequential write phase (0% – 40% of progress) ---
        final writeStart = stopwatch.elapsedMilliseconds;
        // RandomAccessFile + awaited writeFrom() per chunk, not
        // IOSink.add() — mirrors every other I/O loop in this file
        // (the sequential read phase right below, both random-4K
        // phases, the network test's send loop). IOSink.add() is
        // fire-and-forget with no backpressure, and this loop had no
        // `await` anywhere in its body, so — same bug-class as the
        // OpenCL dispatch loop's doc comment further down describes —
        // Dart never got a chance to process a single completed write,
        // or the Cancel button, or a repaint, until the *entire* while
        // loop had already run: every chunk got queued in one
        // synchronous burst (progress jumping straight to 40%), and
        // then sink.flush() had to work through that whole backlog
        // with nothing left to yield to in between. Scaled directly
        // with totalBytes, so it was unnoticeable at licht's 128 MB and
        // looked like the app had hung at gemiddeld/zwaar/duurtest's
        // much larger sizes. Awaiting each writeFrom() gives a real
        // yield point every chunk, so progress now reflects actual
        // completed writes and Cancel keeps working throughout.
        final writeRaf = await tempFile.open(mode: FileMode.write);
        var written = 0;
        var writeOps = 0;
        while (written < totalBytes && !cancelled) {
          await writeRaf.writeFrom(chunk);
          written += chunk.length;
          writeOps++;
          final fraction = (written / totalBytes) * 0.4;
          if (!controller.isClosed) {
            controller.add(BenchmarkProgress(
              fractionComplete: fraction,
              statusText:
                  'Sequentieel schrijven... ${(written / (1024 * 1024)).toStringAsFixed(0)} / ${(totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB',
            ));
          }
        }
        await writeRaf.flush();
        await writeRaf.close();
        final writeMs = stopwatch.elapsedMilliseconds - writeStart;
        final writeMBps = writeMs > 0 ? (written / (1024 * 1024)) / (writeMs / 1000) : 0.0;
        // IOPS here reflects our fixed 16 MiB chunk size, not typical
        // 4 KiB-block IOPS as reported by dedicated tools like fio —
        // it's a real, directly-measured number, just at a different
        // (larger) block size than most IOPS benchmarks use. Labelled
        // accordingly in the UI so it isn't mistaken for the 4K figure
        // measured separately below.
        final writeIops = writeMs > 0 ? writeOps / (writeMs / 1000) : 0.0;

        if (cancelled) {
          abortReason ??= 'geannuleerd door gebruiker';
          throw StateError(abortReason);
        }

        // --- Sequential read phase (40% – 70%) ---
        final readStart = stopwatch.elapsedMilliseconds;
        var readBytes = 0;
        var readOps = 0;
        final raf = await tempFile.open();
        final buffer = Uint8List(_diskChunkBytes);
        while (readBytes < written && !cancelled) {
          final read = await raf.readInto(buffer);
          if (read <= 0) break;
          readBytes += read;
          readOps++;
          final fraction = 0.4 + (readBytes / written) * 0.3;
          if (!controller.isClosed) {
            controller.add(BenchmarkProgress(
              fractionComplete: fraction,
              statusText:
                  'Sequentieel lezen... ${(readBytes / (1024 * 1024)).toStringAsFixed(0)} / ${(written / (1024 * 1024)).toStringAsFixed(0)} MB',
            ));
          }
        }
        await raf.close();
        final readMs = stopwatch.elapsedMilliseconds - readStart;
        final readMBps = readMs > 0 ? (readBytes / (1024 * 1024)) / (readMs / 1000) : 0.0;
        final readIops = readMs > 0 ? readOps / (readMs / 1000) : 0.0;

        if (cancelled) {
          abortReason ??= 'geannuleerd door gebruiker';
          throw StateError(abortReason);
        }

        // --- Random 4K IOPS phase (70% – 100%) ---
        // Uses a separate, fixed-size 64 MiB region rather than the
        // sequential-phase file, so the random-IOPS figure is
        // comparable across intensities and isn't confounded by the
        // sequential test's intensity-scaled file size. QD1 (one
        // outstanding operation at a time) — the same convention as
        // CrystalDiskMark's "4K Q1T1" figure, arguably the single most
        // widely recognized disk benchmark number for consumer SSDs.
        random4kFile = File(
            '${tempDir.path}/darktask_disk_bench_4k_${DateTime.now().millisecondsSinceEpoch}.tmp');
        final random4kOps = _diskRandom4kOpsFor(intensity);
        final blockCount = _diskRandom4kFileBytes ~/ _diskRandom4kBlockBytes;
        final raf4k = await random4kFile.open(mode: FileMode.write);

        // Untimed pre-fill: establishes real on-disk blocks to
        // overwrite/read back. Doesn't count toward the timed score —
        // without this, the "random write" phase would just be
        // measuring writes into sparse/unallocated space, which some
        // filesystems handle very differently (and faster) than
        // genuine block overwrites.
        final fillChunk = Uint8List(1024 * 1024);
        for (var i = 0; i < fillChunk.length; i++) {
          fillChunk[i] = random.nextInt(256);
        }
        var filled = 0;
        while (filled < _diskRandom4kFileBytes) {
          await raf4k.writeFrom(fillChunk);
          filled += fillChunk.length;
        }

        final block4k = Uint8List(_diskRandom4kBlockBytes);
        for (var i = 0; i < block4k.length; i++) {
          block4k[i] = random.nextInt(256);
        }
        final readBuf4k = Uint8List(_diskRandom4kBlockBytes);

        // Random write 4K (70% – 85%)
        final rwStart = stopwatch.elapsedMilliseconds;
        var rwCompleted = 0;
        for (var i = 0; i < random4kOps && !cancelled; i++) {
          final offset = random.nextInt(blockCount) * _diskRandom4kBlockBytes;
          await raf4k.setPosition(offset);
          await raf4k.writeFrom(block4k);
          rwCompleted++;
          if (i % 25 == 0 && !controller.isClosed) {
            controller.add(BenchmarkProgress(
              fractionComplete: 0.7 + (i / random4kOps) * 0.15,
              statusText: 'Random schrijven (4K)... $i / $random4kOps',
            ));
          }
        }
        await raf4k.flush();
        final rwMs = stopwatch.elapsedMilliseconds - rwStart;
        final random4kWriteIops = rwMs > 0 ? (rwCompleted / (rwMs / 1000)) : 0.0;
        final random4kWriteMBps =
            rwMs > 0 ? (rwCompleted * _diskRandom4kBlockBytes / (1024 * 1024)) / (rwMs / 1000) : 0.0;

        if (cancelled) {
          abortReason ??= 'geannuleerd door gebruiker';
          throw StateError(abortReason);
        }

        // Random read 4K (85% – 100%)
        final rrStart = stopwatch.elapsedMilliseconds;
        var rrCompleted = 0;
        for (var i = 0; i < random4kOps && !cancelled; i++) {
          final offset = random.nextInt(blockCount) * _diskRandom4kBlockBytes;
          await raf4k.setPosition(offset);
          await raf4k.readInto(readBuf4k);
          rrCompleted++;
          if (i % 25 == 0 && !controller.isClosed) {
            controller.add(BenchmarkProgress(
              fractionComplete: 0.85 + (i / random4kOps) * 0.15,
              statusText: 'Random lezen (4K)... $i / $random4kOps',
            ));
          }
        }
        await raf4k.close();
        final rrMs = stopwatch.elapsedMilliseconds - rrStart;
        final random4kReadIops = rrMs > 0 ? (rrCompleted / (rrMs / 1000)) : 0.0;
        final random4kReadMBps =
            rrMs > 0 ? (rrCompleted * _diskRandom4kBlockBytes / (1024 * 1024)) / (rrMs / 1000) : 0.0;

        if (cancelled) {
          abortReason ??= 'geannuleerd door gebruiker';
        }

        final avgMBps = (writeMBps + readMBps) / 2;

        AppLogger.instance.info(
          _logSource,
          'Disk-test klaar: sequentieel schrijven ${writeMBps.toStringAsFixed(1)} MB/s, '
          'sequentieel lezen ${readMBps.toStringAsFixed(1)} MB/s, '
          'random 4K schrijven ${random4kWriteIops.toStringAsFixed(0)} IOPS, '
          'random 4K lezen ${random4kReadIops.toStringAsFixed(0)} IOPS',
        );

        if (!controller.isClosed) await controller.close();
        final result = BenchmarkResult(
          type: BenchmarkType.disk,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: cancelled,
          abortReason: abortReason,
          score: cancelled ? null : avgMBps,
          details: {
            'schrijfsnelheid': '${writeMBps.toStringAsFixed(1)} MB/s',
            'leessnelheid': '${readMBps.toStringAsFixed(1)} MB/s',
            'schrijf-IOPS (16 MiB)': writeIops.toStringAsFixed(0),
            'lees-IOPS (16 MiB)': readIops.toStringAsFixed(0),
            'random schrijfsnelheid (4K)': '${random4kWriteMBps.toStringAsFixed(1)} MB/s',
            'random leessnelheid (4K)': '${random4kReadMBps.toStringAsFixed(1)} MB/s',
            'random schrijf-IOPS (4K, QD1)': random4kWriteIops.toStringAsFixed(0),
            'random lees-IOPS (4K, QD1)': random4kReadIops.toStringAsFixed(0),
            ...await _powerDetails(powerAtStart),
          },
        );
        recordResult(result);
        resultCompleter.complete(result);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Disk-test mislukt: $e');
        if (!controller.isClosed) await controller.close();
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.disk,
            intensity: intensity,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? '$e',
          ));
        }
      } finally {
        try {
          if (tempFile != null && await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          AppLogger.instance.debug(_logSource, 'Kon tijdelijk testbestand niet opruimen: $e');
        }
        try {
          if (random4kFile != null && await random4kFile.exists()) {
            await random4kFile.delete();
          }
        } catch (e) {
          AppLogger.instance.debug(_logSource, 'Kon tijdelijk 4K-testbestand niet opruimen: $e');
        }
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }

  // ---------------------------------------------------------------------
  // Memory bandwidth test — N isolates each repeatedly copy a large
  // (64 MiB) buffer into another buffer of the same size. 64 MiB is
  // deliberately far bigger than any consumer CPU's L2/L3 cache, so the
  // copy genuinely round-trips through RAM rather than mostly hitting
  // cache — otherwise this would measure cache bandwidth and call it
  // "memory bandwidth", which would be a misleading number wearing an
  // honest label. The reported figure is the literal bytes copied per
  // second — not doubled to account for "read+source, write+dest" the
  // way some tools do — so it's directly what was measured, not a
  // derived multiple of it.
  // ---------------------------------------------------------------------

  static const _memoryBufferBytes = 64 * 1024 * 1024; // 64 MiB per worker

  int _memoryWorkerCountFor(BenchmarkIntensity intensity) {
    final cores = Platform.numberOfProcessors;
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 1;
      case BenchmarkIntensity.gemiddeld:
        return min(2, cores);
      case BenchmarkIntensity.zwaar:
        return min(4, cores);
      case BenchmarkIntensity.duurtest:
        return min(4, cores);
    }
  }

  Duration _memoryDurationFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return const Duration(seconds: 12);
      case BenchmarkIntensity.gemiddeld:
        return const Duration(seconds: 20);
      case BenchmarkIntensity.zwaar:
        return const Duration(seconds: 30);
      case BenchmarkIntensity.duurtest:
        return const Duration(minutes: 10);
    }
  }

  BenchmarkRun startMemoryTest(BenchmarkIntensity intensity, {int? workerCountOverride}) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;

    Future<void> run() async {
      final workerCount = workerCountOverride ?? _memoryWorkerCountFor(intensity);
      final duration = _memoryDurationFor(intensity);
      final receivePort = ReceivePort();
      final isolates = <Isolate>[];
      final stopwatch = Stopwatch()..start();
      var totalBytes = 0;
      var peakTemp = 0.0;
      var consecutiveSafetyTimeouts = 0;
      String? abortReason;

      AppLogger.instance.info(_logSource,
          'Memory-test gestart: $workerCount worker(s) × ${_memoryBufferBytes ~/ (1024 * 1024)} MiB, '
          '${duration.inSeconds}s, intensiteit ${intensity.label}');
      final powerAtStart = await _logPowerAtStart('Memory-test');

      try {
        for (var i = 0; i < workerCount; i++) {
          isolates.add(await Isolate.spawn(
              _memoryWorkerEntry, _MemoryWorkerConfig(receivePort.sendPort, duration, _memoryBufferBytes)));
        }
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Kon memory-testworkers niet starten: $e');
        await controller.close();
        resultCompleter.complete(BenchmarkResult(
          type: BenchmarkType.memory,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: true,
          abortReason: 'kon workers niet starten',
        ));
        return;
      }

      // See the CPU test's identical workStopwatch for why: `stopwatch`
      // starts before the (sequential) isolate-spawn loop above, so
      // scoring against its elapsed time would understate real
      // throughput by however long spawning took.
      final workStopwatch = Stopwatch()..start();

      var doneWorkers = 0;
      final opsSub = receivePort.listen((message) {
        if (message == 'done') {
          doneWorkers++;
          return;
        }
        if (message is int) totalBytes += message;
      });

      // Same thermal-safety approach as the CPU test: the copy loop
      // keeps `workerCount` cores busy (memory-bound, but still real
      // CPU work), so it's monitored the same way rather than assuming
      // "it's just memory" means it can't heat the chip up.
      double? lastKnownTemp;

      // See the CPU test's identical acquire()/release() pair for why:
      // shares one CPU-temp poll with whichever other tests are
      // running concurrently instead of starting a competing one.
      _cpuTempFeed.acquire();
      _activeCpuHeavyTests++;

      final safetyTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (cancelled) return;
        // See the CPU test's safetyTimer for why this reads the shared
        // feed's cache instead of calling sensors.readCpu() itself, and
        // why the progress update below is unconditional (elapsed-time
        // -based, not gated on a fresh sensor read).
        if (!_cpuTempFeed.isStale) {
          consecutiveSafetyTimeouts = 0;
          final cpu = _cpuTempFeed.latest!;
          if (cpu.temperatureC != null) {
            lastKnownTemp = cpu.temperatureC;
            if (cpu.temperatureC! > peakTemp) peakTemp = cpu.temperatureC!;
            final safetyCutoffC = SettingsService.instance.current.cpuSafetyCutoffC;
            if (cpu.temperatureC! > safetyCutoffC) {
              abortReason = 'CPU-temperatuur te hoog (${cpu.temperatureC!.toStringAsFixed(0)}°C, '
                  'grens ${safetyCutoffC.toStringAsFixed(0)}°C)';
              cancelled = true;
            }
          }
        } else {
          consecutiveSafetyTimeouts++;
          AppLogger.instance.debug(
            _logSource,
            'Temperatuurcontrole is verouderd tijdens memory-test (poging $consecutiveSafetyTimeouts/3) — '
            'waarschijnlijk doordat de volle CPU-belasting zelf de achtergrond-sensorlezing vertraagt.',
          );
          if (consecutiveSafetyTimeouts >= 3) {
            AppLogger.instance.error(_logSource,
                'Temperatuurbewaking blijft te traag (3x op rij) tijdens memory-test, test wordt uit voorzorg gestopt.');
            abortReason = 'temperatuurbewaking bleef te traag reageren';
            cancelled = true;
          }
        }

        final fraction = (stopwatch.elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        final gbps = stopwatch.elapsed.inMilliseconds > 0
            ? (totalBytes / 1e9) / (stopwatch.elapsed.inMilliseconds / 1000)
            : 0.0;
        if (!controller.isClosed) {
          controller.add(BenchmarkProgress(
            fractionComplete: fraction,
            statusText: '${(fraction * 100).toStringAsFixed(0)}% · ${gbps.toStringAsFixed(1)} GB/s',
            currentTemperatureC: lastKnownTemp,
          ));
        }
      });

      try {
        while (doneWorkers < workerCount &&
            stopwatch.elapsed < duration + const Duration(seconds: 5) &&
            !cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }

        final effectiveSeconds = workStopwatch.elapsed.inMilliseconds / 1000;
        final gbps = effectiveSeconds > 0 ? (totalBytes / 1e9) / effectiveSeconds : null;

        AppLogger.instance.info(
          _logSource,
          'Memory-test klaar: ${cancelled ? 'gestopt (${abortReason ?? 'onbekend'})' : 'voltooid'}, '
          '${gbps?.toStringAsFixed(1) ?? 'n/a'} GB/s, piektemp ${peakTemp.toStringAsFixed(0)}°C',
        );

        final result = BenchmarkResult(
          type: BenchmarkType.memory,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: cancelled,
          abortReason: abortReason,
          score: gbps,
          peakTemperatureC: peakTemp > 0 ? peakTemp : null,
          details: {
            'workers': '$workerCount',
            'buffergrootte per worker': '${_memoryBufferBytes ~/ (1024 * 1024)} MiB',
            ...await _powerDetails(powerAtStart),
          },
        );
        recordResult(result);
        if (!resultCompleter.isCompleted) resultCompleter.complete(result);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Memory-test onverwacht mislukt: $e');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.memory,
            intensity: intensity,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? '$e',
          ));
        }
      } finally {
        safetyTimer.cancel();
        _cpuTempFeed.release();
        _activeCpuHeavyTests--;
        await opsSub.cancel();
        receivePort.close();
        for (final isolate in isolates) {
          isolate.kill(priority: Isolate.immediate);
        }
        if (!controller.isClosed) await controller.close();
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }

  // ---------------------------------------------------------------------
  // Network test — loopback TCP throughput: a server socket and client
  // socket both on 127.0.0.1, transferring real bytes over a real
  // (local) TCP connection. This measures the machine's TCP/loopback
  // stack throughput, NOT real LAN or internet speed — there's no
  // second device to test against, so honesty here means measuring
  // exactly what we can measure and labeling it "loopback" everywhere
  // it's shown, not letting it be mistaken for "network speed" in
  // general.
  // ---------------------------------------------------------------------

  int _networkTotalBytesFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 256 * 1024 * 1024;
      case BenchmarkIntensity.gemiddeld:
        return 1024 * 1024 * 1024;
      case BenchmarkIntensity.zwaar:
        return 2048 * 1024 * 1024;
      case BenchmarkIntensity.duurtest:
        return 6144 * 1024 * 1024;
    }
  }

  static const _networkChunkBytes = 1 * 1024 * 1024; // 1 MiB per send() call

  BenchmarkRun startNetworkTest(BenchmarkIntensity intensity) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;

    Future<void> run() async {
      final totalBytes = _networkTotalBytesFor(intensity);
      final stopwatch = Stopwatch()..start();
      String? abortReason;
      ServerSocket? server;
      Socket? serverSideSocket;
      Socket? clientSocket;

      AppLogger.instance.info(_logSource,
          'Network-test (loopback) gestart: ${(totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB, intensiteit ${intensity.label}');
      final powerAtStart = await _logPowerAtStart('Network-test');

      try {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final acceptFuture = server.first;
        clientSocket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
        serverSideSocket = await acceptFuture;

        // Server side just drains and discards everything it receives —
        // as fast as it can, which is the point: we want to measure how
        // fast bytes can move from the client's send buffer, through
        // the kernel's loopback path, to the server's receive side.
        var received = 0;
        final serverDone = Completer<void>();
        final receivedSub = serverSideSocket.listen(
          (data) => received += data.length,
          onDone: () => serverDone.complete(),
          onError: (Object e) {
            if (!serverDone.isCompleted) serverDone.completeError(e);
          },
        );

        final chunk = Uint8List(_networkChunkBytes);
        final random = Random();
        for (var i = 0; i < chunk.length; i += 4096) {
          chunk[i] = random.nextInt(256);
        }

        var sent = 0;
        while (sent < totalBytes && !cancelled) {
          clientSocket.add(chunk);
          await clientSocket.flush();
          sent += chunk.length;
          final fraction = (sent / totalBytes).clamp(0.0, 1.0);
          if (!controller.isClosed) {
            final elapsedSec = stopwatch.elapsed.inMilliseconds / 1000;
            final mbps = elapsedSec > 0 ? (sent / (1024 * 1024)) / elapsedSec : 0.0;
            controller.add(BenchmarkProgress(
              fractionComplete: fraction,
              statusText:
                  '${(sent / (1024 * 1024)).toStringAsFixed(0)} / ${(totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB · ${mbps.toStringAsFixed(0)} MB/s',
            ));
          }
        }

        await clientSocket.close();
        await serverDone.future.timeout(const Duration(seconds: 5), onTimeout: () {});
        await receivedSub.cancel();

        if (cancelled) abortReason ??= 'geannuleerd door gebruiker';

        final elapsedSec = stopwatch.elapsed.inMilliseconds / 1000;
        final mbps = elapsedSec > 0 ? (received / (1024 * 1024)) / elapsedSec : 0.0;

        AppLogger.instance.info(_logSource,
            'Network-test klaar: ${(received / (1024 * 1024)).toStringAsFixed(0)} MB ontvangen, ${mbps.toStringAsFixed(0)} MB/s (loopback)');

        final result = BenchmarkResult(
          type: BenchmarkType.network,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: cancelled,
          abortReason: abortReason,
          score: cancelled ? null : mbps,
          details: {
            'ontvangen': '${(received / (1024 * 1024)).toStringAsFixed(0)} MB',
            'pad': 'loopback (127.0.0.1), niet LAN/internet',
            ...await _powerDetails(powerAtStart),
          },
        );
        recordResult(result);
        if (!resultCompleter.isCompleted) resultCompleter.complete(result);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Network-test mislukt: $e');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.network,
            intensity: intensity,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? '$e',
          ));
        }
      } finally {
        if (!controller.isClosed) await controller.close();
        try {
          await clientSocket?.close();
        } catch (_) {}
        try {
          await serverSideSocket?.close();
        } catch (_) {}
        try {
          await server?.close();
        } catch (_) {}
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }

  // ---------------------------------------------------------------------
  // Crypto test — real work: N isolates each repeatedly hash a data
  // chunk with SHA-256 (package:crypto — a genuine, widely-used
  // implementation, not a hand-rolled algorithm). Reports combined
  // MB/s hashed. Useful as a proxy for workloads like backup
  // verification, TLS, or disk encryption throughput, none of which
  // this app measures directly, but which all bottleneck on the same
  // hashing/crypto primitives.
  // ---------------------------------------------------------------------

  int _cryptoWorkerCountFor(BenchmarkIntensity intensity) {
    final cores = Platform.numberOfProcessors;
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 1;
      case BenchmarkIntensity.gemiddeld:
        return max(1, (cores / 2).round());
      case BenchmarkIntensity.zwaar:
      case BenchmarkIntensity.duurtest:
        // Vol aantal cores zodra het losse workerproces beschikbaar is
        // (zie _benchmarkWorkerBinary hierboven) — dan geldt de Dart
        // VM-isolate-limiet niet meer, want elk workerproces draait in
        // zijn eigen VM-instantie. Zonder dat losse programma (bijv.
        // tijdens "flutter run" in ontwikkeling) blijft de oude,
        // empirisch bevestigd veilige isolate-cap van 3 workers gelden,
        // zodat de app nooit kan vastlopen — wel met een lagere score.
        return _benchmarkWorkerBinary != null ? cores : min(3, cores);
    }
  }

  Duration _cryptoDurationFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return const Duration(seconds: 12);
      case BenchmarkIntensity.gemiddeld:
        return const Duration(seconds: 20);
      case BenchmarkIntensity.zwaar:
        return const Duration(seconds: 30);
      case BenchmarkIntensity.duurtest:
        return const Duration(minutes: 10);
    }
  }

  BenchmarkRun startCryptoTest(BenchmarkIntensity intensity, {int? workerCountOverride}) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;

    Future<void> run() async {
      final workerCount = workerCountOverride ?? _cryptoWorkerCountFor(intensity);
      final duration = _cryptoDurationFor(intensity);
      // Zie de toelichting bij de CPU-test hierboven: zelfde losse-
      // OS-proces-aanpak voor "zwaar"/"duurtest".
      final useProcessWorkers = (intensity == BenchmarkIntensity.zwaar ||
              intensity == BenchmarkIntensity.duurtest) &&
          _benchmarkWorkerBinary != null;
      final receivePort = useProcessWorkers ? null : ReceivePort();
      final isolates = <Isolate>[];
      final processes = <Process>[];
      final processSubs = <StreamSubscription<String>>[];
      final stopwatch = Stopwatch()..start();
      var totalBytes = 0;
      var peakTemp = 0.0;
      var consecutiveSafetyTimeouts = 0;
      String? abortReason;

      AppLogger.instance.info(_logSource,
          'Crypto-test (SHA-256) gestart: $workerCount worker(s), ${duration.inSeconds}s, intensiteit ${intensity.label}');
      final powerAtStart = await _logPowerAtStart('Crypto-test');

      try {
        if (useProcessWorkers) {
          final binaryPath = _benchmarkWorkerBinary!.path;
          for (var i = 0; i < workerCount; i++) {
            processes.add(await Process.start(binaryPath, ['crypto', '${duration.inMilliseconds}']));
          }
        } else {
          for (var i = 0; i < workerCount; i++) {
            isolates.add(await Isolate.spawn(
                _cryptoWorkerEntry, _CryptoWorkerConfig(receivePort!.sendPort, duration)));
          }
        }
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Kon crypto-testworkers niet starten: $e');
        await controller.close();
        resultCompleter.complete(BenchmarkResult(
          type: BenchmarkType.crypto,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: true,
          abortReason: 'kon workers niet starten',
        ));
        return;
      }

      // See the CPU test's identical workStopwatch for why: `stopwatch`
      // starts before the (sequential) isolate-spawn loop above, so
      // scoring against its elapsed time would understate real
      // throughput by however long spawning took.
      final workStopwatch = Stopwatch()..start();

      var doneWorkers = 0;
      void registerBytes(int bytes) {
        totalBytes += bytes;
      }

      final StreamSubscription? opsSub;
      if (useProcessWorkers) {
        opsSub = null;
        for (final process in processes) {
          processSubs.add(process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
            if (line == 'DONE') {
              doneWorkers++;
            } else if (line.startsWith('P ')) {
              final bytes = int.tryParse(line.substring(2));
              if (bytes != null) registerBytes(bytes);
            }
          }));
          processSubs.add(process.stderr
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) => AppLogger.instance.error(_logSource, 'Crypto-workerproces: $line')));
        }
      } else {
        opsSub = receivePort!.listen((message) {
          if (message == 'done') {
            doneWorkers++;
            return;
          }
          if (message is int) registerBytes(message);
        });
      }

      double? lastKnownTemp;

      // See the CPU test's identical acquire()/release() pair for why:
      // shares one CPU-temp poll with whichever other tests are
      // running concurrently instead of starting a competing one.
      _cpuTempFeed.acquire();
      _activeCpuHeavyTests++;

      final safetyTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (cancelled) return;
        // See the CPU test's safetyTimer for why this reads the shared
        // feed's cache instead of calling sensors.readCpu() itself, and
        // why the progress update below is unconditional (elapsed-time
        // -based, not gated on a fresh sensor read).
        if (!_cpuTempFeed.isStale) {
          consecutiveSafetyTimeouts = 0;
          final cpu = _cpuTempFeed.latest!;
          if (cpu.temperatureC != null) {
            lastKnownTemp = cpu.temperatureC;
            if (cpu.temperatureC! > peakTemp) peakTemp = cpu.temperatureC!;
            final safetyCutoffC = SettingsService.instance.current.cpuSafetyCutoffC;
            if (cpu.temperatureC! > safetyCutoffC) {
              abortReason = 'CPU-temperatuur te hoog (${cpu.temperatureC!.toStringAsFixed(0)}°C, '
                  'grens ${safetyCutoffC.toStringAsFixed(0)}°C)';
              cancelled = true;
            }
          }
        } else {
          consecutiveSafetyTimeouts++;
          AppLogger.instance.debug(
            _logSource,
            'Temperatuurcontrole is verouderd tijdens crypto-test (poging $consecutiveSafetyTimeouts/3) — '
            'waarschijnlijk doordat de volle CPU-belasting zelf de achtergrond-sensorlezing vertraagt.',
          );
          if (consecutiveSafetyTimeouts >= 3) {
            AppLogger.instance.error(_logSource,
                'Temperatuurbewaking blijft te traag (3x op rij) tijdens crypto-test, test wordt uit voorzorg gestopt.');
            abortReason = 'temperatuurbewaking bleef te traag reageren';
            cancelled = true;
          }
        }

        final fraction = (stopwatch.elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        final mbps = stopwatch.elapsed.inMilliseconds > 0
            ? (totalBytes / (1024 * 1024)) / (stopwatch.elapsed.inMilliseconds / 1000)
            : 0.0;
        if (!controller.isClosed) {
          controller.add(BenchmarkProgress(
            fractionComplete: fraction,
            statusText: '${(fraction * 100).toStringAsFixed(0)}% · ${mbps.toStringAsFixed(0)} MB/s',
            currentTemperatureC: lastKnownTemp,
          ));
        }
      });

      try {
        while (doneWorkers < workerCount &&
            stopwatch.elapsed < duration + const Duration(seconds: 5) &&
            !cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }

        final effectiveSeconds = workStopwatch.elapsed.inMilliseconds / 1000;
        final mbps = effectiveSeconds > 0 ? (totalBytes / (1024 * 1024)) / effectiveSeconds : null;

        AppLogger.instance.info(
          _logSource,
          'Crypto-test klaar: ${cancelled ? 'gestopt (${abortReason ?? 'onbekend'})' : 'voltooid'}, '
          '${mbps?.toStringAsFixed(0) ?? 'n/a'} MB/s, piektemp ${peakTemp.toStringAsFixed(0)}°C',
        );

        final result = BenchmarkResult(
          type: BenchmarkType.crypto,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: cancelled,
          abortReason: abortReason,
          score: mbps,
          peakTemperatureC: peakTemp > 0 ? peakTemp : null,
          details: {'workers': '$workerCount', 'algoritme': 'SHA-256', ...await _powerDetails(powerAtStart)},
        );
        recordResult(result);
        if (!resultCompleter.isCompleted) resultCompleter.complete(result);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'Crypto-test onverwacht mislukt: $e');
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.crypto,
            intensity: intensity,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? '$e',
          ));
        }
      } finally {
        safetyTimer.cancel();
        _cpuTempFeed.release();
        _activeCpuHeavyTests--;
        await opsSub?.cancel();
        for (final sub in processSubs) {
          await sub.cancel();
        }
        receivePort?.close();
        for (final isolate in isolates) {
          isolate.kill(priority: Isolate.immediate);
        }
        for (final process in processes) {
          process.kill();
        }
        if (!controller.isClosed) await controller.close();
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }

  // ---------------------------------------------------------------------
  // Multi-core scaling insight — not a standalone test, but a derived
  // figure computed from CPU results already sitting in this session's
  // history: if both a single-core (licht) and a multi-core (zwaar) run
  // exist for this session, per-core throughput lets you see how well
  // this CPU scales across cores (a well-scaling CPU stays close to
  // 1.0× per-core; thermal/power limits or memory-bandwidth contention
  // show up as a ratio below 1.0×).
  // ---------------------------------------------------------------------

  /// Returns the per-core scaling ratio (multi-core per-core throughput
  /// ÷ single-core throughput) for this session, or null if either a
  /// licht or zwaar CPU run hasn't happened yet this session.
  double? cpuScalingRatio() {
    final singleCoreRuns = historyFor(BenchmarkType.cpu, BenchmarkIntensity.licht);
    final multiCoreRuns = historyFor(BenchmarkType.cpu, BenchmarkIntensity.zwaar);
    if (singleCoreRuns.isEmpty || multiCoreRuns.isEmpty) return null;

    final singleCoreScore = singleCoreRuns.last.score;
    final multiCoreScore = multiCoreRuns.last.score;
    if (singleCoreScore == null || multiCoreScore == null || singleCoreScore <= 0) return null;

    final workerCount = _cpuWorkerCountFor(BenchmarkIntensity.zwaar);
    if (workerCount <= 1) return null; // single-core machine — nothing to compare
    final perCoreMultiScore = multiCoreScore / workerCount;
    return perCoreMultiScore / singleCoreScore;
  }

  // ---------------------------------------------------------------------
  // GPU compute test — shells out to glmark2 (a real OpenGL benchmark
  // suite), unlike the built-in Flutter rendering-load approximation
  // used by startGpuTest-equivalent UI code. If glmark2 isn't
  // installed, this fails with a clear reason rather than silently
  // falling back to the render approximation and blurring the two
  // together — they measure genuinely different things and are labeled
  // differently everywhere in the UI ("modus": "compute" in details).
  // ---------------------------------------------------------------------

  final OpenClComputeReader _openCl = OpenClComputeReader();

  /// Windows equivalent of [isGlmark2Available] — see
  /// [OpenClComputeReader]'s class doc for why OpenCL specifically,
  /// not Direct3D, was chosen for a real (not approximated) GPU
  /// compute-kernel stress test on Windows.
  Future<bool> isOpenClAvailable() async => _openCl.isAvailable();

  /// Every GPU device OpenCL can see on this machine, for a device
  /// picker in the benchmarks UI — see [OpenClComputeReader.listGpuDevices]
  /// for why this (and not the "render" test mode) is where per-GPU
  /// selection on a multi-GPU system actually belongs.
  Future<List<OpenClGpuDevice>> listOpenClGpuDevices() async => _openCl.listGpuDevices();

  Duration _openClDurationFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return const Duration(seconds: 15);
      case BenchmarkIntensity.gemiddeld:
        return const Duration(seconds: 30);
      case BenchmarkIntensity.zwaar:
        return const Duration(seconds: 45);
      case BenchmarkIntensity.duurtest:
        return const Duration(minutes: 10);
    }
  }

  /// Transcendental-math iterations per work item, per dispatch — the
  /// load knob for this test, deliberately kept as "more math per
  /// dispatch" rather than "bigger work-item count," so each
  /// individual dispatch's GPU time stays predictable and bounded
  /// regardless of intensity (see OpenClComputeReader's class doc on
  /// why that matters for Windows' TDR budget).
  int _openClIterationsFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 1000;
      case BenchmarkIntensity.gemiddeld:
        return 3000;
      case BenchmarkIntensity.zwaar:
        return 6000;
      case BenchmarkIntensity.duurtest:
        return 3000; // moderate and sustained, not maximal, for a 10-minute run
    }
  }

  /// Picks, out of a [SystemSensorService.readGpus] reading, the sample
  /// that corresponds to the physical GPU an OpenCL compute test is
  /// actually running on — matched by substring against [deviceLabel]
  /// (OpenCL's own device name, from [OpenClComputeReader.listGpuDevices])
  /// the same tolerant way this app already matches GPU names across
  /// its other data sources (WMI vs. LibreHardwareMonitor vs. DXGI all
  /// report slightly different strings for the same card). Falls back
  /// to the first sample when no label was given or nothing matches,
  /// which is also the old (pre-picker) behavior for a single-GPU
  /// system or the Linux/glmark2 path that never has a device label.
  GpuSample? _matchTestedGpuSample(List<GpuSample> gpus, String? deviceLabel) {
    if (gpus.isEmpty) return null;
    if (deviceLabel == null || deviceLabel.isEmpty) return gpus.first;
    final lowerLabel = deviceLabel.toLowerCase();
    for (final gpu in gpus) {
      final lowerName = gpu.name.toLowerCase();
      if (lowerName.contains(lowerLabel) || lowerLabel.contains(lowerName)) return gpu;
    }
    return gpus.first;
  }

  /// Windows equivalent of [startGpuComputeTest] (glmark2) — a real
  /// GPU compute-kernel stress test via OpenCL rather than an external
  /// process. See [OpenClComputeReader]'s class doc for the full
  /// reasoning behind this specific implementation choice.
  ///
  /// [platformIndex]/[deviceIndex] pick which GPU (from
  /// [listOpenClGpuDevices]) actually runs the test — this is what
  /// lets a multi-GPU system genuinely stress-test either card, unlike
  /// the render test mode which is always bound to whichever GPU
  /// Flutter's own rendering surface happens to use.
  BenchmarkRun startGpuComputeTestOpenCl(
    BenchmarkIntensity intensity, {
    int platformIndex = 0,
    int deviceIndex = 0,
    String? deviceLabel,
  }) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;

    Future<void> run() async {
      final stopwatch = Stopwatch()..start();
      final duration = _openClDurationFor(intensity);
      final iterations = _openClIterationsFor(intensity);
      String? abortReason;
      var peakTemp = 0.0;
      var dispatchCount = 0;
      Timer? safetyTimer;

      AppLogger.instance.info(
        _logSource,
        'GPU compute-test (OpenCL) gestart: $iterations iteraties/dispatch, '
        '${duration.inSeconds}s, intensiteit ${intensity.label}, '
        'apparaat: ${deviceLabel ?? "platform $platformIndex/apparaat $deviceIndex (onbekende naam)"}',
      );
      final powerAtStart = await _logPowerAtStart('GPU compute-test (OpenCL)');

      try {
        final available = await isOpenClAvailable();
        if (!available) {
          abortReason = 'OpenCL is niet beschikbaar op dit systeem';
          throw StateError(abortReason);
        }

        safetyTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
          if (cancelled) return;
          try {
            final gpus = await sensors.readGpus().timeout(const Duration(seconds: 5));
            // Match by deviceLabel rather than blindly taking .first —
            // .first is whichever GPU this app's sensor service happens
            // to enumerate first (WMI row order on Windows, which has
            // no relation to OpenCL's own platform/device order), so on
            // a system with more than one GPU it can easily be *not*
            // the card this test is actually dispatching work to. That
            // would both mislabel the reported peak temperature and,
            // worse, point the >100°C safety abort at the wrong card
            // entirely.
            final matched = _matchTestedGpuSample(gpus, deviceLabel);
            if (matched != null) {
              final temp = matched.temperatureC;
              if (temp != null && temp > peakTemp) peakTemp = temp;
              if (temp != null && temp > 100.0) {
                abortReason = 'GPU-temperatuur te hoog (${temp.toStringAsFixed(0)}°C)';
                cancelled = true;
              }
            }
          } catch (_) {
            // Same reasoning as every other safety timer in this
            // file: a slow/failed tick doesn't abort an otherwise-fine
            // test.
          }
          final fraction = (stopwatch.elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
          if (!controller.isClosed) {
            controller.add(BenchmarkProgress(
              fractionComplete: fraction,
              statusText: '${(fraction * 100).toStringAsFixed(0)}% · $dispatchCount dispatches',
            ));
          }
        });

        // The actual sustained-load loop: many small, bounded
        // dispatches rather than one long one — see
        // OpenClComputeReader.runDispatchBatch's doc for why. Checked
        // against wall-clock elapsed time, same pattern as every other
        // test in this file.
        //
        // The `await Future.delayed(Duration.zero)` after every
        // dispatch is not a no-op: runDispatchBatch is a plain
        // synchronous FFI call (enqueue + a blocking clFinish), so
        // without ever yielding, this while loop would occupy the
        // whole UI isolate's event loop back-to-back for the entire
        // test duration — no repaints, no Timer.periodic ticks (this
        // test's own safetyTimer above included), no processing of the
        // Cancel button's tap, and no other screen's sensor-polling
        // timer running either. That is exactly what "the whole app
        // freezes and only comes back once the test finishes" looks
        // like from the outside, and it would also explain readings
        // elsewhere (e.g. a GPU's temperature tile on Summary/
        // Performance) appearing stuck at whatever they showed the
        // instant the test started. Yielding here after each — already
        // individually TDR-bounded — dispatch costs essentially nothing
        // against a multi-second test, and is what actually lets
        // everything above keep working while the test runs.
        while (stopwatch.elapsed < duration && !cancelled) {
          final ok = _openCl.runDispatchBatch(
            iterations,
            platformIndex: platformIndex,
            deviceIndex: deviceIndex,
          );
          if (!ok) {
            abortReason = 'OpenCL-dispatch mislukte — zie Log voor details';
            break;
          }
          dispatchCount++;
          await Future.delayed(Duration.zero);
        }

        safetyTimer.cancel();

        if (cancelled) {
          abortReason ??= 'geannuleerd door gebruiker';
        }

        AppLogger.instance.info(
          _logSource,
          'GPU compute-test (OpenCL) klaar: ${abortReason != null ? 'gestopt (${abortReason})' : 'voltooid'}, '
          '$dispatchCount dispatches, piektemp ${peakTemp.toStringAsFixed(0)}°C '
          '(apparaat: ${deviceLabel ?? "platform $platformIndex/apparaat $deviceIndex"})',
        );

        if (!controller.isClosed) await controller.close();
        final result = BenchmarkResult(
          type: BenchmarkType.gpu,
          intensity: intensity,
          actualDuration: stopwatch.elapsed,
          aborted: abortReason != null,
          abortReason: abortReason,
          // Dispatches/second — a genuine, comparable throughput
          // figure for this specific test, distinct from glmark2's
          // point score and the render test's frame count. All three
          // share BenchmarkType.gpu but are never charted together
          // (see the note on the glmark2 result below).
          score: stopwatch.elapsed.inMilliseconds > 0
              ? dispatchCount / (stopwatch.elapsed.inMilliseconds / 1000)
              : null,
          peakTemperatureC: peakTemp > 0 ? peakTemp : null,
          details: {
            'modus': 'compute',
            'tool': 'opencl',
            if (deviceLabel != null) 'apparaat': deviceLabel,
            ...await _powerDetails(powerAtStart),
          },
        );
        // Deliberately not recorded via recordResult() — same reasoning
        // as glmark2's result below: compute-mode throughput numbers
        // and render-mode frame counts share BenchmarkType.gpu, and
        // mixing them into one session chart would contaminate it for
        // no benefit, since the UI never charts compute results.
        if (!resultCompleter.isCompleted) resultCompleter.complete(result);
      } catch (e, st) {
        safetyTimer?.cancel();
        AppLogger.instance.error(_logSource, 'GPU compute-test (OpenCL) failed: $e\n$st');
        if (!controller.isClosed) await controller.close();
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.gpu,
            intensity: intensity,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? 'onverwachte fout',
            details: {
              'modus': 'compute',
              'tool': 'opencl',
              if (deviceLabel != null) 'apparaat': deviceLabel,
            },
          ));
        }
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }

  Future<bool> isGlmark2Available() async {
    try {
      final result = await Process.run('which', ['glmark2']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Runs `pkexec apt-get install -y glmark2`, streaming output into the
  /// app log — same pattern as GpuSensorMixin's installIntelGpuTools.
  Future<bool> installGlmark2() async {
    AppLogger.instance.info(_logSource, 'User requested glmark2 install via pkexec');
    try {
      final process = await Process.start(
        'pkexec',
        ['apt-get', 'install', '-y', 'glmark2'],
        environment: {'DEBIAN_FRONTEND': 'noninteractive'},
      );
      process.stdout.transform(const SystemEncoding().decoder).listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) AppLogger.instance.debug(_logSource, 'apt-get: $trimmed');
      });
      process.stderr.transform(const SystemEncoding().decoder).listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) AppLogger.instance.debug(_logSource, 'apt-get: $trimmed');
      });
      final exitCode = await process.exitCode;
      final success = exitCode == 0;
      AppLogger.instance.info(_logSource,
          success ? 'glmark2 installed successfully' : 'glmark2 install failed (exit $exitCode)');
      return success;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'pkexec apt-get call failed: $e');
      return false;
    }
  }

  BenchmarkRun startGpuComputeTest() {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BenchmarkResult>();
    var cancelled = false;
    Process? process;

    Future<void> run() async {
      final stopwatch = Stopwatch()..start();
      String? abortReason;
      var peakTemp = 0.0;
      var sceneCount = 0;
      int? finalScore;
      Timer? safetyTimer;

      AppLogger.instance.info(_logSource, 'GPU compute-test (glmark2) gestart');

      try {
        final available = await isGlmark2Available();
        if (!available) {
          abortReason = 'glmark2 is niet geïnstalleerd';
          throw StateError(abortReason);
        }

        process = await Process.start('glmark2', const []);

        safetyTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
          if (cancelled) return;
          try {
            // Timeout for the same reason as the CPU/memory/crypto
            // tests' safety timers: a maxed-out GPU (the whole point
            // of this test) can itself slow down the background sensor
            // read that's supposed to be watching it. Falls into the
            // same lenient catch below either way — a single slow or
            // failed tick doesn't abort a real external benchmark
            // that's otherwise running fine — this just stops a stuck
            // read from silently piling up call after call.
            final gpus = await sensors.readGpus().timeout(const Duration(seconds: 5));
            if (gpus.isNotEmpty) {
              final temp = gpus.first.temperatureC;
              if (temp != null && temp > peakTemp) peakTemp = temp;
              if (temp != null && temp > 100.0) {
                abortReason = 'GPU-temperatuur te hoog (${temp.toStringAsFixed(0)}°C)';
                cancelled = true;
                process?.kill();
              }
            }
          } catch (_) {
            // A single failed (or timed-out) sensor read mid-test
            // shouldn't abort a real external benchmark that's
            // otherwise running fine.
          }
          // Unconditional, same reasoning as the other three tests'
          // safety timers: sceneCount is updated separately (by
          // parsing glmark2's own stdout, not by anything above), so
          // this progress update never actually needed the GPU read to
          // succeed — gating it on the try block above only meant a
          // slow/timed-out tick made the progress bar look stuck too.
          if (!controller.isClosed) {
            // glmark2's default suite runs ~25 scenes — an
            // approximation, since it doesn't report total scene
            // count upfront, only completes them one at a time.
            controller.add(BenchmarkProgress(
              fractionComplete: (sceneCount / 25).clamp(0.0, 0.95),
              statusText: '$sceneCount scenes voltooid...',
            ));
          }
        });

        final scoreCompleter = Completer<void>();
        process!.stdout
            .transform(const SystemEncoding().decoder)
            .transform(const LineSplitter())
            .listen((line) {
          if (line.trimLeft().startsWith('[')) sceneCount++;
          final match = RegExp(r'glmark2\s+Score:\s*(\d+)').firstMatch(line);
          if (match != null) finalScore = int.tryParse(match.group(1)!);
        }, onDone: () {
          if (!scoreCompleter.isCompleted) scoreCompleter.complete();
        });
        unawaited(process!.stderr.drain());

        final exitCode = await process!.exitCode;
        await scoreCompleter.future.timeout(const Duration(seconds: 2), onTimeout: () {});
        safetyTimer.cancel();

        if (cancelled) {
          abortReason ??= 'geannuleerd door gebruiker';
        } else if (exitCode != 0 && finalScore == null) {
          abortReason = 'glmark2 gaf geen score (exitcode $exitCode)';
        }

        AppLogger.instance.info(
          _logSource,
          'GPU compute-test klaar: ${cancelled || finalScore == null ? 'gestopt (${abortReason ?? 'onbekend'})' : 'voltooid'}, '
          'score ${finalScore ?? 'n/a'}, piektemp ${peakTemp.toStringAsFixed(0)}°C',
        );

        if (!controller.isClosed) await controller.close();
        final result = BenchmarkResult(
          type: BenchmarkType.gpu,
          // glmark2's own built-in scene suite has no adjustable
          // intensity the way our other tests do — recorded as
          // "gemiddeld" purely to satisfy the shared model, with the
          // real distinguishing info in details['modus'].
          intensity: BenchmarkIntensity.gemiddeld,
          actualDuration: stopwatch.elapsed,
          aborted: cancelled || finalScore == null,
          abortReason: abortReason,
          score: finalScore?.toDouble(),
          peakTemperatureC: peakTemp > 0 ? peakTemp : null,
          details: const {'modus': 'compute', 'tool': 'glmark2'},
        );
        // Deliberately NOT recorded via recordResult(): compute-mode
        // scores (glmark2 points) and render-mode scores (frames
        // rendered) share the same BenchmarkType.gpu + intensity key in
        // session history, since compute mode has no adjustable
        // intensity of its own and always uses "gemiddeld" as a
        // placeholder. Recording both under that shared key would let
        // wildly different-scale numbers end up in the same
        // session comparison chart — the UI already never charts
        // compute results, so there'd be nothing to gain and a real
        // contamination risk for render-mode's own history.
        if (!resultCompleter.isCompleted) resultCompleter.complete(result);
      } catch (e) {
        AppLogger.instance.error(_logSource, 'GPU compute-test mislukt: $e');
        safetyTimer?.cancel();
        if (!controller.isClosed) await controller.close();
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BenchmarkResult(
            type: BenchmarkType.gpu,
            intensity: BenchmarkIntensity.gemiddeld,
            actualDuration: stopwatch.elapsed,
            aborted: true,
            abortReason: abortReason ?? '$e',
            details: const {'modus': 'compute'},
          ));
        }
      }
    }

    unawaited(run());

    return BenchmarkRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () {
        cancelled = true;
        process?.kill();
      },
    );
  }

  // ---------------------------------------------------------------------
  // Battery drain test — only meaningful (and only offered in the UI)
  // on a machine with a battery that's actually discharging. Measures
  // real capacity drop over a fixed window while running a modest
  // single-core background load (closer to "how much does using this
  // laptop cost" than a pure-idle measurement, which a person could
  // already estimate by watching the tray icon over time).
  // ---------------------------------------------------------------------

  BatteryTestRun startBatteryTest({Duration duration = const Duration(minutes: 3)}) {
    final controller = StreamController<BenchmarkProgress>();
    final resultCompleter = Completer<BatteryTestResult>();
    var cancelled = false;

    Future<void> run() async {
      final stopwatch = Stopwatch()..start();
      final startSample = await sensors.readBattery();

      if (!startSample.present || startSample.capacityPercent == null) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(const BatteryTestResult(
            aborted: true,
            abortReason: 'Geen batterij gevonden op dit systeem.',
            actualDuration: Duration.zero,
            startCapacityPercent: 0,
            endCapacityPercent: 0,
          ));
        }
        if (!controller.isClosed) await controller.close();
        return;
      }
      if (!startSample.isDischarging) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BatteryTestResult(
            aborted: true,
            abortReason: 'Apparaat is aangesloten op netvoeding (status: '
                '${startSample.status ?? 'onbekend'}) — koppel de oplader los voor een zinvolle meting.',
            actualDuration: Duration.zero,
            startCapacityPercent: startSample.capacityPercent!,
            endCapacityPercent: startSample.capacityPercent!,
          ));
        }
        if (!controller.isClosed) await controller.close();
        return;
      }

      final batteryPower = await PowerContext.capture();
      // Fijnere meting in mWh/mW (null als de machine dat niet levert).
      final energyStart = await sensors.readBatteryEnergy();
      final energyPoints = <_EnergyPoint>[
        if (energyStart != null) _EnergyPoint(Duration.zero, energyStart),
      ];
      AppLogger.instance.info(
          _logSource,
          energyStart != null
              ? 'Batterij-energie beschikbaar: ${energyStart.remainingMWh.toStringAsFixed(0)} mWh resterend'
                  '${energyStart.fullChargeMWh != null ? ' van ${energyStart.fullChargeMWh!.toStringAsFixed(0)} mWh vol' : ''}'
                  '${energyStart.drawMW != null ? ', gemeld verbruik ${(energyStart.drawMW! / 1000).toStringAsFixed(1)} W' : ', geen verbruik gemeld'}'
              : 'Batterij-energie (mWh/mW) niet beschikbaar; alleen hele procenten.');
      AppLogger.instance.info(_logSource,
          'Batterijtest gestart: start ${startSample.capacityPercent}%, ${duration.inMinutes} min, met lichte achtergrondbelasting, '
          'energieplan ${batteryPower.plan}');

      // Every reading (elapsed time + whole-percent capacity) is kept so
      // the drain rate can be computed between the moments the battery
      // percentage actually *changed*, instead of from start/end alone
      // (see _estimateDrainPercentPerHour).
      final batteryPoints = <_BatteryPoint>[
        _BatteryPoint(Duration.zero, startSample.capacityPercent!),
      ];

      final receivePort = ReceivePort();
      Isolate? loadIsolate;
      try {
        loadIsolate =
            await Isolate.spawn(_cpuWorkerEntry, _CpuWorkerConfig(receivePort.sendPort, duration));
      } catch (e) {
        AppLogger.instance.debug(_logSource, 'Kon achtergrondbelasting voor batterijtest niet starten: $e');
      }
      final opsSub = receivePort.listen((_) {}); // not scoring CPU here, just generating load

      try {
        while (stopwatch.elapsed < duration && !cancelled) {
          await Future.delayed(const Duration(seconds: 2));
          final sample = await sensors.readBattery();
          if (sample.capacityPercent != null) {
            batteryPoints.add(_BatteryPoint(stopwatch.elapsed, sample.capacityPercent!));
          }
          if (energyStart != null) {
            final e = await sensors.readBatteryEnergy();
            if (e != null) energyPoints.add(_EnergyPoint(stopwatch.elapsed, e));
          }
          final fraction = (stopwatch.elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
          if (!controller.isClosed) {
            final remaining = duration - stopwatch.elapsed;
            controller.add(BenchmarkProgress(
              fractionComplete: fraction,
              statusText:
                  '${sample.capacityPercent ?? '?'}% · nog ${remaining.inSeconds.clamp(0, 999)}s',
            ));
          }
        }

        final endSample = await sensors.readBattery();
        final endCapacity = endSample.capacityPercent ?? startSample.capacityPercent!;
        batteryPoints.add(_BatteryPoint(stopwatch.elapsed, endCapacity));
        if (energyStart != null) {
          final e = await sensors.readBatteryEnergy();
          if (e != null) energyPoints.add(_EnergyPoint(stopwatch.elapsed, e));
        }
        final elapsedHours = stopwatch.elapsed.inSeconds / 3600;
        final drop = startSample.capacityPercent! - endCapacity;

        // Preferred: the rate between the first and last observed
        // percentage step. The battery only reports whole percents, so
        // start-minus-end over a short window can be off by up to a
        // full percent at each end (82% -> 80% in 3 minutes could be
        // anything from 0.5% to 1.5% really lost, i.e. 10-30 %/h vs a
        // reported 40 %/h). Timing between two actual steps removes
        // that rounding error. Falls back to start-minus-end when
        // fewer than two steps were seen.
        final stepRate = _estimateDrainPercentPerHour(batteryPoints);
        final endpointRate = (elapsedHours > 0 && drop > 0) ? drop / elapsedHours : null;
        // Begin/eind alleen is pas bruikbaar bij minstens 3 procent
        // verschil (fout van ±1% is dan hooguit ~33%); bij 0-2% zegt het
        // niets en zou het een schijnnauwkeurig "0,0%/uur" of een
        // uitschieter opleveren. Dan liever eerlijk geen getal.
        final percentFallback = cancelled
            ? null
            : (stepRate ?? ((elapsedHours > 0 && drop >= 3) ? drop / elapsedHours : null));

        // Voorkeur: echte energie (mWh/mW). Levert een schatting in watt,
        // procent per uur en de looptijd van een volle accu.
        final energy = cancelled ? null : _estimateFromEnergy(energyPoints);
        final percentPerHour = energy?.percentPerHour ?? percentFallback;
        if (energy != null) {
          AppLogger.instance.info(
            _logSource,
            'Batterij-energie: gemiddeld ${energy.watts.toStringAsFixed(1)} W '
            '(${energy.methodNote})'
            '${energy.runtimeHours != null ? ', volle accu houdt dit ~${energy.runtimeHours!.toStringAsFixed(1)} uur vol' : ''}.',
          );
        }

        AppLogger.instance.info(
          _logSource,
          'Batterijtest klaar: ${startSample.capacityPercent}% -> $endCapacity%, '
          '${percentPerHour != null ? '${percentPerHour.toStringAsFixed(1)}%/uur geschat' : 'geen betrouwbare schatting mogelijk'} '
          '(${energy != null ? 'afgeleid van de energiemeting in mWh/mW, zie de regel hierboven' : stepRate != null ? 'gemeten over meerdere procentstappen' : percentPerHour != null ? 'grove schatting uit begin/eind, te weinig procentstappen waargenomen' : 'te weinig procentstappen (minder dan 3) en minder dan 3% verschil; de batterij meldt alleen hele procenten, kies een langere test'}'
          '${stepRate != null && endpointRate != null ? '; begin/eind alleen had ${endpointRate.toStringAsFixed(1)}%/uur gegeven' : ''})',
        );

        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(BatteryTestResult(
            aborted: cancelled,
            abortReason: cancelled ? 'geannuleerd door gebruiker' : null,
            actualDuration: stopwatch.elapsed,
            startCapacityPercent: startSample.capacityPercent!,
            endCapacityPercent: endCapacity,
            percentPerHour: percentPerHour,
            averagePowerWatts: energy?.watts,
            estimatedRuntimeHours: energy?.runtimeHours,
            methodNote: energy?.methodNote,
          ));
        }
      } finally {
        await opsSub.cancel();
        receivePort.close();
        loadIsolate?.kill(priority: Isolate.immediate);
        if (!controller.isClosed) await controller.close();
      }
    }

    unawaited(run());

    return BatteryTestRun(
      progress: controller.stream,
      result: resultCompleter.future,
      cancel: () => cancelled = true,
    );
  }
}

class _CpuWorkerConfig {
  final SendPort sendPort;
  final Duration duration;
  const _CpuWorkerConfig(this.sendPort, this.duration);
}

/// Runs in a separate isolate — genuinely loads one CPU core. Pure
/// floating-point busy work, no external dependencies, bounded to avoid
/// overflow. Reports its operation count back roughly every 200ms so
/// the main isolate can compute a live combined rate.

/// Linux only: lowers just THIS worker isolate's own OS-thread scheduling
/// priority (its "niceness"), as the very first thing it does.
///
/// Geverifieerde oorzaak (Flutter's eigen "Merged threads on Linux"-
/// migratienotitie + GNOME Mutter's check-alive-timeout gsetting, beide
/// rechtstreeks nagelezen): sinds Flutter stable 3.41 (deze app bouwt op
/// 3.50.1) is de Linux "platform thread" -- die GTK/X11/Wayland-events
/// moet blijven verwerken, inclusief Mutter's periodieke "leef je nog?"-
/// ping -- samengevoegd met de Dart hoofd/UI-isolate-thread. Mutter's
/// standaard check-alive-timeout is 5000ms: krijgt die samengevoegde
/// thread niet op tijd de kans om binnen 5s te antwoorden, dan toont
/// GNOME "reageert niet" -- los van hoeveel cores er elders nominaal vrij
/// zijn, want Linux' CFS-scheduler geeft die ene thread geen intrinsieke
/// voorrang boven andere, even hoog geprioriteerde actieve threads. Een
/// eerdere poging (1 core vrijhouden) loste dit niet op -- top -H liet
/// tijdens een reproductie nog ~30% idle CPU zien terwijl het dialoog
/// actief was, wat bevestigt dat het nooit om kern-aantal ging.
///
/// Linux/NPTL-feit (niet specifiek voor deze app): setpriority(PRIO_PROCESS,
/// who, ...) met who==0 raakt alleen de AANROEPENDE thread, niet het hele
/// proces -- elke NPTL-thread is zijn eigen planbare kernel-taak. libc's
/// nice() (een dunne wrapper om diezelfde syscall) aanroepen vanuit een
/// net gestarte workerisolate verlaagt dus alleen de prioriteit van DIE
/// ene workerthread; de samengevoegde UI/platform-thread blijft op normale
/// prioriteit staan, waardoor Linux' scheduler die laatste systematisch
/// voortrekt zodra ze om een kern strijden -- ongeacht het aantal cores.
///
/// Best-effort en stil bij falen: in het ergste geval draait deze worker
/// gewoon op normale prioriteit zoals voorheen, zonder deze extra
/// bescherming -- nooit een reden om de test te laten mislukken. print(),
/// niet AppLogger: dit draait in een vers gespawnde isolate zonder
/// Flutter-plugin-bindings (vandaar dat elke andere logregel in dit
/// bestand vanuit de hoofdisolate komt).
void _lowerThisWorkerThreadPriorityOnLinux() {
  if (!Platform.isLinux) return;
  try {
    final libc = ffi.DynamicLibrary.open('libc.so.6');
    final nice = libc
        .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>('nice');
    nice(19); // 19 = laagst mogelijke OS-prioriteit (max niceness)
  } catch (e) {
    print('DarkTask: kon workerthread-prioriteit niet verlagen (niet kritiek): $e');
  }
}

void _cpuWorkerEntry(_CpuWorkerConfig config) async {
  _lowerThisWorkerThreadPriorityOnLinux();
  final stopwatch = Stopwatch()..start();
  var opsSinceReport = 0;
  var lastReportMs = 0;
  var x = 1.000001;

  while (stopwatch.elapsed < config.duration) {
    for (var i = 0; i < 200000; i++) {
      x = x * 1.0000001 + 0.0000001;
      if (x > 1e6 || x.isNaN || x.isInfinite) x = 1.000001;
    }
    opsSinceReport += 200000;

    final nowMs = stopwatch.elapsedMilliseconds;
    if (nowMs - lastReportMs >= 200) {
      config.sendPort.send(opsSinceReport);
      opsSinceReport = 0;
      lastReportMs = nowMs;
    }

    // ECHTE ROOT CAUSE (bevestigd door Dart-VM-ontwikkelaars zelf, zie
    // github.com/dart-lang/sdk/issues/51254 en
    // github.com/flutter/flutter/issues/161224): de Dart VM staat maar
    // een vast, beperkt aantal isolates toe dat écht tegelijk
    // ("in parallel") mag draaien zonder ooit terug te geven aan zijn
    // eigen event loop — ongeveer 6 à 8, volledig ONAFHANKELIJK van het
    // aantal CPU-cores. Dart-ontwikkelaar mkustermann hierover: "one can
    // run into this also in Dart if the dart code runs very long
    // synchronous code" — precies wat deze while-loop tot nu toe deed:
    // urenlang puur synchrone Dart-code zonder ooit een await. Zo'n
    // isolate bezet zijn "slot" voor altijd, waardoor andere isolates
    // (uiteindelijk ook het hoofdisolaat/de GUI) voor onbepaalde tijd
    // kunnen vastlopen op het wachten op een vrij slot — dit is dus geen
    // kwestie van CPU-verzadiging of OS-scheduling (vandaar dat de
    // eerdere nice()-fix niets opleverde), maar een Dart VM-interne
    // beperking. Door hier na elke rapportageronde héél even (0ms) terug
    // te geven aan de event loop, geeft deze isolate zijn "slot"
    // regelmatig vrij, zonder de gemeten rekensnelheid merkbaar te
    // beïnvloeden.
    await Future<void>.delayed(Duration.zero);
  }
  if (opsSinceReport > 0) config.sendPort.send(opsSinceReport);
  config.sendPort.send('done');
}

class _MemoryWorkerConfig {
  final SendPort sendPort;
  final Duration duration;
  final int bufferBytes;
  const _MemoryWorkerConfig(this.sendPort, this.duration, this.bufferBytes);
}

/// Runs in a separate isolate — repeatedly copies [bufferBytes] from one
/// buffer into another for the test duration. Reports bytes copied back
/// roughly every 200ms, same cadence as the CPU worker.
void _memoryWorkerEntry(_MemoryWorkerConfig config) {
  _lowerThisWorkerThreadPriorityOnLinux();
  final stopwatch = Stopwatch()..start();
  final src = Uint8List(config.bufferBytes);
  final dst = Uint8List(config.bufferBytes);

  // Touch every page once before timing starts: on first access, the OS
  // lazily backs each page with physical memory (and some allocators
  // zero it lazily too), which would otherwise show up as an artificial
  // slowdown in the very first iteration rather than reflecting steady-
  // state copy speed.
  for (var i = 0; i < src.length; i += 4096) {
    src[i] = 1;
  }

  var bytesSinceReport = 0;
  var lastReportMs = 0;

  while (stopwatch.elapsed < config.duration) {
    dst.setAll(0, src); // one full sequential buffer copy
    bytesSinceReport += config.bufferBytes;

    final nowMs = stopwatch.elapsedMilliseconds;
    if (nowMs - lastReportMs >= 200) {
      config.sendPort.send(bytesSinceReport);
      bytesSinceReport = 0;
      lastReportMs = nowMs;
    }
  }
  if (bytesSinceReport > 0) config.sendPort.send(bytesSinceReport);
  config.sendPort.send('done');
}

class _CryptoWorkerConfig {
  final SendPort sendPort;
  final Duration duration;
  const _CryptoWorkerConfig(this.sendPort, this.duration);
}

/// Runs in a separate isolate — repeatedly SHA-256-hashes a 4 MiB
/// buffer using package:crypto's real (not hand-rolled) implementation.
/// Reports bytes hashed back roughly every 200ms, same cadence as the
/// other workers.
void _cryptoWorkerEntry(_CryptoWorkerConfig config) async {
  _lowerThisWorkerThreadPriorityOnLinux();
  final stopwatch = Stopwatch()..start();
  final data = Uint8List(4 * 1024 * 1024);
  for (var i = 0; i < data.length; i += 4096) {
    data[i] = 1;
  }

  var bytesSinceReport = 0;
  var lastReportMs = 0;

  while (stopwatch.elapsed < config.duration) {
    sha256.convert(data);
    bytesSinceReport += data.length;

    final nowMs = stopwatch.elapsedMilliseconds;
    if (nowMs - lastReportMs >= 200) {
      config.sendPort.send(bytesSinceReport);
      bytesSinceReport = 0;
      lastReportMs = nowMs;
    }

    // Zie de uitgebreide toelichting bij _cpuWorkerEntry hierboven:
    // zelfde bevestigde Dart VM-limiet op het aantal isolates dat écht
    // parallel mag draaien zonder terug te geven aan de event loop
    // (dart-lang/sdk#51254, flutter/flutter#161224) — hier na elke
    // hash-ronde toegepast.
    await Future<void>.delayed(Duration.zero);
  }
  if (bytesSinceReport > 0) config.sendPort.send(bytesSinceReport);
  config.sendPort.send('done');
}

/// One battery reading taken during the battery drain test.
class _BatteryPoint {
  final Duration at;
  final int percent;
  const _BatteryPoint(this.at, this.percent);
}

/// Drain rate in percent per hour, measured between the first and the
/// last moment the whole-number battery percentage was seen to drop.
///
/// Returns null when fewer than two distinct drops were observed (or
/// they happened at the same moment), in which case the caller falls
/// back to a coarse start-minus-end estimate.
double? _estimateDrainPercentPerHour(List<_BatteryPoint> points) {
  _BatteryPoint? firstStep;
  _BatteryPoint? lastStep;
  var steps = 0;
  for (var i = 1; i < points.length; i++) {
    if (points[i].percent < points[i - 1].percent) {
      firstStep ??= points[i];
      lastStep = points[i];
      steps++;
    }
  }
  // Minstens drie stappen (= twee volledige intervallen): met één interval
  // is de uitkomst puur toeval van waar de procentafronding toevallig viel
  // (gemeten: 89,6%/uur tegen 40%/uur begin/eind op dezelfde run).
  if (steps < 3 || firstStep == null || lastStep == null) return null;
  final droppedPercent = firstStep.percent - lastStep.percent;
  final seconds = (lastStep.at - firstStep.at).inMilliseconds / 1000.0;
  if (droppedPercent <= 0 || seconds <= 0) return null;
  return droppedPercent / (seconds / 3600.0);
}

class _EnergyPoint {
  final Duration at;
  final BatteryEnergySample sample;
  const _EnergyPoint(this.at, this.sample);
}

class _EnergyEstimate {
  final double watts;
  final double? percentPerHour;
  final double? runtimeHours;
  final String methodNote;
  const _EnergyEstimate(this.watts, this.percentPerHour, this.runtimeHours, this.methodNote);
}

/// Schat het gemiddelde verbruik uit twee onafhankelijke bronnen en kiest
/// de betrouwbaarste:
///  - capaciteit: kleinste-kwadratenlijn door alle (tijd, resterende mWh)
///    punten; de helling is het verbruik in mW. Alleen betrouwbaar als de
///    capaciteit in de tijdspanne genoeg veranderd is (>= 2% van vol), want
///    sommige accu's melden mWh in grove stappen.
///  - gemeld verbruik: gemiddelde van de door de batterij gemelde mW-waarden
///    (minstens 5 metingen).
/// Geeft null als geen van beide bruikbaar is.
_EnergyEstimate? _estimateFromEnergy(List<_EnergyPoint> pts) {
  if (pts.length < 3) return null;

  final fullMWh = pts
      .map((p) => p.sample.fullChargeMWh)
      .whereType<double>()
      .fold<double?>(null, (acc, v) => acc ?? v);

  // Kleinste-kwadratenlijn: mWh = a + b * uren.
  final n = pts.length;
  final xs = [for (final p in pts) p.at.inMilliseconds / 3600000.0];
  final ys = [for (final p in pts) p.sample.remainingMWh];
  final meanX = xs.reduce((a, b) => a + b) / n;
  final meanY = ys.reduce((a, b) => a + b) / n;
  var sxx = 0.0;
  var sxy = 0.0;
  for (var i = 0; i < n; i++) {
    sxx += (xs[i] - meanX) * (xs[i] - meanX);
    sxy += (xs[i] - meanX) * (ys[i] - meanY);
  }
  final spanHours = xs.last - xs.first;
  double? capacityMW;
  double? capacityDropMWh;
  if (sxx > 0 && spanHours > 0) {
    final slope = sxy / sxx; // mWh per uur = mW
    if (slope < 0) {
      capacityMW = -slope;
      capacityDropMWh = -slope * spanHours;
    }
  }

  final rates = [
    for (final p in pts)
      if (p.sample.drawMW != null && p.sample.drawMW! > 0) p.sample.drawMW!,
  ];
  final avgRateMW = rates.length >= 5 ? rates.reduce((a, b) => a + b) / rates.length : null;

  final capacityGood = capacityMW != null &&
      capacityDropMWh != null &&
      fullMWh != null &&
      capacityDropMWh >= 0.02 * fullMWh;
  final capacityRough = capacityMW != null && capacityDropMWh != null && capacityDropMWh > 0;

  double mw;
  String note;
  if (capacityGood) {
    mw = capacityMW!;
    note = 'uit afname van de accu-energie, ${capacityDropMWh!.toStringAsFixed(0)} mWh in '
        '${(spanHours * 60).toStringAsFixed(1)} min'
        '${avgRateMW != null ? '; gemeld verbruik gaf ${(avgRateMW / 1000).toStringAsFixed(1)} W' : ''}';
  } else if (avgRateMW != null) {
    mw = avgRateMW;
    note = 'gemiddelde van ${rates.length} door de accu gemelde verbruikswaarden'
        '${capacityRough ? '; energieafname was te klein om te vertrouwen (${capacityDropMWh!.toStringAsFixed(0)} mWh)' : ''}';
  } else if (capacityRough) {
    mw = capacityMW!;
    note = 'grove schatting uit een kleine energieafname (${capacityDropMWh!.toStringAsFixed(0)} mWh); '
        'accu meldt geen verbruik';
  } else {
    return null;
  }

  return _EnergyEstimate(
    mw / 1000,
    fullMWh != null && fullMWh > 0 ? mw / fullMWh * 100 : null,
    fullMWh != null && mw > 0 ? fullMWh / mw : null,
    note,
  );
}
