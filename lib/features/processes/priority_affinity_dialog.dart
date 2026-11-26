import 'package:flutter/material.dart';

import '../../core/models/process_info.dart';
import '../../core/models/process_priority.dart';
import '../../services/process_service.dart';

/// A small dialog for changing one process' scheduling priority and/or
/// CPU affinity — the two controls Windows' own Task Manager exposes
/// under its Details tab's right-click menu, which this app's Processes
/// screen didn't have until now (killing a process was the only
/// available action). See [ProcessService.getPriority]/[setPriority]/
/// [getAffinity]/[setAffinity] for where the actual platform work
/// happens; this widget is just the read-current-state → edit → apply
/// flow around them.
class PriorityAffinityDialog extends StatefulWidget {
  final ProcessService service;
  final ProcessInfo process;

  const PriorityAffinityDialog({super.key, required this.service, required this.process});

  static Future<void> show(BuildContext context, ProcessService service, ProcessInfo process) {
    return showDialog<void>(
      context: context,
      builder: (_) => PriorityAffinityDialog(service: service, process: process),
    );
  }

  @override
  State<PriorityAffinityDialog> createState() => _PriorityAffinityDialogState();
}

class _PriorityAffinityDialogState extends State<PriorityAffinityDialog> {
  bool _loading = true;
  bool _saving = false;

  bool _priorityAvailable = false;
  ProcessPriority _priority = ProcessPriority.normal;

  bool _affinityAvailable = false;
  int _processMask = 0;
  int _systemMask = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final priority = await widget.service.getPriority(widget.process.pid);
    final affinity = await widget.service.getAffinity(widget.process.pid);
    if (!mounted) return;
    setState(() {
      _priorityAvailable = priority != null;
      _priority = priority ?? ProcessPriority.normal;
      _affinityAvailable = affinity != null;
      _processMask = affinity?.process ?? 0;
      _systemMask = affinity?.system ?? 0;
      _loading = false;
    });
  }

  /// Logical CPU indices present in the system affinity mask — the set
  /// of checkboxes/chips to draw. Bounded to 64 since that's the width
  /// of the int this mask travels in on both platforms; no machine
  /// this app targets has more logical processors than that.
  List<int> get _logicalCpus {
    final cpus = <int>[];
    for (var i = 0; i < 64; i++) {
      if ((_systemMask >> i) & 1 == 1) cpus.add(i);
    }
    return cpus;
  }

  Future<void> _apply() async {
    setState(() => _saving = true);
    var priorityOk = true;
    var affinityOk = true;
    if (_priorityAvailable) {
      priorityOk = await widget.service.setPriority(widget.process.pid, _priority);
    }
    if (_affinityAvailable) {
      affinityOk = await widget.service.setAffinity(widget.process.pid, _processMask);
    }
    if (!mounted) return;
    final ok = priorityOk && affinityOk;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Toegepast op "${widget.process.name}".'
              : 'Niet (volledig) gelukt voor "${widget.process.name}" — mogelijk toegang geweigerd voor dit proces.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canApply = !_saving && !_loading && (_priorityAvailable || _affinityAvailable);
    return AlertDialog(
      title: Text(
        '${widget.process.name} (PID ${widget.process.pid})',
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      content: SizedBox(
        width: 360,
        child: _loading
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Prioriteit', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  if (!_priorityAvailable)
                    Text(
                      'Niet beschikbaar voor dit proces (mogelijk een beschermd systeemproces, '
                      'of het is al gestopt).',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    )
                  else
                    DropdownButton<ProcessPriority>(
                      isExpanded: true,
                      value: _priority,
                      items: ProcessPriority.values
                          .map((p) => DropdownMenuItem(value: p, child: Text(p.label)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _priority = v);
                      },
                    ),
                  const SizedBox(height: 16),
                  Text('CPU-affinity', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  if (!_affinityAvailable)
                    Text(
                      'Niet beschikbaar voor dit proces (mogelijk een beschermd systeemproces, '
                      'of het is al gestopt).',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _logicalCpus.map((i) {
                        final selected = (_processMask >> i) & 1 == 1;
                        return FilterChip(
                          label: Text('CPU $i', style: const TextStyle(fontSize: 12)),
                          selected: selected,
                          onSelected: (v) {
                            setState(() {
                              final newMask = v ? (_processMask | (1 << i)) : (_processMask & ~(1 << i));
                              // Never allow ending up with zero bits set —
                              // Windows rejects that outright (a process
                              // needs at least one CPU to run on), so this
                              // blocks the last checkbox from being
                              // unticked rather than letting "Toepassen"
                              // fail with an opaque error afterward.
                              if (newMask != 0) _processMask = newMask;
                            });
                          },
                        );
                      }).toList(),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Annuleren'),
        ),
        FilledButton(
          onPressed: canApply ? _apply : null,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Toepassen'),
        ),
      ],
    );
  }
}
