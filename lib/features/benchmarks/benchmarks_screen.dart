import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../../core/models/benchmark_models.dart';
import '../../core/models/disk_sample.dart';
import '../../core/theming/graph_palette.dart';
import '../../services/benchmark_history_store.dart';
import '../../services/benchmark_service.dart';
import '../../services/report_service.dart';
import '../../services/sensors/system_sensor_service.dart';
import '../../services/sensors/windows/opencl_compute_reader.dart';
import '../../services/settings_service.dart';
import '../../widgets/benchmark_bar_chart.dart';

const _logSource = 'BenchmarksScreen';

enum _ScreenState { idle, running, result }

class BenchmarksScreen extends StatefulWidget {
  /// Shared across every screen (owned by the top-level app shell).
  final SystemSensorService sensors;

  const BenchmarksScreen({super.key, required this.sensors});

  @override
  State<BenchmarksScreen> createState() => _BenchmarksScreenState();
}

class _BenchmarksScreenState extends State<BenchmarksScreen> with TickerProviderStateMixin {
  SystemSensorService get _sensors => widget.sensors;
  late final BenchmarkService _benchmarks = BenchmarkService(_sensors);

  /// True while [_exportReport] is generating the HTML/PDF report —
  /// disables the button so a second tap can't start a second,
  /// overlapping generation (each one does several sensor reads plus a
  /// PDF build, so this isn't instant).
  bool _generatingReport = false;
  GraphColorScheme get _colors => GraphColorScheme.fromSettings(SettingsService.instance.current);

  @override
  void initState() {
    super.initState();
    _checkGlmark2();
    _checkBattery();
    _loadDisks();
  }

  // --- One-time environment checks: which optional features/hardware
  // are actually available on this machine, so the UI only offers what
  // will genuinely work (a "Compute" toggle when neither backend is
  // available would just be a button that always fails; a "Battery
  // test" card on a desktop with no battery would be meaningless). ---

  bool? _computeAvailable; // null = not checked yet
  Future<void> _checkGlmark2() async {
    // Same "Compute" mode toggle on both platforms, backed by whichever
    // real (not approximated) GPU-load mechanism actually exists there:
    // glmark2 (a real OpenGL benchmark) on Linux, OpenCL (a real
    // compute-kernel dispatch) on Windows — never Direct3D, see
    // OpenClComputeReader's class doc for why. Neither exists on the
    // other platform, so this is the one place platform branches.
    final available =
        Platform.isWindows ? await _benchmarks.isOpenClAvailable() : await _benchmarks.isGlmark2Available();
    if (mounted) setState(() => _computeAvailable = available);
    // Only Windows' OpenCL path supports picking a specific GPU (see
    // OpenClComputeReader.listGpuDevices's doc) — glmark2 on Linux has
    // no equivalent device-selection concept in this app, so the list
    // stays empty there and the picker UI never shows.
    if (available && Platform.isWindows) {
      await _loadOpenClGpuDevices();
    }
  }

  List<OpenClGpuDevice> _openClGpuDevices = [];
  OpenClGpuDevice? _selectedOpenClDevice;

  Future<void> _loadOpenClGpuDevices() async {
    final devices = await _benchmarks.listOpenClGpuDevices();
    if (!mounted) return;
    setState(() {
      _openClGpuDevices = devices;
      // Keep the current selection if it's still in the list (e.g. a
      // manual refresh), otherwise default to the first device found.
      if (devices.isEmpty) {
        _selectedOpenClDevice = null;
      } else if (_selectedOpenClDevice == null || !devices.contains(_selectedOpenClDevice)) {
        _selectedOpenClDevice = devices.first;
      } else {
        // Same (platformIndex, deviceIndex) as before (OpenClGpuDevice's
        // `==` compares by index, not identity) — but re-point at the
        // freshly-fetched instance so DropdownButton's identity-agnostic
        // `==` match against `items` still has exactly one hit.
        _selectedOpenClDevice = devices.firstWhere((d) => d == _selectedOpenClDevice);
      }
    });
  }

  bool _batteryChecked = false;
  bool _batteryPresent = false;
  Future<void> _checkBattery() async {
    final sample = await _sensors.readBattery();
    if (mounted) {
      setState(() {
        _batteryChecked = true;
        _batteryPresent = sample.present;
      });
    }
  }

  List<DiskSample> _disks = [];
  Future<void> _loadDisks() async {
    final disks = await _sensors.readDisks();
    if (mounted) setState(() => _disks = disks);
  }

  /// Icon for each test type — used consistently across the selection
  /// cards, running view, and result view so the same visual identity
  /// carries through the whole flow.
  IconData _typeIcon(BenchmarkType type) {
    switch (type) {
      case BenchmarkType.cpu:
        return Icons.memory;
      case BenchmarkType.memory:
        return Icons.developer_board;
      case BenchmarkType.disk:
        return Icons.storage;
      case BenchmarkType.network:
        return Icons.lan;
      case BenchmarkType.crypto:
        return Icons.enhanced_encryption;
      case BenchmarkType.gpu:
        return Icons.videogame_asset;
    }
  }

  /// Identity color for each test type, sourced from the same
  /// GraphColorScheme used on Summary/Performance — a CPU test looks
  /// like "CPU" using the exact color CPU already means everywhere
  /// else in the app, rather than an unrelated color picked just for
  /// this screen.
  Color _typeColor(BenchmarkType type) {
    switch (type) {
      case BenchmarkType.cpu:
        return _colors.cpu;
      case BenchmarkType.memory:
        return _colors.memory;
      case BenchmarkType.disk:
        return _colors.disk;
      case BenchmarkType.network:
        return _colors.network;
      case BenchmarkType.crypto:
        return _colors.crypto;
      case BenchmarkType.gpu:
        return _colors.gpu;
    }
  }

  String _typeLabel(BenchmarkType type) {
    switch (type) {
      case BenchmarkType.cpu:
        return 'CPU';
      case BenchmarkType.memory:
        return 'Memory';
      case BenchmarkType.disk:
        return 'Disk';
      case BenchmarkType.network:
        return 'Network';
      case BenchmarkType.crypto:
        return 'Crypto';
      case BenchmarkType.gpu:
        return 'GPU';
    }
  }

  /// orangeAccent.shade100 (a light, pastel orange) reads fine on
  /// DarkTask's near-black background but is nearly invisible on a
  /// light-mode background — same class of bug fixed elsewhere in the
  /// app. Picks a properly contrasting shade for whichever brightness
  /// is actually active.
  Color _warningTextColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? Colors.orangeAccent.shade100 : Colors.orange.shade800;

  Color _successIconColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? Colors.greenAccent : Colors.green.shade700;

  Color _abortedIconColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? Colors.orangeAccent : Colors.orange.shade800;

