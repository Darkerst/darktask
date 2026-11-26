import 'package:flutter/material.dart';

import '../core/models/process_info.dart';

const _headerStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey);

/// A compact, scrollable table of the top processes by CPU usage —
/// used on the summary dashboard. GPU% is shown as "—" for every row
/// for now: correlating fdinfo's per-process GPU busy time into this
/// table is a reasonable follow-up, not yet wired through.
class ProcessTable extends StatelessWidget {
  final List<ProcessInfo> processes;
  final int maxRows;

  const ProcessTable({super.key, required this.processes, this.maxRows = 8});

  @override
  Widget build(BuildContext context) {
    final rows = processes.take(maxRows).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: const [
              SizedBox(width: 50, child: Text('PID', style: _headerStyle)),
              Expanded(flex: 3, child: Text('Naam', style: _headerStyle)),
              SizedBox(width: 50, child: Text('CPU', style: _headerStyle, textAlign: TextAlign.right)),
              SizedBox(width: 44, child: Text('GPU', style: _headerStyle, textAlign: TextAlign.right)),
              SizedBox(width: 70, child: Text('Geheugen', style: _headerStyle, textAlign: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        ...rows.map((p) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  SizedBox(width: 50, child: Text('${p.pid}', style: const TextStyle(fontSize: 12))),
                  Expanded(
                    flex: 3,
                    child: Text(p.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                  ),
                  SizedBox(
                    width: 50,
                    child: Text('${p.cpuPercent.toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 12), textAlign: TextAlign.right),
                  ),
                  const SizedBox(
                    width: 44,
                    child: Text('—', style: TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.right),
                  ),
                  SizedBox(
                    width: 70,
                    child: Text('${(p.memoryKiB / 1024).toStringAsFixed(1)} MiB',
                        style: const TextStyle(fontSize: 12), textAlign: TextAlign.right),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}
