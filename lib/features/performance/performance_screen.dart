import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../../core/models/cpu_detail_info.dart';
import '../../core/models/cpu_sample.dart';
import '../../core/models/gpu_diagnostic.dart';
import '../../core/models/gpu_sample.dart';
import '../../core/models/memory_sample.dart';
import '../../core/models/network_sample.dart';
import '../../core/models/system_info_sample.dart';
import '../../core/theming/graph_palette.dart';
import '../../services/process_service.dart';
import '../../services/sensor_log_recorder.dart';
import '../../services/sensor_stats_tracker.dart';
import '../../services/sensors/system_sensor_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/horizontal_gauge_bar.dart';
import '../../widgets/mini_graph.dart';
import '../../widgets/multi_line_chart.dart';

const _logSource = 'PerformanceScreen';
const int _historyLength = 60;

enum _Resource { cpu, memory, cpuPower, thermals, disk, network, gpu }

class PerformanceScreen extends StatefulWidget {
  /// See MonitoringDashboard.active — same reasoning: pause the 1s
  /// poll (which repaints many CustomPaint mini-graphs) while this
  /// tab isn't the visible one.
  final bool active;

  /// Shared across every screen (owned by the top-level app shell) so
  /// that state like GPU diagnostics, the persistent intel_gpu_top
  /// process, and fdinfo/RAPL delta caches survives tab switches
  /// instead of being torn down and rebuilt from scratch every time
  /// this screen is navigated away from and back to.
  final SystemSensorService sensors;

  const PerformanceScreen({super.key, this.active = true, required this.sensors});

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> {
  SystemSensorService get _sensors => widget.sensors;
  GraphColorScheme get _colors => GraphColorScheme.fromSettings(SettingsService.instance.current);
  double get _glow => SettingsService.instance.current.glowIntensity;
  final ProcessService _processService = ProcessService();
  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _exportingCsv = false;

  _Resource _selected = _Resource.cpu;
  String? _selectedGpuId; // which GPU when _selected == gpu and multiple exist

  final Queue<double> _cpuHistory = Queue<double>();
  final Queue<double> _memHistory = Queue<double>();
  final Queue<double> _cpuPowerHistory = Queue<double>();
  final Queue<double> _thermalsHistory = Queue<double>();
  final Queue<double> _diskActivityHistory = Queue<double>();
  final Queue<double> _networkRateHistory = Queue<double>();
  final Map<String, Queue<double>> _gpuHistories = {};
  final Map<String, Queue<double>> _gpuTempHistories = {};
  List<Queue<double>> _perCoreHistories = [];

  CpuSample _cpu = CpuSample.empty();
  MemorySample _mem = MemorySample.empty();
  List<GpuSample> _gpus = [];
  List<NetworkSample> _networks = [];
  double? _cpuPowerWatts;
  double? _diskActivityPercent;
  int _processCount = 0;
  int? _threadCount;
  Duration _uptime = Duration.zero;
  CpuDetailInfo _cpuDetails = CpuDetailInfo.unknown();

  bool _firstSampleDiscarded = false;
  final Set<String> _fixInProgress = {};

  // null = not checked yet. Checked once regardless of whether
  // temperature is currently working — the setup button needs to be
  // offered even in a session that happens to be manually elevated
  // right now (exactly the situation this was built for: "I'm
  // elevated today, let me make future launches not need that").
  bool? _backgroundFeedActive;
  Future<void> _checkBackgroundFeed() async {
    if (!Platform.isWindows) return;
    final active = await _sensors.isBackgroundSensorFeedActive();
    if (mounted) setState(() => _backgroundFeedActive = active);
  }

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
    if (widget.active) _startPolling();
    _loadCpuDetails();
    _checkBackgroundFeed();
  }

