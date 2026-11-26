import 'package:flutter/material.dart';

import '../../core/models/system_info_sample.dart';
import '../../services/sensors/system_sensor_service.dart';

class SystemInfoScreen extends StatefulWidget {
  /// Shared across every screen (owned by the top-level app shell) —
  /// avoids re-scanning NVIDIA/sysfs GPUs from scratch on every visit.
  final SystemSensorService sensors;

  const SystemInfoScreen({super.key, required this.sensors});

  @override
  State<SystemInfoScreen> createState() => _SystemInfoScreenState();
}

class _SystemInfoScreenState extends State<SystemInfoScreen> {
  SystemSensorService get _sensors => widget.sensors;
  SystemInfoSample? _info;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final info = await _sensors.readSystemInfo();
    if (mounted) {
      setState(() {
        _info = info;
        _loading = false;
      });
    }
  }

  String _formatUptime(Duration d) {
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    final parts = <String>[];
    if (days > 0) parts.add('$days d');
    if (hours > 0 || days > 0) parts.add('$hours u');
    parts.add('$minutes m');
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final info = _info ?? SystemInfoSample.unknown();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('System Info', style: Theme.of(context).textTheme.headlineSmall),
                const Spacer(),
                IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
              ],
            ),
            const SizedBox(height: 16),
            _section(
              title: 'Systeem',
              icon: Icons.dns_outlined,
              rows: [
                _InfoRow('Hostname', info.hostname),
                _InfoRow('Besturingssysteem', info.osName),
                _InfoRow('Kernel', info.kernelVersion),
                _InfoRow('Architectuur', info.architecture),
                _InfoRow('Uptime', _formatUptime(info.uptime)),
              ],
            ),
            const SizedBox(height: 16),
            _section(
              title: 'Hardware',
              icon: Icons.memory_outlined,
              rows: [
                _InfoRow('CPU', info.cpuModel),
                _InfoRow('CPU-kernen', '${info.cpuCores}'),
                _InfoRow('Geheugen (totaal)', '${info.totalMemoryGiB.toStringAsFixed(1)} GiB'),
                if (info.gpuNames.isEmpty)
                  const _InfoRow('GPU', 'Geen gedetecteerd')
                else
                  for (var i = 0; i < info.gpuNames.length; i++)
                    _InfoRow(info.gpuNames.length > 1 ? 'GPU ${i + 1}' : 'GPU', info.gpuNames[i]),
                _InfoRow('Fabrikant', info.systemVendor ?? 'onbekend'),
                _InfoRow('Model', info.systemModel ?? 'onbekend'),
                _InfoRow('BIOS-versie', info.biosVersion ?? 'onbekend'),
                _InfoRow('BIOS-datum', info.biosDate ?? 'onbekend'),
              ],
            ),
            const SizedBox(height: 16),
            _section(
              title: 'Software-omgeving',
              icon: Icons.desktop_windows_outlined,
              rows: [
                _InfoRow('Desktopomgeving', info.desktopEnvironment ?? 'onbekend'),
                _InfoRow('Display-server', info.displayServer ?? 'onbekend'),
                _InfoRow('Shell', info.shell ?? 'onbekend'),
                _InfoRow('Taal/locale', info.locale ?? 'onbekend'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({required String title, required IconData icon, required List<_InfoRow> rows}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 4),
          const Divider(height: 16),
          for (final row in rows) _buildRow(row),
        ],
      ),
    );
  }

  Widget _buildRow(_InfoRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(row.label, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
          ),
          Expanded(
            child: Text(row.value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

class _InfoRow {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
}
