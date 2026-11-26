import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../core/logging/app_logger.dart';
import '../../core/models/cpu_sample.dart';
import '../../core/models/gpu_sample.dart';
import '../../core/models/load_sample.dart';
import '../../core/models/memory_sample.dart';
import '../../core/models/network_sample.dart';
import '../../core/models/process_info.dart';
import '../../core/theming/graph_palette.dart';
import '../../services/process_service.dart';
import '../../services/sensors/system_sensor_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/horizontal_spark_bars.dart';
import '../../widgets/multi_line_chart.dart';
import '../../widgets/process_table.dart';
import '../../widgets/vertical_gauge_bar.dart';

const _logSource = 'MonitoringDashboard';
const int _historyLength = 60; // 60 samples of history per graph

class MonitoringDashboard extends StatefulWidget {
  /// Whether this screen is the currently visible tab. When false, the
  /// polling timer is paused (state/history is kept, just not updated)
  /// so an offscreen tab doesn't keep rebuilding dozens of CustomPaint
  /// widgets every second in the background — multiple screens doing
  /// that simultaneously under IndexedStack is what was triggering a
  /// long-standing Flutter framework semantics-tree assertion crash.
  final bool active;

  /// Shared across every screen (owned by the top-level app shell) so
  /// that state like GPU diagnostics, the persistent intel_gpu_top
  /// process, and fdinfo/RAPL delta caches survives tab switches
  /// instead of being torn down and rebuilt from scratch every time
  /// this screen is navigated away from and back to.
  final SystemSensorService sensors;

  const MonitoringDashboard({
    super.key,
    this.active = true,
    required this.sensors,
  });

  @override
  State<MonitoringDashboard> createState() => _MonitoringDashboardState();
}

class _MonitoringDashboardState extends State<MonitoringDashboard> {
  SystemSensorService get _sensors => widget.sensors;
  GraphColorScheme get _colors => GraphColorScheme.fromSettings(SettingsService.instance.current);
  double get _glow => SettingsService.instance.current.glowIntensity;
  final ProcessService _processService = ProcessService();
  Timer? _pollTimer;

  final Queue<double> _cpuHistory = Queue<double>();
  final Queue<double> _cpuTempHistory = Queue<double>();
  final Queue<double> _cpuKernelHistory = Queue<double>();
  final Queue<double> _cpuPowerHistory = Queue<double>();
  final Queue<double> _memHistory = Queue<double>();
  final Queue<double> _networkRateHistory = Queue<double>();
  final Queue<double> _diskActivityHistory = Queue<double>();
  double? _diskActivityPercent;
  // Keyed by GpuSample.id, since a system can have several GPUs
  // (e.g. an Intel iGPU plus a discrete AMD/NVIDIA card) at once.
  final Map<String, Queue<double>> _gpuHistories = {};
  final Map<String, Queue<double>> _gpuTempHistories = {};

  CpuSample _cpu = CpuSample.empty();
  MemorySample _mem = MemorySample.empty();
  List<GpuSample> _gpus = [];
  List<NetworkSample> _networks = [];
  LoadSample _load = LoadSample.empty();
  List<ProcessInfo> _processes = [];
  double? _cpuPowerWatts;

  bool _firstSampleDiscarded = false;

  @override
  void initState() {
    super.initState();
    // Starts from the "empty" defaults above (0%, no GPUs, ...) — this
    // screen used to also be seedable with already-warmed values from
    // the app's old splash screen, now removed (see DarkTaskApp's doc
    // in app.dart for why). _startPolling() below fires this screen's
    // own first poll immediately, so those placeholders are only ever
    // visible for the brief moment until that first Future.wait
    // resolves — typically well under a second now that none of the
    // individual reads it's made of block on PowerShell/LibreHardware-
    // Monitor cold-start any more.
    SettingsService.instance.addListener(_onSettingsChanged);
    if (widget.active) _startPolling();
  }

