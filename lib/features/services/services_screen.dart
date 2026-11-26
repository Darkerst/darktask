import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/service_info.dart';
import '../../services/services_service.dart';
import '../../services/settings_service.dart';

class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  final ServicesService _service = ServicesService();
  List<ServiceInfo> _services = [];
  bool _loading = true;
  bool _systemdAvailable = true;
  String _filter = '';
  bool _onlyRunning = false;
  final Set<String> _busyUnits = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final systemdOk = await _service.isSystemdAvailable();
    final services = systemdOk ? await _service.listServices() : <ServiceInfo>[];
    if (mounted) {
      setState(() {
        _systemdAvailable = systemdOk;
        _services = services;
        _loading = false;
      });
    }
  }

  Future<void> _runAction(ServiceInfo service, String action, {bool confirm = false}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${_actionLabel(action)}?'),
          content: Text('Weet je zeker dat je "${service.unitName}" wilt ${_actionLabel(action).toLowerCase()}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuleren')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_actionLabel(action))),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busyUnits.add(service.unitName));
    final result = await _service.runAction(action, service.unitName);
    if (!mounted) return;
    setState(() => _busyUnits.remove(service.unitName));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? '${_actionLabel(action)} van "${service.unitName}" gelukt'
              : '${_actionLabel(action)} mislukt: ${result.message.isNotEmpty ? result.message : 'zie het Log-tabblad'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );

    if (result.success) _load();
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'start':
        return 'Starten';
      case 'stop':
        return 'Stoppen';
      case 'restart':
        return 'Herstarten';
      case 'enable':
        return 'Inschakelen';
      case 'disable':
        return 'Uitschakelen';
      default:
        return action;
    }
  }

  Color _statusColor(ServiceInfo s) {
    if (s.isFailed) return Colors.redAccent;
    if (s.isRunning) return Colors.greenAccent;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_systemdAvailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.build_outlined, size: 48, color: Colors.grey.shade600),
              const SizedBox(height: 12),
              Text(
                Platform.isWindows
                    ? 'Kon geen verbinding maken met Windows Service Control Manager'
                    : 'systemd niet gevonden op dit systeem',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                Platform.isWindows
                    ? 'Dit zou op elke Windows-installatie moeten werken — controleer het Log-tabblad voor details.'
                    : 'Deze pagina werkt alleen op systemd-gebaseerde distributies.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _services.where((s) {
      if (_onlyRunning && !s.isRunning) return false;
      if (_filter.isEmpty) return true;
      final q = _filter.toLowerCase();
      return s.unitName.toLowerCase().contains(q) || s.description.toLowerCase().contains(q);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Services', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Filter op naam of omschrijving...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('Alleen actief'),
                selected: _onlyRunning,
                onSelected: (v) => setState(() => _onlyRunning = v),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${filtered.length} van ${_services.length} services',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) => _buildServiceTile(filtered[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServiceTile(ServiceInfo s) {
    final busy = _busyUnits.contains(s.unitName);
    return ListTile(
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: _statusColor(s), shape: BoxShape.circle),
      ),
      title: Text(s.unitName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      subtitle: Text(
        '${s.description.isNotEmpty ? s.description : '(geen omschrijving)'} · ${s.subState} · ${s.enabledState}',
        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (action) {
                final isRiskyAction = action == 'stop' || action == 'disable';
                final needsConfirm =
                    isRiskyAction && SettingsService.instance.current.confirmDestructiveActions;
                _runAction(s, action, confirm: needsConfirm);
              },
              itemBuilder: (context) => [
                if (!s.isRunning)
                  const PopupMenuItem(value: 'start', child: Text('Starten')),
                if (s.isRunning) ...[
                  const PopupMenuItem(value: 'stop', child: Text('Stoppen')),
                  const PopupMenuItem(value: 'restart', child: Text('Herstarten')),
                ],
                if (!s.isEnabled)
                  const PopupMenuItem(value: 'enable', child: Text('Inschakelen bij opstarten')),
                if (s.isEnabled)
                  const PopupMenuItem(value: 'disable', child: Text('Uitschakelen bij opstarten')),
              ],
            ),
    );
  }
}