  _ScreenState _screenState = _ScreenState.idle;
  BenchmarkType _selectedType = BenchmarkType.cpu;
  BenchmarkIntensity _selectedIntensity = BenchmarkIntensity.gemiddeld;
  GpuTestMode _gpuMode = GpuTestMode.render;
  String? _selectedDiskMountPoint; // null = default (system temp dir)

  BenchmarkProgress? _liveProgress;
  BenchmarkResult? _lastResult;
  StreamSubscription<BenchmarkProgress>? _progressSub;
  void Function()? _cancelCurrentRun;

  // --- Battery test: separate flow from the rest — different result
  // shape (BatteryTestResult, not BenchmarkResult), and only reachable
  // from its own card, not the regular type/intensity picker. ---
  bool _batteryFlowActive = false;
  BenchmarkProgress? _batteryProgress;
  BatteryTestResult? _batteryResult;
  StreamSubscription<BenchmarkProgress>? _batteryProgressSub;
  void Function()? _cancelBatteryRun;

  // --- GPU render-mode test state (rendering-load approximation — see
  // _startGpuTest) ---
  Ticker? _gpuTicker;
  Duration _gpuElapsed = Duration.zero;
  Duration _gpuDuration = Duration.zero;
  int _gpuFrameCount = 0;
  int _gpuParticleCount = 0;
  Timer? _gpuSafetyTimer;
  double _gpuPeakTemp = 0;
  bool _gpuCancelled = false;
  String? _gpuAbortReason;

  // --- Stress test: "everything at once" — runs CPU, Memory, Disk,
  // Crypto, and Network concurrently (each via its own already-tested
  // BenchmarkRun, complete with its own thermal safety cutoff and
  // cleanup) plus the GPU render-load ticker, so the whole machine is
  // under load simultaneously rather than one subsystem at a time. Each
  // sub-test keeps its own per-intensity duration, so they don't all
  // finish together — that's expected and even informative (whichever
  // finishes last is usually the bottleneck for that intensity). GPU
  // reuses the exact same render-load mechanics as the standalone GPU
  // test above; _gpuFeedsStressTest just redirects where the result
  // (and peak temp) end up.
  bool _stressFlowActive = false;
  bool _gpuFeedsStressTest = false;
  static const _stressTypes = [
    BenchmarkType.cpu,
    BenchmarkType.memory,
    BenchmarkType.disk,
    BenchmarkType.crypto,
    BenchmarkType.network,
    BenchmarkType.gpu,
  ];
  final Map<BenchmarkType, BenchmarkProgress?> _stressProgress = {};
  final Map<BenchmarkType, BenchmarkResult> _stressResults = {};
  final List<StreamSubscription<BenchmarkProgress>> _stressProgressSubs = [];
  final List<void Function()> _stressCancelFns = [];
  double _stressPeakCpuTemp = 0;
  double _stressPeakGpuTemp = 0;

  @override
  void dispose() {
    _progressSub?.cancel();
    _batteryProgressSub?.cancel();
    for (final sub in _stressProgressSubs) {
      sub.cancel();
    }
    _gpuTicker?.dispose();
    _gpuSafetyTimer?.cancel();
    super.dispose();
  }

  void _startSelectedTest() {
    setState(() {
      _screenState = _ScreenState.running;
      _batteryFlowActive = false;
      _stressFlowActive = false;
      _liveProgress = null;
    });

    switch (_selectedType) {
      case BenchmarkType.cpu:
        _runServiceBackedTest(_benchmarks.startCpuTest(_selectedIntensity));
        break;
      case BenchmarkType.memory:
        _runServiceBackedTest(_benchmarks.startMemoryTest(_selectedIntensity));
        break;
      case BenchmarkType.disk:
        _runServiceBackedTest(
            _benchmarks.startDiskTest(_selectedIntensity, targetMountPoint: _selectedDiskMountPoint));
        break;
      case BenchmarkType.network:
        _runServiceBackedTest(_benchmarks.startNetworkTest(_selectedIntensity));
        break;
      case BenchmarkType.crypto:
        _runServiceBackedTest(_benchmarks.startCryptoTest(_selectedIntensity));
        break;
      case BenchmarkType.gpu:
        if (_gpuMode == GpuTestMode.compute) {
          if (Platform.isWindows) {
            final device = _selectedOpenClDevice;
            _runServiceBackedTest(_benchmarks.startGpuComputeTestOpenCl(
              _selectedIntensity,
              platformIndex: device?.platformIndex ?? 0,
              deviceIndex: device?.deviceIndex ?? 0,
              deviceLabel: device?.name,
            ));
          } else {
            _runServiceBackedTest(_benchmarks.startGpuComputeTest());
          }
        } else {
          _startGpuTest(_selectedIntensity);
        }
        break;
    }
  }