  @override
  void didUpdateWidget(covariant MonitoringDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _startPolling();
    } else if (!widget.active && oldWidget.active) {
      _stopPolling();
    }
  }

  /// Restarts the poll timer with the current interval whenever a
  /// setting changes — most relevantly pollIntervalSeconds. Cheap to
  /// call even when the change is unrelated to polling, since it's
  /// just re-reading the same setting and re-scheduling the timer.
  void _onSettingsChanged() {
    if (widget.active) _startPolling();
  }

  void _startPolling() {
    final intervalSeconds = SettingsService.instance.current.pollIntervalSeconds;
    _pollTimer?.cancel();
    if (intervalSeconds == 0) {
      // Paused: still do a single poll so the screen isn't blank right
      // after unpausing-then-repausing, but don't schedule a repeat.
      AppLogger.instance.info(_logSource, 'Dashboard gepauzeerd (geen automatische verversing)');
      _poll();
      return;
    }
    final interval = Duration(seconds: intervalSeconds);
    AppLogger.instance.info(_logSource, 'Dashboard started, polling every ${interval.inSeconds}s');
    _pollTimer = Timer.periodic(interval, (_) => _poll());
    _poll();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    // Note: does NOT call _sensors.disposeIntelGpuTop() — `sensors` is
    // now shared across all screens (owned by the app shell), so
    // stopping the background GPU tool here would kill it out from
    // under whichever screen is navigated to next. The shell disposes
    // it once, when the whole app closes.
    SettingsService.instance.removeListener(_onSettingsChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  bool _pollInFlight = false;

  Future<void> _poll() async {
    // Without this guard, if a poll (especially the GPU/fdinfo scan)
    // ever takes longer than the 1s timer interval, the next tick would
    // start a second overlapping poll on top of it — and once that
    // starts happening, scans keep piling up and the app gets
    // progressively slower rather than recovering.
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      await _doPoll();
    } finally {
      _pollInFlight = false;
    }
  }

  DateTime? _lastProcessPoll;
  static const _processPollInterval = Duration(seconds: 3);

  Future<void> _doPoll() async {
    // These seven reads don't depend on each other's results, so they're
    // fired concurrently rather than one at a time — the previous
    // sequential-await version meant every tick took the SUM of all
    // seven readers' latencies (CPU/memory/battery FFI calls, GPU and
    // disk-activity native+PowerShell paths, network counters, ...)
    // instead of just the slowest one. Even where two reads both end up
    // going through the same persistent PowerShell session (see
    // PowerShellSession's own doc on this), issuing them together still
    // avoids paying Dart's own await/microtask round-trip overhead
    // between each one — same reasoning as the splash screen's warm-up
    // in app.dart, which already reads its sensors this way.
    final results = await Future.wait<dynamic>([
      _sensors.readCpu(),
      _sensors.readMemory(),
      _sensors.readGpus(),
      _sensors.readNetwork(),
      _sensors.readLoad(),
      _sensors.readCpuPowerWatts(),
      _sensors.readDiskActivity(),
    ]);
    final cpu = results[0] as CpuSample;
    final mem = results[1] as MemorySample;
    final gpus = results[2] as List<GpuSample>;
    final networks = results[3] as List<NetworkSample>;
    final load = results[4] as LoadSample;
    final cpuPower = results[5] as double?;
    final diskActivity = results[6] as double?;

    // Same reasoning as before: `ps` is a process spawn, and the top-N
    // list doesn't need sub-3-second resolution to be useful.
    List<ProcessInfo> processes = _processes;
    final lastProcessPoll = _lastProcessPoll;
    if (lastProcessPoll == null ||
        DateTime.now().difference(lastProcessPoll) >= _processPollInterval) {
      processes = await _processService.listProcesses();
      _lastProcessPoll = DateTime.now();
    }

    // The first /proc/stat read has no prior snapshot to diff against,
    // so its load value is meaningless — skip pushing it into history.
    if (!_firstSampleDiscarded) {
      _firstSampleDiscarded = true;
      if (mounted) {
        setState(() {
          _cpu = cpu;
          _mem = mem;
          _gpus = gpus;
          _networks = networks;
          _load = load;
          _processes = processes;
          _cpuPowerWatts = cpuPower;
          _diskActivityPercent = diskActivity;
        });
      }
      return;
    }

    _pushHistory(_cpuHistory, cpu.overallLoadPercent);
    _pushHistory(_memHistory, mem.usedPercent);
    if (cpu.temperatureC != null) _pushHistory(_cpuTempHistory, cpu.temperatureC!);
    _pushHistory(_cpuKernelHistory, cpu.systemLoadPercent);
    if (cpuPower != null) _pushHistory(_cpuPowerHistory, cpuPower);
    if (diskActivity != null) _pushHistory(_diskActivityHistory, diskActivity);
    if (networks.isNotEmpty) {
      _pushHistory(_networkRateHistory, networks.first.rxBytesPerSec + networks.first.txBytesPerSec);
    }
    for (final gpu in gpus) {
      if (gpu.loadPercent != null) {
        final history = _gpuHistories.putIfAbsent(gpu.id, () => Queue<double>());
        _pushHistory(history, gpu.loadPercent!);
      }
      if (gpu.temperatureC != null) {
        final tempHistory = _gpuTempHistories.putIfAbsent(gpu.id, () => Queue<double>());
        _pushHistory(tempHistory, gpu.temperatureC!);
      }
    }

    if (mounted) {
      setState(() {
        _cpu = cpu;
        _mem = mem;
        _gpus = gpus;
        _networks = networks;
        _load = load;
        _processes = processes;
        _cpuPowerWatts = cpuPower;
        _diskActivityPercent = diskActivity;
      });
    }
  }

  void _pushHistory(Queue<double> queue, double value) {
    queue.addLast(value);
    if (queue.length > _historyLength) {
      queue.removeFirst();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopBar(context),
          const SizedBox(height: 8),
          _buildSummaryHeader(context),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.menu, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Text('Summary', style: Theme.of(context).textTheme.headlineSmall),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _poll,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refresh'),
        ),
      ],
    );
  }

  Widget _buildSummaryHeader(BuildContext context) {
    final primaryGpu = _gpus.isNotEmpty ? _gpus.first : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Row 1: at-a-glance gauges · CPU overview chart · top processes
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summaryCard(
                width: 205,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    VerticalGaugeBar(
                      topLabel: 'CPU',
                      bottomValue: '${_cpu.overallLoadPercent.toStringAsFixed(0)}%',
                      fraction: _cpu.overallLoadPercent / 100,
                      color: _colors.cpu,
                    ),
                    VerticalGaugeBar(
                      topLabel: 'Clock',
                      bottomValue: _cpu.clockMHz != null
                          ? '${(_cpu.clockMHz! / 1000).toStringAsFixed(1)}G'
                          : '—',
                      fraction: _cpu.clockMHz != null ? (_cpu.clockMHz! / 5000).clamp(0.0, 1.0) : 0,
                      color: Colors.redAccent.shade100,
                    ),
                    VerticalGaugeBar(
                      topLabel: 'CPU °C',
                      bottomValue: _cpu.temperatureC != null
                          ? '${_cpu.temperatureC!.toStringAsFixed(0)}C'
                          : '—',
                      fraction: _cpu.temperatureC != null ? (_cpu.temperatureC! / 100).clamp(0.0, 1.0) : 0,
                      color: _colors.cpuTemp,
                    ),
                    VerticalGaugeBar(
                      topLabel: 'GPU %',
                      bottomValue: primaryGpu?.loadPercent != null
                          ? '${primaryGpu!.loadPercent!.toStringAsFixed(0)}%'
                          : '—',
                      fraction: (primaryGpu?.loadPercent ?? 0) / 100,
                      color: _colors.gpu,
                    ),
                    VerticalGaugeBar(
                      topLabel: (primaryGpu?.temperatureIsSharedWithCpu ?? false) ? 'GPU≈CPU' : 'GPU °C',
                      bottomValue: primaryGpu?.temperatureC != null
                          ? '${primaryGpu!.temperatureC!.toStringAsFixed(0)}C'
                          : '—',
                      fraction:
                          primaryGpu?.temperatureC != null ? (primaryGpu!.temperatureC! / 100).clamp(0.0, 1.0) : 0,
                      color: _colors.gpuTemp,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _summaryCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.memory, size: 16),
                          const SizedBox(width: 6),
                          const Text('CPU Overview', style: TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text('${_cpu.overallLoadPercent.toStringAsFixed(1)}%',
                              style: TextStyle(color: _colors.cpu, fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _legendDot(_colors.cpu, 'Utilization'),
                          const SizedBox(width: 12),
                          _legendDot(_colors.cpuTemp, 'Temperature'),
                          const SizedBox(width: 12),
                          _legendDot(_colors.cpuKernel, 'Kernel'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      MultiLineChart(
                        height: 110,
                        minValue: 0,
                        maxValue: 100,
                        glowIntensity: _glow,
                        series: [
                          ChartSeries(values: _cpuHistory.toList(), color: _colors.cpu, filled: true),
                          ChartSeries(values: _cpuTempHistory.toList(), color: _colors.cpuTemp),
                          ChartSeries(values: _cpuKernelHistory.toList(), color: _colors.cpuKernel),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Flexible + ellipsis: prevents overflow if this
                          // card is ever narrowed (window resize, more cards
                          // added to the row) — same fix as HorizontalSparkBarCard.
                          Flexible(
                            child: Text('${_cpu.perCoreLoadPercent.length} logical processors',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                          ),
                          Flexible(
                            child: Text(
                              _cpu.clockMHz != null ? 'Speed ${(_cpu.clockMHz! / 1000).toStringAsFixed(2)} GHz' : '',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _summaryCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.list_alt, size: 16),
                          const SizedBox(width: 6),
                          Text('Top CPU processes (${_processes.length})',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 200,
                        child: SingleChildScrollView(child: ProcessTable(processes: _processes)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Row 2: memory gauge + memory chart
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summaryCard(
                width: 170,
                child: Center(
                  child: VerticalGaugeBar(
                    topLabel: 'Memory',
                    bottomValue: '${_mem.usedPercent.toStringAsFixed(0)}%',
                    fraction: _mem.usedPercent / 100,
                    color: _colors.memory,
                    segments: 14,
                    barWidth: 48,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _summaryCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.developer_board, size: 16),
                          const SizedBox(width: 6),
                          const Text('Memory Utilization', style: TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text(
                            '${(_mem.usedKiB / 1048576).toStringAsFixed(1)} GiB / ${(_mem.totalKiB / 1048576).toStringAsFixed(1)} GiB',
                            style: TextStyle(color: _colors.memory, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      MultiLineChart(
                        height: 90,
                        minValue: 0,
                        maxValue: 100,
                        glowIntensity: _glow,
                        series: [
                          ChartSeries(values: _memHistory.toList(), color: _colors.memory, filled: true),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Flexible + ellipsis on all three, same reasoning
                          // as the disk-space stat row: three unconstrained
                          // Texts in one Row can overflow on a narrow window
                          // even when each string looks short alone.
                          Flexible(
                            child: Text('Available ${(_mem.availableKiB / 1048576).toStringAsFixed(1)} GiB',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                          ),
                          Flexible(
                            child: Text('Cached ${(_mem.cachedKiB / 1048576).toStringAsFixed(1)} GiB',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                          ),
                          Flexible(
                            child: Text('Swap ${(_mem.swapUsedKiB / 1048576).toStringAsFixed(1)} GiB',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Row 3: load average + tasks
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Load average', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      '${_load.load1.toStringAsFixed(2)}  ${_load.load5.toStringAsFixed(2)}  ${_load.load15.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summaryCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Tasks', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      '${_load.runningTasks} running / ${_load.totalTasks}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Row 4: CPU power · thermals · GPU thermals · disk (I/O activity) · network
        Row(
          children: [
            Expanded(
              child: HorizontalSparkBarCard(
                title: 'CPU Power',
                value: _cpuPowerWatts != null ? '${_cpuPowerWatts!.toStringAsFixed(1)} W' : 'N/A',
                history: _cpuPowerHistory.toList(),
                maxValue: _cpuPowerHistory.isEmpty
                    ? 1
                    : _cpuPowerHistory.reduce((a, b) => a > b ? a : b) * 1.2,
                color: _colors.cpuPower,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: HorizontalSparkBarCard(
                title: 'CPU Thermals',
                value: _cpu.temperatureC != null ? '${_cpu.temperatureC!.toStringAsFixed(0)} C' : 'N/A',
                history: _cpuTempHistory.toList(),
                maxValue: 100,
                color: _colors.cpuTemp,
              ),
            ),
            const SizedBox(width: 12),
            ..._buildGpuThermalCards(),
            const SizedBox(width: 12),
            Expanded(
              child: HorizontalSparkBarCard(
                title: 'Disk',
                value: _diskActivityPercent != null ? '${_diskActivityPercent!.toStringAsFixed(1)}%' : 'N/A',
                history: _diskActivityHistory.toList(),
                maxValue: 100,
                color: _colors.disk,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: HorizontalSparkBarCard(
                title: 'Network',
                value: _networks.isNotEmpty
                    ? _formatRate(_networks.first.rxBytesPerSec + _networks.first.txBytesPerSec)
                    : 'N/A',
                history: _networkRateHistory.toList(),
                maxValue: _networkRateHistory.isEmpty
                    ? 1
                    : _networkRateHistory.reduce((a, b) => a > b ? a : b) * 1.2,
                color: _colors.network,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Native providers healthy · ${_processes.length} processes',
          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  /// One "GPU Thermals" spark-bar card per detected GPU (see
  /// [_gpuTempHistories], keyed by [GpuSample.id]) — a system with a
  /// discrete card plus an integrated GPU shows both, side by side,
  /// rather than only the first GPU found. Falls back to a single
  /// "N/A" placeholder card when no GPU was detected at all, so the
  /// row's layout stays stable either way.
  List<Widget> _buildGpuThermalCards() {
    if (_gpus.isEmpty) {
      return [
        Expanded(
          child: HorizontalSparkBarCard(
            title: 'GPU Thermals',
            value: 'N/A',
            history: const [],
            maxValue: 100,
            color: _colors.gpuTemp,
          ),
        ),
      ];
    }

    final multiple = _gpus.length > 1;
    final cards = <Widget>[];
    for (var i = 0; i < _gpus.length; i++) {
      final gpu = _gpus[i];
      if (i > 0) cards.add(const SizedBox(width: 12));
      final baseTitle = gpu.temperatureIsSharedWithCpu ? 'GPU≈CPU' : 'GPU Thermals';
      // Shorter "GPU" (not "GPU Thermals") once a vendor tag is appended
      // for a multi-GPU system — two full titles like "GPU Thermals ·
      // AMD" side by side in an already-narrow card is exactly what
      // triggered the overflow this card now guards against below, so
      // there's no reason to spend the extra width here too.
      final multiTitle = gpu.temperatureIsSharedWithCpu ? 'GPU≈CPU' : 'GPU';
      cards.add(
        Expanded(
          child: HorizontalSparkBarCard(
            title: multiple ? '$multiTitle · ${_shortGpuLabel(gpu)}' : baseTitle,
            value: gpu.temperatureC != null ? '${gpu.temperatureC!.toStringAsFixed(0)} C' : 'N/A',
            history: (_gpuTempHistories[gpu.id] ?? Queue<double>()).toList(),
            maxValue: 100,
            color: _colors.gpuTemp,
          ),
        ),
      );
    }
    return cards;
  }

  /// Short, card-title-friendly label distinguishing one GPU from
  /// another when more than one is shown — vendor name when known
  /// (NVIDIA/AMD/INTEL), otherwise the first word of the GPU's own
  /// name (e.g. "Radeon" out of "AMD Radeon RX 6600").
  String _shortGpuLabel(GpuSample gpu) {
    if (gpu.vendor != GpuVendor.unknown) return gpu.vendor.name.toUpperCase();
    final words = gpu.name.trim().split(RegExp(r'\s+'));
    return (words.isEmpty || words.first.isEmpty) ? 'GPU' : words.first;
  }

  Widget _summaryCard({double? width, required Widget child}) {
    final card = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.15)),
      ),
      child: child,
    );
    return width != null ? SizedBox(width: width, child: card) : card;
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ],
    );
  }

  String _formatRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}
