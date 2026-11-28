import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/logging/app_logger.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/process_info.dart';
import '../../services/process_service.dart';
import '../../services/sensors/system_sensor_service.dart';
import '../../services/settings_service.dart';
import 'priority_affinity_dialog.dart';

const _logSource = 'ProcessListScreen';

class ProcessListScreen extends StatefulWidget {
  /// See MonitoringDashboard.active — pause the 2s poll while this
  /// tab isn't the visible one.
  final bool active;
  final SystemSensorService sensors;
  const ProcessListScreen({super.key, required this.sensors, this.active = true});

  @override
  State<ProcessListScreen> createState() => _ProcessListScreenState();
}

class _ProcessListScreenState extends State<ProcessListScreen> {
  final ProcessService _service = ProcessService();
  Timer? _pollTimer;
  List<ProcessInfo> _processes = [];
  String _filter = '';

  // readPerProcessGpuLoad() is bewust relatief duur (zie die method's
  // class-doc in windows_sensor_service.dart: elke keer verse
  // performance-counters + een settle-sample, omdat persistente tellers
  // hier een reeel risico op foutieve data geven bij PID-hergebruik).
  // Een "nice to have" kolom als per-proces GPU-load hoeft niet elke
  // 2s-poll vers te zijn -- 1 op de 3 (~6s) volstaat ruim, terwijl de
  // rest van de lijst (naam/CPU%/geheugen, via de snelle native
  // ProcessSnapshotReader) gewoon elke 2s blijft verversen.
  static const _gpuLoadEveryNRefreshes = 3;
  int _refreshCount = 0;
  Map<int, double> _lastGpuByPid = const {};

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
    _refresh();
    if (widget.active) _startPolling();
  }

  /// Re-sorts in place (no need to re-fetch from /proc) when only the
  /// sort preference changed; a full _refresh() would also work but
  /// unnecessarily re-runs `ps` for what's purely a display change.
  void _onSettingsChanged() {
    if (mounted) setState(_applySortOrder);
  }

  void _applySortOrder() {
    final sortBy = SettingsService.instance.current.processSortBy;
    switch (sortBy) {
      case ProcessSortBy.cpu:
        _processes.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
        break;
      case ProcessSortBy.memory:
        _processes.sort((a, b) => b.memoryKiB.compareTo(a.memoryKiB));
        break;
      case ProcessSortBy.name:
        _processes.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
    }
  }

  @override
  void didUpdateWidget(covariant ProcessListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _refresh();
      _startPolling();
    } else if (!widget.active && oldWidget.active) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    // Beide onafhankelijke reads meteen starten (niet na elkaar
    // awaiten) zodat de trage GPU-query, als die deze keer aan de
    // beurt is, niet nog eens bovenop de proceslijst-tijd komt.
    final processesFuture = _service.listProcesses();

    _refreshCount++;
    final fetchGpu = _refreshCount % _gpuLoadEveryNRefreshes == 0;
    final gpuFuture = fetchGpu ? widget.sensors.readPerProcessGpuLoad() : null;

    final processes = await processesFuture;

    // Een separate, optionele read — een GPU-tracking-hiccup mag de
    // kern-proceslijst (waar mensen echt op vertrouwen) nooit
    // ophouden of breken. Buiten de polls waarin de GPU-load niet
    // vers wordt opgehaald, hergebruiken we gewoon de laatst bekende
    // waarde in plaats van de kolom te laten leeglopen.
    var gpuByPid = _lastGpuByPid;
    if (gpuFuture != null) {
      try {
        gpuByPid = await gpuFuture;
        _lastGpuByPid = gpuByPid;
      } catch (e) {
        AppLogger.instance.debug(_logSource, 'Failed to read per-process GPU load: $e');
      }
    }

    final merged = gpuByPid.isEmpty
        ? processes
        : processes.map((p) => p.withGpuPercent(gpuByPid[p.pid])).toList();

    if (mounted) {
      setState(() {
        _processes = merged;
        _applySortOrder();
      });
    }
  }

  Future<void> _confirmAndKill(ProcessInfo process) async {
    final needsConfirm = SettingsService.instance.current.confirmDestructiveActions;
    var confirmed = true;
    if (needsConfirm) {
      confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Proces beëindigen?'),
              content: Text('Weet je zeker dat je "${process.name}" (PID ${process.pid}) wilt beëindigen?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuleren')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Beëindigen')),
              ],
            ),
          ) ??
          false;
    }

    if (confirmed) {
      final success = await _service.killProcess(process.pid);
      AppLogger.instance.info(
        _logSource,
        success
            ? 'User terminated PID ${process.pid} (${process.name})'
            : 'Failed to terminate PID ${process.pid} (${process.name})',
      );
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? _processes
        : _processes
            .where((p) => p.name.toLowerCase().contains(_filter.toLowerCase()))
            .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Filter op processnaam...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final p = filtered[index];
              return ListTile(
                dense: true,
                title: Text(p.name, overflow: TextOverflow.ellipsis),
                subtitle: Text('PID ${p.pid} · ${p.user} · ${p.state}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${p.cpuPercent.toStringAsFixed(1)}%'),
                    const SizedBox(width: 12),
                    Text('${(p.memoryKiB / 1024).toStringAsFixed(0)} MB'),
                    const SizedBox(width: 12),
                    // Null (not measured) is shown as a dash rather
                    // than omitted entirely — a blank gap where every
                    // other row has a GPU% would read as "this process
                    // definitely uses 0%", when the honest answer here
                    // is "not tracked for this process".
                    SizedBox(
                      width: 44,
                      child: Text(
                        p.gpuPercent != null ? '${p.gpuPercent!.toStringAsFixed(0)}%' : '—',
                        textAlign: TextAlign.right,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.tune, size: 18),
                      tooltip: 'Prioriteit & CPU-affinity',
                      onPressed: () => PriorityAffinityDialog.show(context, _service, p),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Beëindigen',
                      onPressed: () => _confirmAndKill(p),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