  void _runServiceBackedTest(BenchmarkRun run) {
    _cancelCurrentRun = run.cancel;
    _progressSub = run.progress.listen((progress) {
      if (mounted) setState(() => _liveProgress = progress);
    });
    run.result.then((result) {
      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _screenState = _ScreenState.result;
      });
    });
  }

  void _cancelRunningTest() {
    if (_stressFlowActive) {
      _cancelStressTest();
    } else if (_selectedType == BenchmarkType.gpu && _gpuMode == GpuTestMode.render) {
      _gpuCancelled = true;
      _gpuAbortReason = 'geannuleerd door gebruiker';
    } else {
      _cancelCurrentRun?.call();
    }
  }

  // --- Battery test flow ------------------------------------------------

  void _startBatteryTest() {
    setState(() {
      _batteryFlowActive = true;
      _screenState = _ScreenState.running;
      _batteryProgress = null;
      _batteryResult = null;
    });
    final run = _benchmarks.startBatteryTest();
    _cancelBatteryRun = run.cancel;
    _batteryProgressSub = run.progress.listen((progress) {
      if (mounted) setState(() => _batteryProgress = progress);
    });
    run.result.then((result) {
      if (!mounted) return;
      setState(() {
        _batteryResult = result;
        _screenState = _ScreenState.result;
      });
    });
  }

  // --- Stress test flow ("alles tegelijk") -------------------------------

  void _startStressTest() {
    setState(() {
      _stressFlowActive = true;
      _screenState = _ScreenState.running;
      _stressProgress.clear();
      _stressResults.clear();
      _stressPeakCpuTemp = 0;
      _stressPeakGpuTemp = 0;
    });
    for (final sub in _stressProgressSubs) {
      sub.cancel();
    }
    _stressProgressSubs.clear();
    _stressCancelFns.clear();

    // Spawning CPU (up to core-count workers) + Memory (up to 4) +
    // Crypto (up to core-count) isolates all at once — a dozen or more
    // on a typical machine — is real VM work that competes with the
    // main isolate for CPU time. Doing it synchronously right after
    // setState() above means Flutter never gets a chance to actually
    // paint the "running" screen before that work starts, so the app
    // visibly freezes for a moment instead of showing the transition.
    // Deferring to a post-frame callback lets the running screen render
    // first; the isolate-spawn storm still costs the same total time,
    // it just no longer looks like the UI hung before doing anything.
    WidgetsBinding.instance.addPostFrameCallback((_) => _launchStressSubTests());
  }

  Future<void> _launchStressSubTests() async {
    if (!mounted || !_stressFlowActive) return;

    void trackRun(BenchmarkType type, BenchmarkRun run) {
      _stressCancelFns.add(run.cancel);
      _stressProgressSubs.add(run.progress.listen((progress) {
        if (mounted) setState(() => _stressProgress[type] = progress);
      }));
      run.result.then((result) {
        if (!mounted) return;
        setState(() {
          _stressResults[type] = result;
          if (result.peakTemperatureC != null && result.peakTemperatureC! > _stressPeakCpuTemp) {
            _stressPeakCpuTemp = result.peakTemperatureC!;
          }
        });
        _maybeFinishStressTest();
      });
    }

    final intensity = _selectedIntensity;
    AppLogger.instance.info(_logSource, 'Stresstest ("alles tegelijk") gestart, intensiteit ${intensity.label}');

    // CPU, Memory, and Crypto each independently size their worker
    // count as if they were the only test running — reasonable
    // standalone, but summed together for "alles tegelijk" (up to
    // 2.5x the logical processor count on the machine this was tested
    // on) this created severe, sustained CPU oversubscription. Short
    // (Zwaar, ~45s) runs surfaced this as corrupted results (0 Mops/s,
    // 0 MB/s — see BenchmarkService's own safety-timer handling); a
    // full Duurtest run (up to 10 minutes) of that same oversubscription
    // was reported and reproduced as a complete, sustained UI freeze —
    // consistent with the OS scheduler starving this app's own main
    // isolate for extended periods when there are simply far more
    // runnable CPU-bound threads than physical cores to run them on,
    // which no amount of Dart-side timeout/queue handling can fix,
    // since it's the operating system's own thread scheduling, not
    // anything happening inside this app's async logic.
    //
    // Dividing Platform.numberOfProcessors three ways (one share per
    // CPU-bound sub-test) keeps the *combined* total close to what a
    // single standalone test already uses, rather than three full
    // standalone allocations stacked on top of each other. Disk,
    // Network, and the GPU render test aren't included in this split —
    // they aren't CPU-bound worker-isolate tests the way these three
    // are (disk/network are I/O-bound, GPU render runs on the main
    // isolate via Flutter's own rendering, not separate isolates).
    final sharedWorkerCount = max(1, (Platform.numberOfProcessors / 3).floor());

    // Even with the reduced worker counts above, starting all six
    // sub-tests in the exact same millisecond was observed (in testing
    // that reproduced and fixed the freeze above) to still cause a
    // brief burst of contention right at the start — isolate spawning,
    // buffer allocation, and each sub-test's own first sensor read all
    // competing at once — severe enough to trip the safety timers'
    // 3-consecutive-timeout abort within the first ~10 seconds, even
    // though the same tests then ran cleanly for the following
    // several minutes once that initial burst passed (confirmed by
    // Crypto's own multi-minute clean run to a legitimate high-
    // temperature abort in that same test). Staggering each start by
    // a few hundred milliseconds spreads that one-time startup cost
    // out instead of concentrating all of it into the same instant —
    // a small, fixed delay against a run that's several minutes long
    // either way, so this doesn't meaningfully change what's being
    // measured.
    const stagger = Duration(milliseconds: 400);
    Future<void> wait() => Future.delayed(stagger);

    trackRun(BenchmarkType.cpu, _benchmarks.startCpuTest(intensity, workerCountOverride: sharedWorkerCount));
    if (!mounted || !_stressFlowActive) return;
    await wait();

    trackRun(BenchmarkType.memory, _benchmarks.startMemoryTest(intensity, workerCountOverride: sharedWorkerCount));
    if (!mounted || !_stressFlowActive) return;
    await wait();

    trackRun(BenchmarkType.disk, _benchmarks.startDiskTest(intensity));
    if (!mounted || !_stressFlowActive) return;
    await wait();

    trackRun(BenchmarkType.crypto, _benchmarks.startCryptoTest(intensity, workerCountOverride: sharedWorkerCount));
    if (!mounted || !_stressFlowActive) return;
    await wait();

    trackRun(BenchmarkType.network, _benchmarks.startNetworkTest(intensity));
    if (!mounted || !_stressFlowActive) return;
    await wait();

    // GPU render load reuses the exact same ticker/safety-timer as the
    // standalone GPU test (see _startGpuTest below) — only the
    // completion handler (_finishGpuTest) branches differently based on
    // _gpuFeedsStressTest, routing the result here instead of into
    // _lastResult/_screenState.
    _gpuFeedsStressTest = true;
    _startGpuTest(intensity);
  }

  /// Called after every sub-test completes; transitions to the combined
  /// result view once all six have reported in — not on a timer, since
  /// each sub-test's own duration differs (that's expected: whichever
  /// finishes last is usually this machine's bottleneck at this
  /// intensity).
  void _maybeFinishStressTest() {
    if (_stressResults.length < _stressTypes.length) return;
    if (mounted) setState(() => _screenState = _ScreenState.result);
  }

  void _cancelStressTest() {
    for (final cancel in _stressCancelFns) {
      cancel();
    }
    // GPU render load doesn't have its own BenchmarkRun.cancel (it's a
    // Ticker, not a service-backed run) — stop it the same way the
    // standalone GPU test does.
    _gpuCancelled = true;
    _gpuAbortReason = 'geannuleerd door gebruiker';
  }

  // -------------------------------------------------------------------
  // GPU render test: Flutter has no direct GPU-compute API, so this
  // generates real rendering/compositing load (many blurred, animated
  // shapes, repainted every frame via a Ticker) rather than a
  // compute-shader stress test. It's an honest approximation, not a
  // true GPU-compute benchmark — the UI says so, and offers the real
  // thing (glmark2) as a separate "Compute" mode when installed.
  // -------------------------------------------------------------------

  Duration _gpuDurationFor(BenchmarkIntensity intensity) {
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

  int _gpuParticleCountFor(BenchmarkIntensity intensity) {
    switch (intensity) {
      case BenchmarkIntensity.licht:
        return 150;
      case BenchmarkIntensity.gemiddeld:
        return 500;
      case BenchmarkIntensity.zwaar:
        return 1200;
      case BenchmarkIntensity.duurtest:
        return 1200;
    }
  }

  void _startGpuTest(BenchmarkIntensity intensity) {
    // Defensive: if a previous run's ticker somehow wasn't cleaned up
    // yet, dispose it first — TickerProviderStateMixin allows creating
    // multiple tickers over the widget's lifetime, but not two live
    // ones from the same call site simultaneously without leaking.
    _gpuTicker?.stop();
    _gpuTicker?.dispose();
    _gpuTicker = null;

    _gpuDuration = _gpuDurationFor(intensity);
    _gpuParticleCount = _gpuParticleCountFor(intensity);
    _gpuElapsed = Duration.zero;
    _gpuFrameCount = 0;
    _gpuPeakTemp = 0;
    _gpuCancelled = false;
    _gpuAbortReason = null;

    AppLogger.instance.info(_logSource,
        'GPU-test (renderbelasting) gestart: $_gpuParticleCount vormen, ${_gpuDuration.inSeconds}s, intensiteit ${intensity.label}');

    _gpuTicker = createTicker((elapsed) {
      _gpuFrameCount++;
      _gpuElapsed = elapsed;
      if (mounted) setState(() {});
      if (elapsed >= _gpuDuration || _gpuCancelled) {
        _finishGpuTest();
      }
    })
      ..start();

    _gpuSafetyTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final gpus = await _sensors.readGpus();
      if (gpus.isEmpty) return;
      final temp = gpus.first.temperatureC;
      if (temp != null && temp > _gpuPeakTemp) _gpuPeakTemp = temp;
      if (temp != null && temp > 100.0) {
        _gpuCancelled = true;
        _gpuAbortReason = 'GPU-temperatuur te hoog (${temp.toStringAsFixed(0)}°C)';
      }
    });
  }

  void _finishGpuTest() {
    _gpuTicker?.stop();
    _gpuTicker?.dispose();
    _gpuTicker = null;
    _gpuSafetyTimer?.cancel();
    _gpuSafetyTimer = null;

    final fps = _gpuElapsed.inMilliseconds > 0
        ? _gpuFrameCount / (_gpuElapsed.inMilliseconds / 1000)
        : 0.0;

    AppLogger.instance.info(_logSource,
        'GPU-test klaar: ${_gpuCancelled ? 'gestopt (${_gpuAbortReason ?? 'onbekend'})' : 'voltooid'}, '
        '$_gpuFrameCount frames, ${fps.toStringAsFixed(0)} fps gemiddeld, piektemp ${_gpuPeakTemp.toStringAsFixed(0)}°C');

    final result = BenchmarkResult(
      type: BenchmarkType.gpu,
      intensity: _selectedIntensity,
      actualDuration: _gpuElapsed,
      aborted: _gpuCancelled,
      abortReason: _gpuAbortReason,
      score: _gpuCancelled ? null : _gpuFrameCount.toDouble(),
      peakTemperatureC: _gpuPeakTemp > 0 ? _gpuPeakTemp : null,
      details: {
        'modus': 'render',
        'gemiddelde fps': fps.toStringAsFixed(0),
        'vormen': '$_gpuParticleCount',
      },
    );

    _benchmarks.recordResult(result);

    if (_gpuFeedsStressTest) {
      _gpuFeedsStressTest = false;
      if (mounted) {
        setState(() {
          _stressResults[BenchmarkType.gpu] = result;
          if (result.peakTemperatureC != null && result.peakTemperatureC! > _stressPeakGpuTemp) {
            _stressPeakGpuTemp = result.peakTemperatureC!;
          }
        });
      }
      _maybeFinishStressTest();
      return;
    }

    if (mounted) {
      setState(() {
        _lastResult = result;
        _screenState = _ScreenState.result;
      });
    }
  }

  void _backToSelection() {
    setState(() {
      _screenState = _ScreenState.idle;
      _liveProgress = null;
      _lastResult = null;
      _batteryFlowActive = false;
      _batteryProgress = null;
      _batteryResult = null;
      _stressFlowActive = false;
      _stressProgress.clear();
      _stressResults.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    // Debug builds run everything unoptimized (JIT, extra checked-mode
    // assertions, no tree-shaking/AOT codegen) — timing- and
    // throughput-based benchmark numbers from a Debug build are
    // therefore routinely far lower than a Release build on the exact
    // same hardware, and are not comparable to any other result the
    // user (or DarkTask's own history/leaderboard) might show. This
    // banner is the one place that warning is shown, covering every
    // sub-view (selection/running/result) rather than duplicating it
    // in each one, so it can never be missed on one code path.
    if (!kDebugMode) return content;
    return Column(
      children: [
        _buildDebugModeWarning(),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildContent() {
    switch (_screenState) {
      case _ScreenState.idle:
        return _buildSelectionView();
      case _ScreenState.running:
        if (_stressFlowActive) return _buildStressRunningView();
        return _batteryFlowActive ? _buildBatteryRunningView() : _buildRunningView();
      case _ScreenState.result:
        if (_stressFlowActive) return _buildStressResultView();
        return _batteryFlowActive ? _buildBatteryResultView() : _buildResultView();
    }
  }

  Widget _buildDebugModeWarning() {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.warning_amber_rounded, size: 16, color: Colors.black),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Debug-build: deze resultaten zijn onbetrouwbaar en niet vergelijkbaar met een '
              'Release-build — bouw en start DarkTask in Release-modus voor echte metingen.',
              style: TextStyle(color: Colors.black, fontSize: 11.5, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // --- Selection view ---------------------------------------------------

  Widget _buildSelectionView() {
    // glmark2 runs its own fixed scene suite with no adjustable
    // intensity — showing the selector there would be misleading,
    // since changing it would do nothing. OpenCL's compute test, by
    // contrast, genuinely uses intensity for dispatch duration/load
    // (see BenchmarkService._openClIterationsFor), so it stays visible
    // on Windows.
    final showIntensity = !(_selectedType == BenchmarkType.gpu &&
        _gpuMode == GpuTestMode.compute &&
        !Platform.isWindows);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Benchmarks',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Test stopt automatisch bij te hoge temperaturen (CPU/Memory/Crypto > '
                '${SettingsService.instance.current.cpuSafetyCutoffC.toStringAsFixed(0)}°C, GPU > 100°C).',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: BenchmarkType.values.map((type) => _buildTypeCard(type)).toList(),
              ),
              const SizedBox(height: 20),
              if (showIntensity) ...[
                const Text('Intensiteit', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                SegmentedButton<BenchmarkIntensity>(
                  segments: BenchmarkIntensity.values
                      .map((i) => ButtonSegment(value: i, label: Text(i.label)))
                      .toList(),
                  selected: {_selectedIntensity},
                  onSelectionChanged: (s) => setState(() => _selectedIntensity = s.first),
                ),
                const SizedBox(height: 8),
              ],
              if (_selectedType == BenchmarkType.gpu) _buildGpuModeSelector(),
              if (_selectedType == BenchmarkType.disk) _buildDiskTargetSelector(),
              if (_selectedType == BenchmarkType.memory)
                _buildInfoNote(
                  'Kopieert herhaaldelijk een 64 MiB-buffer — ruim groter dan de CPU-cache, '
                  'dus dit meet echte RAM-bandbreedte, niet cachesnelheid.',
                ),
              if (_selectedType == BenchmarkType.network)
                _buildInfoNote(
                  'Meet TCP-doorvoer via loopback (127.0.0.1) — de snelheid van dit apparaat '
                  'zelf, niet van je LAN of internetverbinding (er is geen tweede apparaat '
                  'om tegen te testen).',
                ),
              if (_selectedType == BenchmarkType.crypto)
                _buildInfoNote(
                  'SHA-256-doorvoer via package:crypto, een echte hash-implementatie — een '
                  'proxy voor workloads als back-upverificatie, TLS of schijfversleuteling.',
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _typeColor(_selectedType)),
                onPressed:
                    (_selectedType == BenchmarkType.gpu && _gpuMode == GpuTestMode.compute && _computeAvailable != true)
                        ? null
                        : _startSelectedTest,
                icon: const Icon(Icons.play_arrow),
                label: Text('Start ${_typeLabel(_selectedType)}-test'),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              // Added 2026-09-22: the report combines system info + a live
              // sensor snapshot + the FULL benchmark history — it isn't
              // tied to any one test result. The original button only
              // lived inside _buildScoreComparisonChart(), which only
              // renders after an individual (non-disk, non-GPU-compute)
              // test finishes — invisible from this idle screen, from the
              // disk-test result, and from the "alles tegelijk"/battery
              // result views entirely. Duplicated here so it's reachable
              // the moment the Benchmarks tab opens, regardless of which
              // test flow (if any) the user has run.
              Center(
                child: TextButton.icon(
                  onPressed: _generatingReport ? null : _exportReport,
                  icon: _generatingReport
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf_outlined, size: 16),
                  label: Text(
                    _generatingReport ? 'Rapport genereren...' : 'Rapport exporteren',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildStressTestCard(),
              if (_batteryChecked && _batteryPresent) ...[
                const SizedBox(height: 12),
                _buildBatteryCard(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoNote(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildGpuModeSelector() {
    // "Compute" is the same UI concept on both platforms — a real,
    // external/native GPU-load mechanism rather than the built-in
    // Flutter render approximation — backed by whichever one actually
    // exists on this OS. See OpenClComputeReader's class doc for why
    // Windows uses OpenCL specifically, never Direct3D.
    final computeLabel = Platform.isWindows ? 'Compute (OpenCL)' : 'Compute (glmark2)';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          const Text('Modus', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          SegmentedButton<GpuTestMode>(
            segments: [
              const ButtonSegment(value: GpuTestMode.render, label: Text('Render (ingebouwd)')),
              ButtonSegment(
                value: GpuTestMode.compute,
                label: Text(computeLabel),
                enabled: _computeAvailable != false,
              ),
            ],
            selected: {_gpuMode},
            onSelectionChanged: (s) => setState(() => _gpuMode = s.first),
          ),
          const SizedBox(height: 8),
          if (_gpuMode == GpuTestMode.render) ...[
            _buildInfoNote(
              'Genereert renderbelasting (geanimeerde vormen) — geen compute-shaderbenchmark, '
              'maar wel echte GPU-temperatuur/belasting-meting.',
            ),
            if (Platform.isWindows && _openClGpuDevices.length > 1) ...[
              const SizedBox(height: 4),
              _buildInfoNote(
                'Let op: op een systeem met meerdere GPU\'s (bijv. een losse kaart plus een '
                'ingebouwde Intel/AMD-GPU) gebruikt deze rendertest altijd de ene GPU die Windows '
                'aan de hele app toewijst — dit kan niet per test worden gewisseld. Wil je specifiek '
                'de andere kaart testen? Stel de voorkeurs-GPU voor DarkTask in via Windows\' eigen '
                'grafische instellingen, of gebruik hierboven de Compute-modus (die kan wél per kaart '
                'kiezen).',
              ),
              const SizedBox(height: 6),
              Center(
                child: OutlinedButton.icon(
                  onPressed: _openWindowsGraphicsSettings,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Windows grafische instellingen openen'),
                ),
              ),
            ],
          ] else if (_computeAvailable == false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                children: [
                  Text(
                    Platform.isWindows
                        ? 'OpenCL is niet beschikbaar op dit systeem — meestal betekent dit dat de '
                            'GPU-fabrikant geen OpenCL-driver heeft geïnstalleerd. Dit is een echte '
                            'compute-kernelbenchmark, geen ingebouwde benadering, en kan niet vanuit de '
                            'app worden geïnstalleerd (het zit in de grafische driver zelf).'
                        : 'glmark2 is niet geïnstalleerd — dit is een echte OpenGL-benchmark, '
                            'geen ingebouwde benadering.',
                    style: TextStyle(color: _warningTextColor(context), fontSize: 11.5),
                    textAlign: TextAlign.center,
                  ),
                  if (!Platform.isWindows) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _installGlmark2,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('glmark2 installeren'),
                    ),
                  ],
                ],
              ),
            )
          else if (_computeAvailable == true) ...[
            _buildInfoNote(
              Platform.isWindows
                  ? 'OpenCL-GPU gevonden — draait herhaalde compute-kernel-dispatches en rapporteert de doorvoer.'
                  : 'glmark2 gevonden — draait de standaard OpenGL-scenetest en rapporteert de score.',
            ),
            if (Platform.isWindows && _openClGpuDevices.length > 1) _buildOpenClDevicePicker(),
          ],
        ],
      ),
    );
  }

  /// Only shown when OpenCL sees more than one GPU device — lets the
  /// user pick exactly which physical card the compute test runs on.
  /// Unlike the render mode above, this selection genuinely takes
  /// effect per test: OpenClComputeReader tears down and rebuilds its
  /// context for whichever (platform, device) pair is passed in.
  Widget _buildOpenClDevicePicker() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          const Text('GPU voor deze test', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          DropdownButton<OpenClGpuDevice>(
            value: _selectedOpenClDevice,
            isDense: true,
            items: _openClGpuDevices
                .map((d) => DropdownMenuItem(value: d, child: Text(d.name, style: const TextStyle(fontSize: 13))))
                .toList(),
            onChanged: (d) {
              if (d != null) setState(() => _selectedOpenClDevice = d);
            },
          ),
        ],
      ),
    );
  }

  /// Windows-only convenience: opens the OS's own per-app graphics
  /// preference page, so the user can force DarkTask's render test
  /// onto a specific GPU — the practical workaround for the render
  /// test's architectural single-GPU-per-app-lifetime limitation
  /// (see the info note next to this button). Best-effort: if
  /// explorer.exe or the ms-settings URI handler isn't available for
  /// some reason, this just logs and does nothing rather than
  /// crashing the app over a convenience shortcut.
  Future<void> _openWindowsGraphicsSettings() async {
    try {
      await Process.start('explorer.exe', ['ms-settings:display-advancedgraphics']);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon Windows grafische instellingen niet openen: $e');
    }
  }

  Future<void> _installGlmark2() async {
    final success = await _benchmarks.installGlmark2();
    if (mounted) {
      setState(() => _computeAvailable = success);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'glmark2 geïnstalleerd' : 'Installeren van glmark2 mislukt — zie Log')),
      );
    }
  }

  Widget _buildDiskTargetSelector() {
    // Lists every currently mounted filesystem, not just removable
    // ones — DarkTask doesn't yet detect the sysfs "removable" flag
    // per device, so a USB drive is picked the same way as any other
    // disk here: by its mount point.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          const Text('Doelschijf', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          DropdownButton<String?>(
            value: _selectedDiskMountPoint,
            isDense: true,
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Systeemschijf (standaard, tijdelijke map)', overflow: TextOverflow.ellipsis),
              ),
              for (final d in _disks)
                DropdownMenuItem(
                  value: d.mountPoint,
                  child: Text('${d.mountPoint} (${d.device})', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => _selectedDiskMountPoint = value),
          ),
        ],
      ),
    );
  }

  Widget _buildStressTestCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _startStressTest,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.deepOrangeAccent.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.local_fire_department, color: Colors.deepOrangeAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Stresstest — alles tegelijk', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  Text(
                    'CPU, Memory, Disk, Crypto, Network en GPU gelijktijdig belast, op de hierboven '
                    'gekozen intensiteit — voor het vergelijken van complete systemen onder volledige last.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _startBatteryTest,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade700),
        ),
        child: Row(
          children: [
            Icon(Icons.battery_std, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Batterijtest', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  Text(
                    '3 minuten meten onder lichte belasting — vereist dat de oplader is losgekoppeld.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }

  /// A tappable card for one test type — icon and border tinted in that
  /// metric's identity color, filled solid when selected. Replaces the
  /// old plain SegmentedButton<BenchmarkType>: same selection behavior,
  /// but each option now carries its own color and a bigger icon
  /// instead of being a same-colored text-only segment.
  Widget _buildTypeCard(BenchmarkType type) {
    final selected = type == _selectedType;
    final color = _typeColor(type);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _selectedType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? color : Colors.grey.shade700, width: selected ? 2 : 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_typeIcon(type), color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              _typeLabel(type),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? color : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Running view -------------------------------------------------------

  Widget _buildRunningView() {
    if (_selectedType == BenchmarkType.gpu && _gpuMode == GpuTestMode.render) {
      return _buildGpuRunningView();
    }

    final progress = _liveProgress;
    final fraction = progress?.fractionComplete ?? 0;
    final color = _typeColor(_selectedType);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${_typeLabel(_selectedType)}-test loopt...', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 24),
              // Circular ring with the live percentage and test icon in
              // the center — replaces the flat LinearProgressIndicator
              // with something that reads at a glance like a real
              // instrument dial, not just a loading bar.
              SizedBox(
                width: 160,
                height: 160,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: fraction, end: fraction),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                      builder: (context, animatedFraction, _) => SizedBox(
                        width: 160,
                        height: 160,
                        child: CircularProgressIndicator(
                          value: animatedFraction,
                          strokeWidth: 10,
                          backgroundColor: color.withOpacity(0.12),
                          valueColor: AlwaysStoppedAnimation(color),
                        ),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_typeIcon(_selectedType), color: color, size: 26),
                        const SizedBox(height: 4),
                        Text(
                          '${(fraction * 100).toStringAsFixed(0)}%',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(progress?.statusText ?? 'Bezig met starten...',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
              if (progress?.currentTemperatureC != null) ...[
                const SizedBox(height: 6),
                Text('${progress!.currentTemperatureC!.toStringAsFixed(0)}°C',
                    style: TextStyle(color: _warningTextColor(context), fontSize: 12)),
              ],
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _cancelRunningTest,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stoppen'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGpuRunningView() {
    final fraction = _gpuDuration.inMilliseconds > 0
        ? (_gpuElapsed.inMilliseconds / _gpuDuration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return Column(
      children: [
        Expanded(
          child: ClipRect(
            child: CustomPaint(
              painter: _GpuLoadPainter(elapsed: _gpuElapsed, particleCount: _gpuParticleCount),
              size: Size.infinite,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: fraction, end: fraction),
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOut,
                builder: (context, animatedFraction, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: animatedFraction,
                    minHeight: 6,
                    color: _typeColor(BenchmarkType.gpu),
                    backgroundColor: _typeColor(BenchmarkType.gpu).withOpacity(0.15),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(fraction * 100).toStringAsFixed(0)}% · $_gpuFrameCount frames'
                '${_gpuPeakTemp > 0 ? ' · piek ${_gpuPeakTemp.toStringAsFixed(0)}°C' : ''}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _cancelRunningTest,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stoppen'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBatteryRunningView() {
    final progress = _batteryProgress;
    final fraction = progress?.fractionComplete ?? 0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Batterijtest loopt...', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 24),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: fraction, end: fraction),
                duration: const Duration(milliseconds: 400),
                builder: (context, animatedFraction, _) => SizedBox(
                  width: 140,
                  height: 140,
                  child: CircularProgressIndicator(
                    value: animatedFraction,
                    strokeWidth: 8,
                    backgroundColor: Colors.grey.withOpacity(0.15),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(progress?.statusText ?? 'Bezig met starten...',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => _cancelBatteryRun?.call(),
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stoppen'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBatteryResultView() {
    final result = _batteryResult;
    if (result == null) return _buildSelectionView();
    final statusColor = result.aborted ? _abortedIconColor(context) : _successIconColor(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(result.aborted ? Icons.warning_amber_rounded : Icons.battery_std, size: 48, color: statusColor),
              const SizedBox(height: 12),
              Text('Batterijtest ${result.aborted ? 'gestopt' : 'voltooid'}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              if (result.aborted)
                Text(result.abortReason ?? 'onbekende reden', textAlign: TextAlign.center)
              else ...[
                Text('${result.startCapacityPercent}% → ${result.endCapacityPercent}%',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                if (result.averagePowerWatts != null) ...[
                  Text('≈ ${result.averagePowerWatts!.toStringAsFixed(1)} W gemiddeld verbruik',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  if (result.estimatedRuntimeHours != null)
                    Text('Volle accu: ≈ ${result.estimatedRuntimeHours!.toStringAsFixed(1)} uur bij deze belasting',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  if (result.percentPerHour != null)
                    Text('≈ ${result.percentPerHour!.toStringAsFixed(1)}%/uur',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  if (result.methodNote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(result.methodNote!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5)),
                    ),
                ] else if (result.percentPerHour != null)
                  Text('≈ ${result.percentPerHour!.toStringAsFixed(1)}%/uur bij deze belasting',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                if (result.averagePowerWatts == null && result.percentPerHour == null)
                  Text(
                    'Te kort voor een betrouwbare schatting: de batterij meldt alleen hele procenten en '
                    'er zijn te weinig stappen gezien.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5),
                  ),
              ],
              const SizedBox(height: 20),
              OutlinedButton(onPressed: _backToSelection, child: const Text('Terug')),
            ],
          ),
        ),
      ),
    );
  }

  // --- Stress test views ("alles tegelijk") ------------------------------

  Widget _buildStressRunningView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.local_fire_department, color: Colors.deepOrangeAccent, size: 40),
              const SizedBox(height: 8),
              Text('Stresstest loopt — alles tegelijk', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('${_stressResults.length} / ${_stressTypes.length} voltooid',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: _stressTypes.map(_buildStressTile).toList(),
              ),
              if (_stressPeakCpuTemp > 0 || _stressPeakGpuTemp > 0) ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 16,
                  alignment: WrapAlignment.center,
                  children: [
                    if (_stressPeakCpuTemp > 0)
                      Text('CPU piek: ${_stressPeakCpuTemp.toStringAsFixed(0)}°C',
                          style: TextStyle(color: _warningTextColor(context), fontWeight: FontWeight.w600)),
                    if (_stressPeakGpuTemp > 0)
                      Text('GPU piek: ${_stressPeakGpuTemp.toStringAsFixed(0)}°C',
                          style: TextStyle(color: _warningTextColor(context), fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _cancelRunningTest,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Alles stoppen'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One tile per sub-test in the stress grid. GPU is driven by the
  /// render-load Ticker (_gpuElapsed/_gpuDuration), not a
  /// BenchmarkProgress stream like the other five, so its fraction is
  /// computed separately here rather than reading _stressProgress.
  Widget _buildStressTile(BenchmarkType type) {
    final color = _typeColor(type);
    final done = _stressResults.containsKey(type);
    double fraction;
    if (type == BenchmarkType.gpu) {
      fraction = _gpuDuration.inMilliseconds > 0
          ? (_gpuElapsed.inMilliseconds / _gpuDuration.inMilliseconds).clamp(0.0, 1.0)
          : 0.0;
    } else {
      fraction = _stressProgress[type]?.fractionComplete ?? 0;
    }
    final statusText = done ? 'Klaar' : '${(fraction * 100).toStringAsFixed(0)}%';

    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: done ? color : color.withOpacity(0.3), width: done ? 2 : 1),
        color: done ? color.withOpacity(0.1) : Colors.transparent,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(done ? Icons.check_circle : _typeIcon(type), color: color, size: 22),
          const SizedBox(height: 6),
          Text(_typeLabel(type), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              color: color,
              backgroundColor: color.withOpacity(0.12),
            ),
          ),
          const SizedBox(height: 4),
          Text(statusText, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildStressResultView() {
    final anyAborted = _stressResults.values.any((r) => r.aborted);
    final statusColor = anyAborted ? _abortedIconColor(context) : _successIconColor(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(anyAborted ? Icons.warning_amber_rounded : Icons.check_circle,
                    size: 44, color: statusColor),
                const SizedBox(height: 10),
                Text('Stresstest voltooid', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Intensiteit: ${_selectedIntensity.label}',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                if (_stressPeakCpuTemp > 0 || _stressPeakGpuTemp > 0) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 16,
                    alignment: WrapAlignment.center,
                    children: [
                      if (_stressPeakCpuTemp > 0)
                        Text('CPU piek: ${_stressPeakCpuTemp.toStringAsFixed(0)}°C',
                            style: TextStyle(fontWeight: FontWeight.w600, color: _warningTextColor(context))),
                      if (_stressPeakGpuTemp > 0)
                        Text('GPU piek: ${_stressPeakGpuTemp.toStringAsFixed(0)}°C',
                            style: TextStyle(fontWeight: FontWeight.w600, color: _warningTextColor(context))),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                for (final type in _stressTypes)
                  if (_stressResults[type] case final result?)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(_typeIcon(type), color: _typeColor(type), size: 18),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 70,
                            child: Text(_typeLabel(type),
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                          Expanded(
                            child: Text(
                              result.summaryLine,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: result.aborted ? _warningTextColor(context) : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(onPressed: _backToSelection, child: const Text('Terug')),
                    const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.deepOrangeAccent),
                      onPressed: _startStressTest,
                      child: const Text('Opnieuw'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Result view ----------------------------------------------------

  Widget _buildResultView() {
    final result = _lastResult;
    if (result == null) return _buildSelectionView();
    final typeColor = _typeColor(result.type);
    final statusColor = result.aborted ? _abortedIconColor(context) : _successIconColor(context);
    final scalingRatio =
        result.type == BenchmarkType.cpu && !result.aborted ? _benchmarks.cpuScalingRatio() : null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Big colored icon badge: the test-type icon, ringed in
                // its identity color, with a small status badge
                // (check/warning) overlaid — carries the same visual
                // language as the selection cards through to the result.
                SizedBox(
                  width: 84,
                  height: 84,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: typeColor.withOpacity(0.15),
                          border: Border.all(color: typeColor, width: 2),
                        ),
                        child: Icon(_typeIcon(result.type), color: typeColor, size: 36),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context).scaffoldBackgroundColor,
                          ),
                          child: Icon(
                            result.aborted ? Icons.warning_amber_rounded : Icons.check_circle,
                            size: 22,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '${_typeLabel(result.type)}-test ${result.aborted ? 'gestopt' : 'voltooid'}'
                  '${result.type == BenchmarkType.gpu && result.details['modus'] == 'compute' ? ' (compute)' : ''}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(result.summaryLine,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: typeColor),
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                if (result.peakTemperatureC != null)
                  Text('Piektemperatuur: ${result.peakTemperatureC!.toStringAsFixed(0)}°C',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                if (result.throttleDetected)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('⚠ Mogelijke thermal throttling gedetecteerd tijdens de test',
                        style: TextStyle(color: _warningTextColor(context), fontSize: 12.5)),
                  ),
                if (result.details['voeding'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Voeding: ${result.details['voeding']} · Energieplan: ${result.details['energieplan'] ?? 'onbekend'}',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (result.details['let op'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('⚠ ${result.details['let op']}',
                        style: TextStyle(color: _warningTextColor(context), fontSize: 12.5),
                        textAlign: TextAlign.center),
                  ),
                if (scalingRatio != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Multi-core schaling: ${(scalingRatio * 100).toStringAsFixed(0)}% per-core-efficiëntie '
                      '(vs. eerdere single-core run deze sessie)',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (!result.aborted) ...[
                  const SizedBox(height: 16),
                  if (result.type == BenchmarkType.disk)
                    _buildDiskTable(result)
                  else if (!(result.type == BenchmarkType.gpu && result.details['modus'] == 'compute'))
                    _buildScoreComparisonChart(result),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(onPressed: _backToSelection, child: const Text('Terug')),
                    const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: typeColor),
                      onPressed: _startSelectedTest,
                      child: const Text('Opnieuw'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// KDiskMark-style clean table: sequential and random-4K read/write
  /// speeds plus IOPS, pulled straight from the result's own details
  /// map (already computed as real numbers in BenchmarkService, not
  /// invented here).
  Widget _buildDiskTable(BenchmarkResult result) {
    final details = result.details;
    final color = _typeColor(BenchmarkType.disk);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Table(
        columnWidths: const {0: FlexColumnWidth(1.3), 1: FlexColumnWidth(1)},
        children: [
          _diskTableRow('Sequentieel', 'MB/s', 'IOPS', isHeader: true),
          _diskTableRow(
            'Lezen',
            details['leessnelheid']?.replaceAll(' MB/s', '') ?? '—',
            '${details['lees-IOPS (16 MiB)'] ?? '—'} @16MiB',
          ),
          _diskTableRow(
            'Schrijven',
            details['schrijfsnelheid']?.replaceAll(' MB/s', '') ?? '—',
            '${details['schrijf-IOPS (16 MiB)'] ?? '—'} @16MiB',
          ),
          _diskTableRow('Random 4K (QD1)', 'MB/s', 'IOPS', isHeader: true),
          _diskTableRow(
            'Lezen',
            details['random leessnelheid (4K)']?.replaceAll(' MB/s', '') ?? '—',
            details['random lees-IOPS (4K, QD1)'] ?? '—',
          ),
          _diskTableRow(
            'Schrijven',
            details['random schrijfsnelheid (4K)']?.replaceAll(' MB/s', '') ?? '—',
            details['random schrijf-IOPS (4K, QD1)'] ?? '—',
          ),
        ],
      ),
    );
  }

  TableRow _diskTableRow(String label, String col1, String col2, {bool isHeader = false}) {
    final style = isHeader
        ? TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)
        : const TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    return TableRow(
      decoration: isHeader
          ? BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2))))
          : null,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          child: Text(label, style: style),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          child: Text(col1, style: style, textAlign: TextAlign.right),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          child: Text(col2, style: style, textAlign: TextAlign.right),
        ),
      ],
    );
  }

  /// HardInfo-style horizontal bar chart — but honestly comparing the
  /// current run against your OWN earlier runs on this same machine
  /// (persisted across app restarts — see BenchmarkHistoryStore — not
  /// just this session), not against an external reference database
  /// we don't have real data for.
  Widget _buildScoreComparisonChart(BenchmarkResult result) {
    final history = _benchmarks.persistentHistoryFor(result.type, _selectedIntensity);
    if (history.isEmpty) return const SizedBox.shrink();

    final entries = <BarChartEntry>[
      for (var i = 0; i < history.length; i++)
        BarChartEntry(
          label: i == history.length - 1 ? 'Nu' : 'Run ${i + 1}',
          value: history[i].score ?? 0,
          isCurrent: i == history.length - 1,
        ),
    ];

    final String unit;
    switch (result.type) {
      case BenchmarkType.cpu:
        unit = ' Mops/s';
        break;
      case BenchmarkType.memory:
        unit = ' GB/s';
        break;
      case BenchmarkType.network:
        unit = ' MB/s';
        break;
      case BenchmarkType.crypto:
        unit = ' MB/s';
        break;
      case BenchmarkType.gpu:
        unit = ' fps';
        break;
      case BenchmarkType.disk:
        unit = ' MB/s'; // unreachable here — disk uses _buildDiskTable instead
        break;
    }
    final color = _typeColor(result.type);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                history.length > 1
                    ? 'Vergeleken met je eerdere runs op deze machine (zelfde intensiteit)'
                    : 'Nog geen eerdere run om mee te vergelijken',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton.icon(
              onPressed: _generatingReport ? null : _exportReport,
              icon: _generatingReport
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: Text(
                _generatingReport ? 'Rapport genereren...' : 'Rapport exporteren',
                style: const TextStyle(fontSize: 12),
              ),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            ),
            TextButton.icon(
              onPressed: _exportHistoryCsv,
              icon: const Icon(Icons.save_alt, size: 16),
              label: const Text('Exporteer geschiedenis (CSV)', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        BenchmarkBarChart(
          entries: entries,
          color: color,
          formatValue: (v) => '${v.toStringAsFixed(1)}$unit',
        ),
      ],
    );
  }

  /// Generates the combined HTML + colored PDF report (system specs, a
  /// live sensor snapshot, and the full benchmark history — see
  /// [ReportService]'s own class doc) and writes both to disk. Same
  /// save-location/feedback pattern as [_exportHistoryCsv] and
  /// LogViewerScreen._saveToFile: Downloads if available, else the
  /// app's documents folder, with a SnackBar confirming exactly where
  /// both files landed.
  Future<void> _exportReport() async {
    setState(() => _generatingReport = true);
    try {
      final paths = await ReportService(_sensors).generate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rapport opgeslagen: ${paths.htmlPath} en ${paths.pdfPath}'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Kon rapport niet genereren: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rapport genereren mislukt: $e'), duration: const Duration(seconds: 4)),
        );
      }
    } finally {
      if (mounted) setState(() => _generatingReport = false);
    }
  }

  /// Writes the FULL persisted benchmark history (every type/intensity
  /// ever run on this machine, not just the type currently shown) to a
  /// CSV file — one row per run — so it can be handed to a customer as
  /// a before/after comparison or opened in a spreadsheet. Same
  /// save-location/feedback pattern as LogViewerScreen._saveToFile:
  /// Downloads if available, else the app's documents folder, with a
  /// SnackBar confirming exactly where it landed.
  Future<void> _exportHistoryCsv() async {
    try {
      final csv = BenchmarkHistoryStore.instance.toCsv();
      final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final fileName = 'darktask_benchmarks_$timestamp.csv';

      Directory? targetDir;
      try {
        targetDir = await getDownloadsDirectory();
      } catch (_) {
        targetDir = null;
      }
      targetDir ??= await getApplicationDocumentsDirectory();

      final file = File('${targetDir.path}/$fileName');
      await file.writeAsString(csv);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Benchmarkgeschiedenis geëxporteerd: ${file.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Kon benchmarkgeschiedenis niet exporteren: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exporteren mislukt: $e'), duration: const Duration(seconds: 4)),
        );
      }
    }
  }
}

/// Renders a field of animated, blurred, overlapping circles — genuine
/// compositing/rendering work for the GPU, scaled by particleCount.
class _GpuLoadPainter extends CustomPainter {
  final Duration elapsed;
  final int particleCount;

  _GpuLoadPainter({required this.elapsed, required this.particleCount});

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsed.inMilliseconds / 1000.0;
    final rnd = Random(42); // fixed seed so the pattern is deterministic per index

    for (var i = 0; i < particleCount; i++) {
      final phase = rnd.nextDouble() * pi * 2;
      final speed = 0.4 + rnd.nextDouble() * 0.8;
      final radius = 6.0 + rnd.nextDouble() * 24.0;
      final baseX = rnd.nextDouble() * size.width;
      final baseY = rnd.nextDouble() * size.height;

      final x = (baseX + sin(t * speed + phase) * 80) % size.width;
      final y = (baseY + cos(t * speed + phase * 1.3) * 80) % size.height;

      final hue = (i * 37 + t * 30) % 360;
      final color = HSVColor.fromAHSV(0.35, hue, 0.8, 1.0).toColor();

      final paint = Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GpuLoadPainter oldDelegate) => true;
}
