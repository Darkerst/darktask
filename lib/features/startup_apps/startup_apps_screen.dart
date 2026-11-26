import 'package:flutter/material.dart';

import '../../core/models/process_info.dart';
import '../../core/models/startup_app_entry.dart';
import '../../services/process_service.dart';
import '../../services/startup_apps_service.dart';

class StartupAppsScreen extends StatefulWidget {
  const StartupAppsScreen({super.key});

  @override
  State<StartupAppsScreen> createState() => _StartupAppsScreenState();
}

class _StartupAppsScreenState extends State<StartupAppsScreen> {
  final StartupAppsService _service = StartupAppsService();
  final ProcessService _processService = ProcessService();
  List<StartupAppEntry> _entries = [];
  // Keyed by StartupAppEntry.filePath (the same stable identifier the
  // rest of this screen already uses). Only ever holds an entry when a
  // currently-running process was actually matched — an app that
  // starts at logon and exits quickly (or just isn't running right
  // now) simply has no key here, which the UI renders as "Niet actief"
  // rather than a fabricated zero.
  Map<String, ProcessInfo> _matchedByFilePath = {};
  bool _loading = true;
  final Set<String> _toggling = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await _service.listEntries();
    // Best-effort only: a failed process read just means no impact
    // estimate is shown this refresh, never a reason to fail the whole
    // screen — the on/off toggles above are this screen's actual job.
    List<ProcessInfo> processes = const [];
    try {
      processes = await _processService.listProcesses();
    } catch (_) {
      processes = const [];
    }
    final matched = <String, ProcessInfo>{};
    for (final entry in entries) {
      final process = _matchRunningProcess(entry, processes);
      if (process != null) matched[entry.filePath] = process;
    }
    if (mounted) {
      setState(() {
        _entries = entries;
        _matchedByFilePath = matched;
        _loading = false;
      });
    }
  }

  /// Best-effort match between a startup entry and a currently-running
  /// process, by comparing executable basenames (case-insensitive,
  /// extension stripped) — same bidirectional-substring tolerance this
  /// app already uses elsewhere for name matching across two different
  /// data sources (see e.g. BenchmarkService._matchTestedGpuSample).
  /// Deliberately conservative: an unmatched entry shows as "Niet
  /// actief" rather than guessing, since a wrong match would attribute
  /// one app's resource use to a completely different one.
  ProcessInfo? _matchRunningProcess(StartupAppEntry entry, List<ProcessInfo> processes) {
    final raw = entry.execCommand ?? entry.filePath;
    // Strips a leading quoted path ("C:\Program Files\Foo\foo.exe" -arg)
    // or, failing that, just the first whitespace-separated token, then
    // the path and extension — leaving just "foo" to compare with.
    final quoted = RegExp(r'^"([^"]+)"').firstMatch(raw)?.group(1);
    final firstToken = quoted ?? raw.split(RegExp(r'\s+')).first;
    final base = firstToken
        .split(RegExp(r'[\\/]'))
        .last
        .replaceAll(RegExp(r'\.(exe|lnk)$', caseSensitive: false), '')
        .toLowerCase();
    if (base.isEmpty) return null;

    for (final p in processes) {
      final processBase = p.name.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '').toLowerCase();
      if (processBase == base || processBase.contains(base) || base.contains(processBase)) {
        return p;
      }
    }
    return null;
  }

  /// A genuinely-measured-data-derived label, not an invented category:
  /// buckets the matched process' CURRENT memory footprint into the
  /// same Licht/Gemiddeld/Zwaar language the rest of this app's
  /// benchmark intensities use. This measures steady-state resource
  /// use, not actual boot-time delay (a real "how much did this slow
  /// down logon" figure would need Windows' own ETW boot trace, which
  /// this app doesn't attempt to instrument) — the UI is explicit
  /// about that distinction rather than implying more precision than
  /// this actually has.
  ({String label, Color color}) _impactFor(ProcessInfo p) {
    final mb = p.memoryKiB / 1024;
    if (mb < 30) return (label: 'Licht', color: Colors.green);
    if (mb < 150) return (label: 'Gemiddeld', color: Colors.orange);
    return (label: 'Zwaar', color: Colors.red);
  }

  Future<void> _toggle(StartupAppEntry entry, bool newValue) async {
    setState(() => _toggling.add(entry.filePath));
    final success = await _service.setEnabled(entry, newValue);
    if (!mounted) return;
    setState(() => _toggling.remove(entry.filePath));

    if (success) {
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kon "${entry.name}" niet ${newValue ? 'inschakelen' : 'uitschakelen'}')),
      );
    }
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
              Text('Startup apps', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_entries.length} toepassingen die automatisch starten bij het inloggen',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          if (_entries.isEmpty)
            Expanded(
              child: Center(
                child: Text('Geen autostart-toepassingen gevonden', style: TextStyle(color: Colors.grey.shade600)),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  final isToggling = _toggling.contains(entry.filePath);
                  final matched = _matchedByFilePath[entry.filePath];
                  final impact = matched != null ? _impactFor(matched) : null;
                  return ListTile(
                    leading: const Icon(Icons.apps, size: 28),
                    title: Text(entry.name),
                    subtitle: Text(
                      [
                        if (entry.comment != null && entry.comment!.isNotEmpty) entry.comment!,
                        entry.isUserEntry ? 'Gebruiker' : 'Systeem',
                        if (entry.execCommand != null) entry.execCommand!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          message: matched != null
                              ? 'Schatting op basis van huidig geheugengebruik van dit al-lopende proces '
                                  '(${(matched.memoryKiB / 1024).toStringAsFixed(0)} MB, '
                                  '${matched.cpuPercent.toStringAsFixed(1)}% CPU nu) — geen meting van de '
                                  'daadwerkelijke opstartvertraging.'
                              : 'Dit proces draait nu niet (gestopt na opstarten, of niet actief), dus is er '
                                  'geen impact te meten.',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: (impact?.color ?? Colors.grey).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              impact?.label ?? 'Niet actief',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: impact?.color ?? Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        isToggling
                            ? const SizedBox(
                                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Switch(
                                value: entry.enabled,
                                onChanged: (v) => _toggle(entry, v),
                              ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