  @override
  void didUpdateWidget(covariant PerformanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _startPolling();
    } else if (!widget.active && oldWidget.active) {
      _stopPolling();
    }
  }

  void _onSettingsChanged() {
    if (widget.active) _startPolling();
  }

  void _startPolling() {
    final intervalSeconds = SettingsService.instance.current.pollIntervalSeconds;
    _pollTimer?.cancel();
    if (intervalSeconds == 0) {
      AppLogger.instance.info(_logSource, 'Performance screen gepauzeerd (geen automatische verversing)');
      _poll();
      return;
    }
    final interval = Duration(seconds: intervalSeconds);
    AppLogger.instance.info(_logSource, 'Performance screen started, polling every ${interval.inSeconds}s');
    _pollTimer = Timer.periodic(interval, (_) => _poll());
    _poll();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    // Note: does NOT call _sensors.disposeIntelGpuTop() — `sensors` is
    // now shared across all screens (owned by the app shell), so
    // stopping the background GPU tool here would kill it out from
    // under whichever screen is navigated to next. The shell disposes
    // it once, when the whole app closes.
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadCpuDetails() async {
    final details = await _sensors.readCpuDetails();
    if (mounted) setState(() => _cpuDetails = details);
  }

  Future<void> _poll() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      await _doPoll();
    } finally {
      _pollInFlight = false;
    }
  }

  DateTime? _lastSlowPoll;
  static const _slowPollInterval = Duration(seconds: 3);

  Future<void> _doPoll() async {
    // Fired concurrently, not one at a time — see the identical fix (and
    // its full reasoning) in MonitoringDashboard._doPoll. These six
    // reads don't depend on each other's results, so the previous
    // sequential-await version made every tick take the SUM of all six
    // readers' latencies instead of just the slowest one.
    final results = await Future.wait<dynamic>([
      _sensors.readCpu(),
      _sensors.readMemory(),
      _sensors.readGpus(),
      _sensors.readNetwork(),
      _sensors.readCpuPowerWatts(),
      _sensors.readDiskActivity(),
    ]);
    final cpu = results[0] as CpuSample;
    final mem = results[1] as MemorySample;
    final gpus = results[2] as List<GpuSample>;
    final networks = results[3] as List<NetworkSample>;
    final cpuPower = results[4] as double?;
    final diskActivity = results[5] as double?;

    int processCount = _processCount;
    int? threadCount = _threadCount;
    Duration uptime = _uptime;
    final lastSlow = _lastSlowPoll;
    if (lastSlow == null || DateTime.now().difference(lastSlow) >= _slowPollInterval) {
      // Same reasoning again: process listing, thread count, and system
      // info don't depend on each other either.
      final slowResults = await Future.wait<dynamic>([
        _processService.listProcesses(),
        _sensors.readThreadCount(),
        _sensors.readSystemInfo(),
      ]);
      processCount = (slowResults[0] as List).length;
      threadCount = slowResults[1] as int?;
      uptime = (slowResults[2] as SystemInfoSample).uptime;
      _lastSlowPoll = DateTime.now();
    }

    if (_perCoreHistories.length != cpu.perCoreLoadPercent.length) {
      _perCoreHistories = List.generate(cpu.perCoreLoadPercent.length, (_) => Queue<double>());
    }

    if (!_firstSampleDiscarded) {
      _firstSampleDiscarded = true;
      if (mounted) {
        setState(() {
          _cpu = cpu;
          _mem = mem;
          _gpus = gpus;
          _networks = networks;
          _cpuPowerWatts = cpuPower;
          _diskActivityPercent = diskActivity;
          _processCount = processCount;
          _threadCount = threadCount;
          _uptime = uptime;
        });
      }
      return;
    }

    _pushHistory(_cpuHistory, cpu.overallLoadPercent);
    _pushHistory(_memHistory, mem.usedPercent);
    if (cpuPower != null) _pushHistory(_cpuPowerHistory, cpuPower);
    if (cpu.temperatureC != null) _pushHistory(_thermalsHistory, cpu.temperatureC!);
    if (diskActivity != null) _pushHistory(_diskActivityHistory, diskActivity);
    if (networks.isNotEmpty) {
      _pushHistory(_networkRateHistory, networks.first.rxBytesPerSec + networks.first.txBytesPerSec);
    }
    for (var i = 0; i < cpu.perCoreLoadPercent.length && i < _perCoreHistories.length; i++) {
      _pushHistory(_perCoreHistories[i], cpu.perCoreLoadPercent[i]);
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

    // Fed into the app-lifetime SensorStatsTracker singleton alongside
    // the graph histories above — see that class's doc for why this is
    // free (no extra sensor polling, just recording values already
    // read this tick) and why it survives navigating away from this
    // screen, unlike the bounded Queue<double> histories above it.
    final stats = SensorStatsTracker.instance;
    stats.record('cpuLoad', cpu.overallLoadPercent);
    stats.record('memUsed', mem.usedPercent);
    stats.record('cpuPowerW', cpuPower);
    stats.record('cpuTempC', cpu.temperatureC);
    for (final gpu in gpus) {
      stats.record('gpuLoad:${gpu.id}', gpu.loadPercent);
      stats.record('gpuTempC:${gpu.id}', gpu.temperatureC);
    }

    // Same "already read this tick, just also record it" pattern as
    // the SensorStatsTracker calls above — see SensorLogRecorder's own
    // doc for why this is a bounded rolling buffer rather than an
    // unbounded on-disk log.
    final gpuLoadById = <String, double>{
      for (final gpu in gpus)
        if (gpu.loadPercent != null) gpu.id: gpu.loadPercent!,
    };
    final gpuTempById = <String, double>{
      for (final gpu in gpus)
        if (gpu.temperatureC != null) gpu.id: gpu.temperatureC!,
    };
    SensorLogRecorder.instance.record(SensorLogRow(
      timestamp: DateTime.now(),
      cpuLoadPercent: cpu.overallLoadPercent,
      memUsedPercent: mem.usedPercent,
      cpuPowerW: cpuPower,
      cpuTempC: cpu.temperatureC,
      diskActivityPercent: diskActivity,
      networkBytesPerSec:
          networks.isNotEmpty ? networks.first.rxBytesPerSec + networks.first.txBytesPerSec : null,
      gpuLoadPercent: gpuLoadById,
      gpuTempC: gpuTempById,
    ));

    if (mounted) {
      setState(() {
        _cpu = cpu;
        _mem = mem;
        _gpus = gpus;
        _networks = networks;
        _cpuPowerWatts = cpuPower;
        _diskActivityPercent = diskActivity;
        _processCount = processCount;
        _threadCount = threadCount;
        _uptime = uptime;
      });
    }
  }

  void _pushHistory(Queue<double> queue, double value) {
    queue.addLast(value);
    if (queue.length > _historyLength) queue.removeFirst();
  }

  /// Saves the rolling sensor log (see [SensorLogRecorder]) as a CSV
  /// file — same save-location and feedback pattern as
  /// `LogViewerScreen._saveToFile`: Downloads first, falling back to
  /// the app's documents directory if the platform has no Downloads
  /// folder.
  Future<void> _exportCsv() async {
    final recorder = SensorLogRecorder.instance;
    if (recorder.rowCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nog geen metingen om te exporteren — wacht op de eerste paar polls.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() => _exportingCsv = true);
    try {
      final csv = recorder.toCsv();
      final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final fileName = 'darktask_sensorlog_$timestamp.csv';

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
            content: Text('Sensorlog opgeslagen (${recorder.rowCount} metingen): ${file.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Kon sensorlog niet exporteren: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exporteren mislukt: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exportingCsv = false);
    }
  }

  String _formatRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatUptime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _runFix(String gpuId, Future<bool> Function() action, String successMessage) async {
    setState(() => _fixInProgress.add(gpuId));
    final success = await action();
    if (!mounted) return;
    setState(() => _fixInProgress.remove(gpuId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? successMessage : 'Mislukt — zie het Log-tabblad voor details'),
        duration: const Duration(seconds: 3),
      ),
    );
    if (success) _poll();
  }

  bool _restartingElevated = false;

  /// On success this doesn't return — the process exits once the
  /// elevated copy has actually launched (see
  /// SystemSensorService.restartElevated's doc). Only a failure
  /// (declined UAC prompt, etc.) ever reaches the snackbar below.
  Future<void> _restartElevated() async {
    setState(() => _restartingElevated = true);
    final error = await _sensors.restartElevated();
    if (!mounted) return;
    setState(() => _restartingElevated = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 4)),
      );
    }
  }

  /// Opens Windows' own Settings entry point for Windows Security —
  /// confirmed stable/documented, unlike a deeper direct link straight
  /// to the Core Isolation details page (no confirmed stable URI for
  /// that one, so this gets the user to "Apparaatbeveiliging" →
  /// "Kernisolatiedetails" one extra click away rather than guessing a
  /// link that might silently go nowhere). Best-effort: if it can't be
  /// launched for some reason, this just logs and does nothing rather
  /// than crashing over a convenience shortcut.
  Future<void> _openWindowsSecuritySettings() async {
    try {
      await Process.start('explorer.exe', ['ms-settings:windowsdefender']);
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon Windows Beveiliging niet openen: $e');
    }
  }

  bool _installingPawnIo = false;

  /// Downloads and runs the official PawnIO installer — see
  /// SystemSensorService.installPawnIo / LibreHardwareMonitorBridge.
  /// installPawnIo for the full reasoning and exactly what happens
  /// (signature-verified download, then a visible installer wizard
  /// the person interacts with themselves). This only reports back
  /// once that wizard has closed and PawnIO's presence has been
  /// re-verified — never assumes success just because the process
  /// exited.
  Future<void> _installPawnIo() async {
    setState(() => _installingPawnIo = true);
    final success = await _sensors.installPawnIo();
    if (!mounted) return;
    setState(() => _installingPawnIo = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success
            ? 'PawnIO geïnstalleerd — CPU-temperatuur/-vermogen zouden nu moeten verschijnen.'
            : 'PawnIO-installatie niet bevestigd gelukt — zie het Log-tabblad voor details.'),
        duration: const Duration(seconds: 4),
      ),
    );
    if (success) _poll();
  }

  bool _settingUpBackgroundFeed = false;

  /// One-time setup — unlike _restartElevated, this doesn't need to
  /// exit and relaunch anything: the background task starts
  /// independently, and the very next sensor poll will simply start
  /// picking up its readings (see WindowsSensorService's preference
  /// order for the background feed over the per-launch LHM path).
  Future<void> _setupBackgroundFeed() async {
    setState(() => _settingUpBackgroundFeed = true);
    final error = await _sensors.setupBackgroundSensorFeed();
    if (!mounted) return;
    setState(() => _settingUpBackgroundFeed = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Achtergronddienst ingesteld — temperatuur/vermogen zouden nu moeten verschijnen.'),
        duration: const Duration(seconds: 4),
      ),
    );
    if (error == null) {
      _poll();
      _checkBackgroundFeed();
    }
  }

  Widget _buildBackgroundFeedButton() {
    // Recommended over "Herstart als Administrator": one UAC prompt,
    // ever — after this, temperature/power work on every future
    // launch without needing elevation again.
    return OutlinedButton.icon(
      onPressed: _settingUpBackgroundFeed ? null : _setupBackgroundFeed,
      icon: _settingUpBackgroundFeed
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.bolt, size: 16),
      label: Text(_settingUpBackgroundFeed ? 'Bezig...' : 'Achtergronddienst instellen (eenmalig, aanbevolen)'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Icon(Icons.menu, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Text('Performance', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _exportingCsv ? null : _exportCsv,
                icon: _exportingCsv
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_outlined, size: 18),
                label: Text(_exportingCsv ? 'Bezig...' : 'CSV exporteren'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _poll,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 260, child: _buildResourceList()),
              const VerticalDivider(width: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: _buildDetail(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Left master list ---------------------------------------------

  Widget _buildResourceList() {
    return ListView(
      children: [
        _resourceRow(
          resource: _Resource.cpu,
          icon: Icons.memory,
          title: 'CPU',
          line1: '${_cpu.overallLoadPercent.toStringAsFixed(1)}%',
          line2: '${_cpu.perCoreLoadPercent.length} logical processors',
          history: _cpuHistory,
          color: _colors.cpu,
        ),
        _resourceRow(
          resource: _Resource.memory,
          icon: Icons.developer_board,
          title: 'Memory',
          line1:
              '${(_mem.usedKiB / 1048576).toStringAsFixed(1)} GiB / ${(_mem.totalKiB / 1048576).toStringAsFixed(1)} GiB',
          line2: '${_mem.usedPercent.toStringAsFixed(1)}%',
          history: _memHistory,
          color: _colors.memory,
        ),
        _resourceRow(
          resource: _Resource.cpuPower,
          icon: Icons.bolt,
          title: 'CPU Power',
          line1: 'Whole machine',
          line2: _cpuPowerWatts != null ? '${_cpuPowerWatts!.toStringAsFixed(1)} W' : 'N/A',
          history: _cpuPowerHistory,
          color: _colors.cpuPower,
          maxValue: _cpuPowerHistory.isEmpty ? 1 : _cpuPowerHistory.reduce((a, b) => a > b ? a : b) * 1.2,
        ),
        _resourceRow(
          resource: _Resource.thermals,
          icon: Icons.thermostat,
          title: 'Thermals',
          line1: 'Whole machine',
          line2: _cpu.temperatureC != null ? '${_cpu.temperatureC!.toStringAsFixed(0)} C' : 'N/A',
          history: _thermalsHistory,
          color: _colors.cpuTemp,
        ),
        _resourceRow(
          resource: _Resource.disk,
          icon: Icons.storage,
          title: 'Disk',
          line1: 'Physical disk',
          line2: _diskActivityPercent != null ? '${_diskActivityPercent!.toStringAsFixed(1)}%' : 'N/A',
          history: _diskActivityHistory,
          color: _colors.disk,
        ),
        _resourceRow(
          resource: _Resource.network,
          icon: Icons.lan,
          title: 'Network',
          line1: 'Network adapter',
          line2: _networks.isNotEmpty
              ? 'S: ${_formatRate(_networks.first.txBytesPerSec)}  R: ${_formatRate(_networks.first.rxBytesPerSec)}'
              : 'N/A',
          history: _networkRateHistory,
          color: _colors.network,
          maxValue: _networkRateHistory.isEmpty ? 1 : _networkRateHistory.reduce((a, b) => a > b ? a : b) * 1.2,
        ),
        for (final gpu in _gpus)
          _resourceRow(
            resource: _Resource.gpu,
            gpuId: gpu.id,
            icon: Icons.videogame_asset,
            title: gpu.vendor == GpuVendor.unknown ? 'GPU' : 'GPU · ${gpu.vendor.name.toUpperCase()}',
            line1: gpu.name,
            line2: gpu.loadPercent != null ? '${gpu.loadPercent!.toStringAsFixed(1)}%' : 'N/A',
            history: _gpuHistories[gpu.id] ?? Queue<double>(),
            color: _colors.gpu,
          ),
      ],
    );
  }

  Widget _resourceRow({
    required _Resource resource,
    String? gpuId,
    required IconData icon,
    required String title,
    required String line1,
    required String line2,
    required Queue<double> history,
    required Color color,
    double? maxValue,
  }) {
    final isSelected = _selected == resource && (resource != _Resource.gpu || _selectedGpuId == gpuId);
    final selectionColor = Theme.of(context).colorScheme.primary;
    return Material(
      color: isSelected ? selectionColor.withOpacity(0.1) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() {
          _selected = resource;
          _selectedGpuId = gpuId;
        }),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: isSelected ? selectionColor : Colors.transparent, width: 3)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    Text(line1, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                    Text(line2, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              SizedBox(
                width: 60,
                height: 32,
                child: MiniGraph(
                  values: history.toList(),
                  color: color,
                  height: 32,
                  maxValue: maxValue ?? 100,
                  glowIntensity: _glow,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Right detail pane -----------------------------------------------

  Widget _buildDetail() {
    switch (_selected) {
      case _Resource.cpu:
        return _buildCpuDetail();
      case _Resource.memory:
        return _buildMemoryDetail();
      case _Resource.cpuPower:
        return _buildSimpleDetail(
          title: 'CPU Power',
          value: _cpuPowerWatts != null ? '${_cpuPowerWatts!.toStringAsFixed(1)} W' : 'N/A',
          history: _cpuPowerHistory,
          maxValue: _cpuPowerHistory.isEmpty ? 1 : _cpuPowerHistory.reduce((a, b) => a > b ? a : b) * 1.2,
          color: _colors.cpuPower,
          statsKey: 'cpuPowerW',
          statsUnit: ' W',
        );
      case _Resource.thermals:
        return _buildSimpleDetail(
          title: 'Thermals',
          value: _cpu.temperatureC != null ? '${_cpu.temperatureC!.toStringAsFixed(0)} °C' : 'N/A',
          history: _thermalsHistory,
          maxValue: 100,
          color: _colors.cpuTemp,
          statsKey: 'cpuTempC',
          statsUnit: ' °C',
          statsDecimals: 0,
        );
      case _Resource.disk:
        return _buildSimpleDetail(
          title: 'Disk (I/O-activiteit)',
          value: _diskActivityPercent != null ? '${_diskActivityPercent!.toStringAsFixed(1)}%' : 'N/A',
          history: _diskActivityHistory,
          maxValue: 100,
          color: _colors.disk,
        );
      case _Resource.network:
        return _buildNetworkDetail();
      case _Resource.gpu:
        return _buildGpuDetail();
    }
  }

  Widget _buildCpuDetail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CPU', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: HorizontalGaugeBar(
                fraction: _cpu.overallLoadPercent / 100,
                color: _colors.cpu,
              ),
            ),
            const SizedBox(width: 12),
            Text('${_cpu.overallLoadPercent.toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _colors.cpu)),
          ],
        ),
        const SizedBox(height: 4),
        Text('${_cpu.perCoreLoadPercent.length} logical processors',
            style: TextStyle(color: Colors.grey.shade500)),
        const SizedBox(height: 10),
        if (SettingsService.instance.current.showPerCoreCpu) ...[
          const Text('% Utilization by logical processor', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.withOpacity(0.15)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(_cpu.perCoreLoadPercent.length, (i) {
                final history =
                    i < _perCoreHistories.length ? _perCoreHistories[i].toList() : const <double>[];
                return SizedBox(
                  key: ValueKey('cpu-core-$i'),
                  width: 128,
                  height: 52,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.withOpacity(0.15)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('CPU $i', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                        Expanded(child: MiniGraph(values: history, color: _colors.cpu, height: 40, glowIntensity: _glow)),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            _statBlock('Utilization', '${_cpu.overallLoadPercent.toStringAsFixed(1)}%'),
            _statBlock('Speed', _cpu.clockMHz != null ? '${(_cpu.clockMHz! / 1000).toStringAsFixed(2)} GHz' : '—'),
            _statBlock('Processes', '$_processCount'),
            _statBlock('Threads', _threadCount != null ? '$_threadCount' : '—'),
          ],
        ),
        const SizedBox(height: 8),
        _minAvgMaxRow('cpuLoad', unit: '%'),
        const SizedBox(height: 8),
        Row(children: [
          _statBlock('Up time', _formatUptime(_uptime)),
          // Absent (not a fabricated "—" alongside real values) on
          // most laptops, where fan control lives on the embedded
          // controller and isn't exposed to software at all — only
          // shown when LibreHardwareMonitor actually found a Fan
          // sensor for this hardware.
          if (_cpu.fanRpm != null) _statBlock('Fan', '${_cpu.fanRpm} rpm'),
        ]),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('Base speed', _cpuDetails.baseSpeedMHz != null
                      ? '${(_cpuDetails.baseSpeedMHz! / 1000).toStringAsFixed(2)} GHz'
                      : 'onbekend'),
                  _detailRow('Physical cores', _cpuDetails.physicalCores?.toString() ?? 'onbekend'),
                  _detailRow('Virtualization',
                      _cpuDetails.virtualizationSupport != null ? 'Ondersteund (${_cpuDetails.virtualizationSupport})' : 'onbekend'),
                  // Unlike the other "onbekend" fallbacks on this
                  // screen, a missing frequency driver on Windows isn't
                  // a failed reading — the concept itself (a cpufreq
                  // kernel driver) simply doesn't exist there, so
                  // "onbekend" would falsely suggest DarkTask tried and
                  // failed to find one. Same wording already used for
                  // this exact field on the Energie/Frequentie-scherm
                  // (see PowerFreqScreen).
                  _detailRow('Frequency driver',
                      _cpuDetails.frequencyDriver ?? (Platform.isWindows ? 'n.v.t. (Windows)' : 'onbekend')),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('Sockets', _cpuDetails.sockets?.toString() ?? 'onbekend'),
                  _detailRow('Logical processors', _cpuDetails.logicalProcessors?.toString() ?? 'onbekend'),
                  _detailRow('Virtual machine', _cpuDetails.isVirtualMachine == null
                      ? 'onbekend'
                      : (_cpuDetails.isVirtualMachine! ? 'Ja' : 'Nee')),
                  _detailRow('Governor', _cpuDetails.governor ?? 'onbekend'),
                ],
              ),
            ),
          ],
        ),
        if (_sensors.needsElevationForFullSensors) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withOpacity(0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, color: Colors.amber, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('CPU-temperatuur en -vermogen vereisen Administrator-rechten',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        'LibreHardwareMonitor kent deze sensoren, maar heeft laagniveau toegang nodig die '
                        'alleen beschikbaar is als DarkTask verhoogd draait.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                      ),
                      const SizedBox(height: 10),
                      _buildBackgroundFeedButton(),
                      const SizedBox(height: 6),
                      Text(
                        'Vraagt eenmalig om verhoogde rechten en onthoudt dat daarna — geen herhaalde '
                        'UAC-vraag bij elke volgende start.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _restartingElevated ? null : _restartElevated,
                        icon: _restartingElevated
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.admin_panel_settings, size: 16),
                        label: Text(_restartingElevated ? 'Bezig...' : 'Herstart als Administrator (eenmalig, deze sessie)'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else if (_sensors.msrBlockedDespiteElevation) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withOpacity(0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, color: Colors.amber, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('CPU-temperatuur en -vermogen geblokkeerd, ondanks Administrator-rechten',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        'DarkTask draait al verhoogd, dus dat is hier niet het probleem. Waarschijnlijkste '
                        'oorzaak: Geheugenintegriteit/Kernisolatie (Virtualization-Based Security) — op veel '
                        'nieuwere Windows 11-pc\'s standaard ingeschakeld door de fabrikant — blokkeert '
                        'laagniveau CPU-toegang voor élke tool die dit gebruikt (ook HWiNFO, '
                        'OpenHardwareMonitor, enz.), niet alleen DarkTask. Draait dit in een virtuele '
                        'machine, dan geeft de hypervisor zelf dezelfde beperking.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Om te testen: Windows Beveiliging → Apparaatbeveiliging → Kernisolatiedetails → zet '
                        '"Geheugenintegriteit" tijdelijk uit (vereist herstart). Dit is een beveiligingsfunctie '
                        '— alleen uitzetten als je die afweging bewust wilt maken, puur om temperatuur/'
                        'vermogen te meten.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _openWindowsSecuritySettings,
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Windows Beveiliging openen'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else if (Platform.isWindows && _backgroundFeedActive == false && !_sensors.isRunningElevated) ...[
          // Only shown on a non-elevated launch: on an elevated one,
          // SystemSensorService.autoProvisionSensorDependencies already
          // silently set this up (or logged why it couldn't) before
          // this screen was ever opened — offering the same one-click
          // setup again here would just be redundant UI for something
          // that already happened. Genuinely still useful here, though:
          // a non-elevated launch is exactly the case
          // autoProvisionSensorDependencies deliberately skips, so this
          // remains the only way to opt in without relaunching as
          // Administrator every time.
          //
          // Temperature happens to be working right now even without
          // elevation (a driver already installed from an earlier
          // elevated run, or the coarser ACPI thermal-zone fallback) —
          // a neutral tip rather than an alarm, since nothing is
          // actually broken: this is purely "set it up now while
          // you're here, so future non-elevated launches keep the same
          // reading instead of relying on whatever happens to already
          // be in place." Deliberately a different, calmer visual
          // treatment than the amber warning box above.
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.bolt_outlined, color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Tip: temperatuur/vermogen ook zonder verhoogde start',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        'Temperatuur werkt nu al, ook zonder dat DarkTask verhoogd draait. Stel de '
                        'achtergronddienst eenmalig in zodat dit betrouwbaar zo blijft bij elke '
                        'niet-verhoogde start.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                      ),
                      const SizedBox(height: 10),
                      _buildBackgroundFeedButton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else if (Platform.isWindows && _backgroundFeedActive == true && !_sensors.isRunningElevated) ...[
          // Same elevation gate as the "not yet active" card above, and
          // for the same reason: on an elevated launch this card would
          // just be confirming something autoProvisionSensorDependencies
          // already did (or already logged a failure for) moments
          // earlier — redundant, since the person is looking at working
          // numbers on this exact screen either way. Only kept visible
          // on a non-elevated launch, where it's still confirming
          // something genuinely worth knowing (this session's readings
          // are coming from a background task set up earlier, not a
          // fresh elevated process) and its "opnieuw instellen" button
          // still does real work: the background task runs the script
          // that was written to disk at setup time, in an
          // already-started PowerShell process that keeps running with
          // that exact script content until it's restarted — a
          // DarkTask update that changes what the background script
          // itself reads/reports (e.g. adding GPU load to the feed, on
          // top of the temperature/power it already covered) has no way
          // to reach an already-running instance on its own. Re-running
          // setup rewrites the script file and re-registers/restarts
          // the task with it, picking up such a change — at the cost of
          // one more UAC prompt, same as the original one-time setup.
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_outline, color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Achtergronddienst actief', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        'Temperatuur/vermogen (en, als de dienst dat al ondersteunt, GPU-belasting) komen '
                        'rechtstreeks uit deze dienst — geen PowerShell-koude-start nodig bij het opstarten. '
                        'Na een DarkTask-update kan het instellen opnieuw uitvoeren nieuwe verbeteringen '
                        'aan de dienst zelf laten meepakken (vraagt opnieuw eenmalig om verhoogde rechten).',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _settingUpBackgroundFeed ? null : _setupBackgroundFeed,
                        icon: _settingUpBackgroundFeed
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh, size: 16),
                        label: Text(_settingUpBackgroundFeed ? 'Bezig...' : 'Achtergronddienst opnieuw instellen'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        // Deliberately OUTSIDE the if/else-if chain above, not nested
        // inside the msrBlockedDespiteElevation branch: that flag (and
        // therefore all four branches above) is based on whether CPU
        // temperature currently reads as empty — but DarkTask's own
        // ACPI thermal-zone fallback (see WindowsSensorService) often
        // silently fills that gap with an approximate reading once the
        // background service is active, which flips
        // msrBlockedDespiteElevation back to false even though PawnIO
        // is still genuinely missing and LibreHardwareMonitor's own,
        // more precise reading still isn't happening. Confirmed live:
        // on the machine this was built against, setting up the
        // background service made this exact panel jump straight from
        // the amber "geblokkeerd" box to the calm "Achtergronddienst
        // actief" box, silently hiding the PawnIO fix in the process —
        // this box is checked and shown independently precisely so
        // that can't happen again, regardless of which of the four
        // states above is currently showing.
        if (_sensors.pawnIoConfirmedMissing) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withOpacity(0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, color: Colors.amber, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Confirmed, not guessed — see
                      // LibreHardwareMonitorBridge.pawnIoConfirmedMissing:
                      // three independent checks (native driver list,
                      // Windows services, a filesystem sweep) all came
                      // back empty.
                      const Text('CPU-temperatuur en -vermogen: PawnIO-driver ontbreekt',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        'LibreHardwareMonitor gebruikt een apart stukje systeemsoftware (PawnIO) voor deze '
                        'metingen. De officiële LibreHardwareMonitor-app toont daarvoor normaal een eigen '
                        'installatievenster bij de allereerste start — dat venster verschijnt hier nooit, '
                        'omdat DarkTask rechtstreeks met de meetbibliotheek praat. Bevestigd op dit systeem: '
                        'geen PawnIO-driver, -service of -bestand aanwezig (volledige check in het '
                        'Log-tabblad). De temperatuur die hierboven eventueel al te zien is, komt in dat '
                        'geval van een grovere noodoplossing, niet van een echte CPU-uitlezing.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _installingPawnIo ? null : _installPawnIo,
                        icon: _installingPawnIo
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.download, size: 16),
                        label: Text(_installingPawnIo ? 'Bezig...' : 'PawnIO installeren (stil, eenmalig)'),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Downloadt de ondertekende installer van de officiële PawnIO-ontwikkelaar (namazso), '
                        'controleert de digitale handtekening, en installeert die dan stil op de achtergrond '
                        '— geen apart venster, kan een paar seconden duren.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMemoryDetail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Memory', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        MultiLineChart(
          height: 140,
          minValue: 0,
          maxValue: 100,
          glowIntensity: _glow,
          series: [ChartSeries(values: _memHistory.toList(), color: _colors.memory, filled: true)],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _statBlock('In use', '${(_mem.usedKiB / 1048576).toStringAsFixed(1)} GiB'),
            _statBlock('Available', '${(_mem.availableKiB / 1048576).toStringAsFixed(1)} GiB'),
            _statBlock('Cached', '${(_mem.cachedKiB / 1048576).toStringAsFixed(1)} GiB'),
            _statBlock('Swap', '${(_mem.swapUsedKiB / 1048576).toStringAsFixed(1)} GiB'),
          ],
        ),
      ],
    );
  }

  Widget _buildNetworkDetail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Network', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        MultiLineChart(
          height: 140,
          minValue: 0,
          maxValue: _networkRateHistory.isEmpty ? 1 : _networkRateHistory.reduce((a, b) => a > b ? a : b) * 1.2,
          glowIntensity: _glow,
          series: [ChartSeries(values: _networkRateHistory.toList(), color: _colors.network, filled: true)],
        ),
        const SizedBox(height: 16),
        for (final n in _networks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(child: Text(n.interfaceName, style: const TextStyle(fontWeight: FontWeight.w600))),
                Text('↓ ${_formatRate(n.rxBytesPerSec)}   ↑ ${_formatRate(n.txBytesPerSec)}',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildGpuDetail() {
    final gpu = _gpus.firstWhere(
      (g) => g.id == _selectedGpuId,
      orElse: () => _gpus.isNotEmpty ? _gpus.first : GpuSample.unavailable(),
    );
    final diagnostic = _sensors.gpuDiagnostics[gpu.id];
    final fixing = _fixInProgress.contains(gpu.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(gpu.name, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            _legendDot(_colors.gpu, 'Belasting'),
            const SizedBox(width: 12),
            _legendDot(_colors.gpuTemp, 'Temperatuur'),
          ],
        ),
        const SizedBox(height: 8),
        MultiLineChart(
          height: 140,
          minValue: 0,
          maxValue: 100,
          glowIntensity: _glow,
          series: [
            ChartSeries(
                values: (_gpuHistories[gpu.id] ?? Queue<double>()).toList(),
                color: _colors.gpu,
                filled: true),
            ChartSeries(
                values: (_gpuTempHistories[gpu.id] ?? Queue<double>()).toList(),
                color: _colors.gpuTemp),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _statBlock('Belasting', gpu.loadPercent != null ? '${gpu.loadPercent!.toStringAsFixed(1)}%' : 'N/A'),
            _statBlock(
              'Temperatuur',
              gpu.temperatureC != null
                  ? '${gpu.temperatureC!.toStringAsFixed(0)}°C${gpu.temperatureIsSharedWithCpu ? ' (≈CPU-die)' : ''}'
                  : 'niet beschikbaar',
            ),
            if (gpu.powerDrawWatts != null) _statBlock('Vermogen', '${gpu.powerDrawWatts!.toStringAsFixed(0)}W'),
            if (gpu.clockMHz != null) _statBlock('Kloksnelheid', '${gpu.clockMHz!.toStringAsFixed(0)} MHz'),
            if (gpu.memoryTotalMiB != null)
              _statBlock('VRAM', '${(gpu.memoryUsedMiB ?? 0).toStringAsFixed(0)} / ${gpu.memoryTotalMiB!.toStringAsFixed(0)} MiB'),
            // Only ever populated for AMD/Intel via LibreHardwareMonitor
            // (genuinely RPM) — nvidia-smi's fan reading is a percentage
            // of max speed, a different unit, so that path deliberately
            // leaves this null rather than mislabeling a % as RPM (see
            // WindowsSensorService._readGenericGpusWindows).
            if (gpu.fanRpm != null) _statBlock('Fan', '${gpu.fanRpm} rpm'),
          ],
        ),
        const SizedBox(height: 8),
        _minAvgMaxRow('gpuLoad:${gpu.id}', unit: '%'),
        if (!gpu.temperatureIsSharedWithCpu) ...[
          const SizedBox(height: 4),
          _minAvgMaxRow('gpuTempC:${gpu.id}', unit: '°C', decimals: 0),
        ],
        if (gpu.temperatureIsSharedWithCpu) ...[
          const SizedBox(height: 8),
          Text(
            'Deze integrated GPU deelt de die met de CPU en heeft geen eigen thermische sensor — '
            'de weergegeven waarde is de CPU-pakkettemperatuur, die voor de hele die (dus ook de GPU) '
            'geldt. Geen aparte GPU-meting, maar wel een echte en relevante temperatuur.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
          ),
        ] else if (gpu.temperatureC == null) ...[
          const SizedBox(height: 8),
          Text(
            'Deze GPU/driver stelt geen temperatuur beschikbaar via het besturingssysteem, en er is '
            'ook geen CPU-temperatuur gevonden om als benadering te gebruiken.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
          ),
        ],
        if (diagnostic != null && (diagnostic.canOfferPermissionFix || diagnostic.canOfferInstall)) ...[
          const SizedBox(height: 8),
          Text(
            diagnostic.message,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11.5),
          ),
        ],
        if (diagnostic != null && diagnostic.canOfferPermissionFix) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: fixing
                ? null
                : () => _runFix(gpu.id, () => _sensors.fixIntelGpuPermission(),
                    'Rechten hersteld — belasting zou nu moeten verschijnen'),
            icon: fixing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.lock_open, size: 16),
            label: Text(fixing ? 'Bezig...' : 'Rechten herstellen'),
          ),
        ],
        if (diagnostic != null && diagnostic.canOfferInstall) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: fixing
                ? null
                : () => _runFix(gpu.id, () => _sensors.installIntelGpuTools(),
                    'Installatie voltooid — belasting/temperatuur zouden nu moeten verschijnen'),
            icon: fixing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, size: 16),
            label: Text(fixing ? 'Bezig...' : 'Ontbrekende tool installeren'),
          ),
        ],
      ],
    );
  }

  Widget _buildSimpleDetail({
    required String title,
    required String value,
    required Queue<double> history,
    required double maxValue,
    required Color color,
    String? statsKey,
    String statsUnit = '',
    int statsDecimals = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: color)),
        const SizedBox(height: 16),
        MultiLineChart(
          height: 140,
          minValue: 0,
          maxValue: maxValue,
          series: [ChartSeries(values: history.toList(), color: color, filled: true)],
        ),
        if (statsKey != null) ...[
          const SizedBox(height: 12),
          _minAvgMaxRow(statsKey, unit: statsUnit, decimals: statsDecimals),
        ],
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }

  /// Min/Gem./Max row for a sensor tracked in [SensorStatsTracker] —
  /// the concrete "since app start" stat columns HWiNFO64-style tools
  /// show next to a live reading (see that class's doc). Renders
  /// nothing (an empty [SizedBox]) if no sample has been recorded yet
  /// under [key] — right after launch, before the first poll completes
  /// — rather than showing a row of dashes that would only disappear a
  /// second later.
  Widget _minAvgMaxRow(String key, {String unit = '', int decimals = 1}) {
    final stat = SensorStatsTracker.instance[key];
    if (stat == null) return const SizedBox.shrink();
    String fmt(double? v) => v == null ? '—' : '${v.toStringAsFixed(decimals)}$unit';
    return Row(
      children: [
        _statBlock('Min', fmt(stat.min)),
        _statBlock('Gem.', fmt(stat.average)),
        _statBlock('Max', fmt(stat.max)),
      ],
    );
  }

  Widget _statBlock(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 130, child: Text(label, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
