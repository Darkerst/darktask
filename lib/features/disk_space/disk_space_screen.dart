import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/disk_health_info.dart';
import '../../core/models/disk_sample.dart';
import '../../services/sensors/system_sensor_service.dart';

class DiskSpaceScreen extends StatefulWidget {
  /// Shared across every screen (owned by the top-level app shell) so
  /// disk I/O-activity delta history survives tab switches.
  final SystemSensorService sensors;

  const DiskSpaceScreen({super.key, required this.sensors});

  @override
  State<DiskSpaceScreen> createState() => _DiskSpaceScreenState();
}

class _DiskSpaceScreenState extends State<DiskSpaceScreen> {
  SystemSensorService get _sensors => widget.sensors;
  List<DiskSample> _disks = [];
  List<DiskHealthInfo> _diskHealth = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final disks = await _sensors.readDisks();
    // Painted immediately once space usage is known, rather than
    // continuing to wait for SMART health too — readDiskHealth spawns
    // its own fresh, non-persistent PowerShell process (see
    // WindowsSensorService.readDiskHealth), which is meaningfully slower
    // than the disk-space read above it, so gating the whole screen's
    // first paint on both together made the fast figures wait on the
    // slow ones for no reason.
    if (mounted) {
      setState(() {
        _disks = disks;
        _loading = false;
      });
    }
    // SMART data changes even more slowly than filesystem usage anyway,
    // so it's just as reasonable to have it fill in a moment after the
    // rest of the screen as to gate on it up front — and just as
    // reasonable to refresh on every manual refresh tap as the
    // space-usage figures above it.
    final health = await _sensors.readDiskHealth();
    if (mounted) setState(() => _diskHealth = health);
  }

  String _formatBytes(int bytes) {
    final gib = bytes / (1024 * 1024 * 1024);
    if (gib >= 1) return '${gib.toStringAsFixed(1)} GiB';
    final mib = bytes / (1024 * 1024);
    return '${mib.toStringAsFixed(0)} MiB';
  }

  Color _colorForUsage(double percent) {
    if (percent >= 90) return Colors.redAccent;
    if (percent >= 75) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  String _formatPowerOn(int hours) {
    final days = hours / 24;
    if (days >= 365) return '${(days / 365).toStringAsFixed(1)} jaar (${hours}u)';
    if (days >= 1) return '${days.toStringAsFixed(0)} dagen (${hours}u)';
    return '$hours uur';
  }

  Color _colorForLifeRemaining(double percent) {
    if (percent <= 10) return Colors.redAccent;
    if (percent <= 25) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Disk Space', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _disks.isEmpty && _diskHealth.isEmpty
                ? Center(
                    child: Text('Geen schijven gevonden', style: TextStyle(color: Colors.grey.shade600)),
                  )
                : ListView(
                    children: [
                      ..._disks.map((d) {
                        final color = _colorForUsage(d.usedPercent);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: color.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  // Expanded + ellipsis: mountPoint can be a long
                                  // Windows path or Linux mount point, and an
                                  // unconstrained Text next to the percentage
                                  // overflows the Row once the two no longer fit
                                  // side by side (same overflow class fixed
                                  // earlier in HorizontalSparkBarCard).
                                  Expanded(
                                    child: Text(
                                      d.mountPoint,
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('${d.usedPercent.toStringAsFixed(0)}%',
                                      style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text('${d.device} · ${d.fsType}',
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                              const SizedBox(height: 10),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: (d.usedPercent / 100).clamp(0.0, 1.0),
                                  minHeight: 6,
                                  backgroundColor: color.withOpacity(0.12),
                                  valueColor: AlwaysStoppedAnimation(color),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // Flexible + ellipsis on all three: with three
                                  // unconstrained Texts in one Row, a narrow
                                  // window (or a locale with longer unit/number
                                  // formatting) can overflow even though each
                                  // string looks short in isolation.
                                  Flexible(
                                    child: Text('${_formatBytes(d.usedBytes)} gebruikt',
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                  ),
                                  Flexible(
                                    child: Text('${_formatBytes(d.availableBytes)} vrij',
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                  ),
                                  Flexible(
                                    child: Text('${_formatBytes(d.totalBytes)} totaal',
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 4),
                      Text('Schijfgezondheid', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      if (!_diskHealth.hasAnyMeaningfulData)
                        Text(
                          Platform.isWindows
                              ? 'Geen nauwkeurige gezondheidsgegevens beschikbaar voor de gevonden schijven op '
                                  'dit systeem — Windows\' eigen Storage Reliability Counters zijn hiervoor niet '
                                  'altijd betrouwbaar, en dit apparaat/deze bus wordt niet ondersteund door de '
                                  'directe NVMe-uitlezing.'
                              : 'Geen gezondheidsgegevens beschikbaar — installeer het pakket "smartmontools" '
                                  '(voor het commando smartctl) om dit te zien.',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
                        )
                      else ...[
                        // Deliberately a separate list from the
                        // filesystem-space cards above, not merged
                        // into them — a single physical disk can hold
                        // several filesystems (or none at all), so
                        // there's no reliable one-to-one line to draw
                        // between a health entry and a specific mount
                        // point above it (see DiskHealthInfo's own doc
                        // comment on this).
                        ..._diskHealth.map((h) {
                          final lifeRemaining = h.lifeRemainingPercent;
                          final lifeColor =
                              lifeRemaining != null ? _colorForLifeRemaining(lifeRemaining) : Colors.grey;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(h.isSsd == true ? Icons.sd_card_outlined : Icons.storage, size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(h.model ?? h.deviceId,
                                          style: const TextStyle(fontWeight: FontWeight.w600)),
                                    ),
                                    if (h.temperatureC != null)
                                      Text('${h.temperatureC!.toStringAsFixed(0)}°C',
                                          style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                if (h.powerOnHours != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Icon(Icons.schedule, size: 16, color: Colors.grey.shade500),
                                        const SizedBox(width: 8),
                                        const Text('Gebruiksduur', style: TextStyle(fontSize: 12.5)),
                                        const Spacer(),
                                        Text(_formatPowerOn(h.powerOnHours!),
                                            style:
                                                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                if (lifeRemaining != null) ...[
                                  Row(
                                    children: [
                                      Icon(Icons.favorite_border, size: 16, color: Colors.grey.shade500),
                                      const SizedBox(width: 8),
                                      const Text('Resterende levensduur', style: TextStyle(fontSize: 12.5)),
                                      const Spacer(),
                                      Text('${lifeRemaining.toStringAsFixed(0)}%',
                                          style: TextStyle(
                                              fontSize: 12.5, fontWeight: FontWeight.w700, color: lifeColor)),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: (lifeRemaining / 100).clamp(0.0, 1.0),
                                      minHeight: 6,
                                      backgroundColor: lifeColor.withOpacity(0.12),
                                      valueColor: AlwaysStoppedAnimation(lifeColor),
                                    ),
                                  ),
                                ] else if (h.isSsd == false)
                                  Text(
                                    'Geen slijtage-indicator beschikbaar voor een draaiende harde schijf.',
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5),
                                  )
                                else if (h.isSsd == true && h.powerOnHours != null)
                                  Text(
                                    'Slijtage-teller niet betrouwbaar op dit systeem — de opslagcontroller '
                                    'houdt deze niet bij (een bekende beperking op sommige schijven/drivers, '
                                    'geen echte 0%).',
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5),
                                  )
                                else if (h.powerOnHours == null)
                                  Text(
                                    'Geen gezondheidsgegevens beschikbaar voor deze schijf.',
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5),
                                  ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
