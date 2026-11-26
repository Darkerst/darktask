import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/power_freq_sample.dart';
import '../../services/power_freq_service.dart';
import '../../services/sensors/system_sensor_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/multi_line_chart.dart';

const _historyLength = 60;

class PowerFreqScreen extends StatefulWidget {
  /// Shared across every screen (owned by the top-level app shell) so
  /// the RAPL power-delta baseline survives tab switches.
  final SystemSensorService sensors;

  const PowerFreqScreen({super.key, required this.sensors});

  @override
  State<PowerFreqScreen> createState() => _PowerFreqScreenState();
}

class _PowerFreqScreenState extends State<PowerFreqScreen> {
  final PowerFreqService _service = PowerFreqService();
  SystemSensorService get _sensors => widget.sensors; // for CPU power (RAPL)
  Timer? _pollTimer;
  PowerFreqSample _sample = const PowerFreqSample();
  double? _cpuPowerWatts;
  bool _loading = true;
  bool _busy = false;

  // Battery health (design vs. full-charge capacity) barely changes
  // between one poll and the next — fetched once via readBattery()
  // and cached here rather than re-read on every poll tick, alongside
  // WindowsSensorService's own long-lived cache for the same
  // underlying WMI data.
  double? _batteryHealthPercent;
  int? _batteryCycleCount;
  bool _batteryHealthFetched = false;

  // Guards against overlapping poll ticks — the Windows path in
  // particular does several sequential PowerShell round-trips per
  // call (per-core clocks via LHM, max clock speed, power plan,
  // battery), which the very first call especially can take longer
  // than one poll interval to finish (LHM's own Add-Type + Open()
  // startup cost). Without this guard, a slow first call and the next
  // scheduled tick both end up sending commands into the same shared
  // PowerShellSession queue at once, and that pile-up compounds every
  // following tick rather than resolving itself — this was observed
  // and reproduced in testing as a sustained storm of PowerShell
  // timeouts, not a one-off hiccup.
  bool _isFetching = false;

  final Queue<double> _freqHistory = Queue<double>();
  final Queue<double> _powerHistory = Queue<double>();

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
    _load();
    _startPolling();
  }

  void _onSettingsChanged() => _startPolling();

  void _startPolling() {
    _pollTimer?.cancel();
    final intervalSeconds = SettingsService.instance.current.pollIntervalSeconds;
    if (intervalSeconds == 0) return; // paused — no repeating timer
    _pollTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  double? get _avgFreqMHz {
    final values = _sample.perCoreFrequencyMHz.whereType<double>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  Future<void> _load({bool silent = false}) async {
    // If a previous _load() (e.g. from the last poll tick) hasn't
    // finished yet, skip this tick entirely rather than starting a
    // second overlapping fetch — see _isFetching's doc comment above
    // for why letting these pile up is what actually caused the
    // PowerShell timeout storm this guard fixes.
    if (_isFetching) return;
    _isFetching = true;
    try {
      if (!silent) setState(() => _loading = true);
      // Independent reads, fired together rather than one after the
      // other — same fix, same reasoning, as MonitoringDashboard's and
      // PerformanceScreen's poll loops.
      final results = await Future.wait<dynamic>([_service.read(), _sensors.readCpuPowerWatts()]);
      final sample = results[0] as PowerFreqSample;
      final power = results[1] as double?;

      final avgFreq = sample.perCoreFrequencyMHz.whereType<double>().toList();
      if (avgFreq.isNotEmpty) {
        _freqHistory.addLast(avgFreq.reduce((a, b) => a + b) / avgFreq.length);
        if (_freqHistory.length > _historyLength) _freqHistory.removeFirst();
      }
      if (power != null) {
        _powerHistory.addLast(power);
        if (_powerHistory.length > _historyLength) _powerHistory.removeFirst();
      }

      if (mounted) {
        setState(() {
          _sample = sample;
          _cpuPowerWatts = power;
          _loading = false;
        });
      }

      // Fetched once, lazily, only once battery presence is confirmed —
      // avoids a wasted read on desktops with no battery at all.
      if (sample.hasBattery && !_batteryHealthFetched) {
        _batteryHealthFetched = true;
        final battery = await _sensors.readBattery();
        if (mounted) {
          setState(() {
            if (battery.healthPercent != null) _batteryHealthPercent = battery.healthPercent;
            if (battery.cycleCount != null) _batteryCycleCount = battery.cycleCount;
          });
        }
      }
    } finally {
      _isFetching = false;
    }
  }

  Future<void> _changeGovernor(String? governor) async {
    if (governor == null || governor == _sample.governor) return;
    setState(() => _busy = true);
    final success = await _service.setGovernor(governor);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? 'Governor ingesteld op "$governor"' : 'Kon governor niet wijzigen — zie Log')),
    );
    if (success) _load();
  }

  Future<void> _toggleTurbo(bool enabled) async {
    setState(() => _busy = true);
    final success = await _service.setTurboEnabled(enabled);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? 'Turbo ${enabled ? 'ingeschakeld' : 'uitgeschakeld'}' : 'Kon turbo niet wijzigen — zie Log')),
    );
    if (success) _load();
  }

  /// Frequency color-coding uses REAL bounds (min/max from sysfs), not
  /// an invented threshold — green when comfortably below max, orange
  /// approaching it, red essentially maxed out. There's no equivalent
  /// real ceiling for CPU power (no TDP data available), so that stays
  /// a single neutral color rather than fabricated thresholds.
  Color _freqColor(double? avgFreq) {
    final min = _sample.minFreqMHz;
    final max = _sample.maxFreqMHz;
    if (avgFreq == null || min == null || max == null || max <= min) return Colors.cyanAccent;
    final fraction = ((avgFreq - min) / (max - min)).clamp(0.0, 1.0);
    if (fraction > 0.85) return Colors.redAccent;
    if (fraction > 0.6) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = _sample;
    final avgFreq = _avgFreqMHz;
    final freqColor = _freqColor(avgFreq);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Header: title + status chip + refresh ---
            Row(
              children: [
                Text('Power & Freq', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(width: 12),
                Chip(
                  avatar: Icon(Icons.circle, size: 10, color: freqColor),
                  label: Text(s.governor ?? 'onbekend'),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                if (_busy)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load()),
              ],
            ),
            const SizedBox(height: 12),

            // --- Big numeric readouts: Frequency + Power, front and center ---
            Row(
              children: [
                Expanded(
                  child: _bigReadout(
                    label: 'FREQUENCY',
                    value: avgFreq != null ? (avgFreq / 1000).toStringAsFixed(2) : '—',
                    unit: 'GHz',
                    color: freqColor,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _bigReadout(
                    label: 'POWER',
                    value: _cpuPowerWatts != null ? _cpuPowerWatts!.toStringAsFixed(1) : '—',
                    unit: 'W',
                    color: Colors.yellowAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // --- Real-time scrolling graphs (side by side to save height) ---
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _section(
                    title: 'Frequentie',
                    icon: Icons.show_chart,
                    child: MultiLineChart(
                      height: 60,
                      minValue: s.minFreqMHz ?? 0,
                      maxValue: s.maxFreqMHz ?? (avgFreq ?? 100) * 1.1,
                      series: [ChartSeries(values: _freqHistory.toList(), color: freqColor, filled: true)],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _section(
                    title: 'Vermogen',
                    icon: Icons.bolt,
                    child: MultiLineChart(
                      height: 60,
                      minValue: 0,
                      maxValue: _powerHistory.isEmpty ? 1 : _powerHistory.reduce((a, b) => a > b ? a : b) * 1.2,
                      series: [ChartSeries(values: _powerHistory.toList(), color: Colors.yellowAccent, filled: true)],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (s.hasBattery) ...[
              _section(
                title: 'Batterij',
                icon: Icons.battery_std_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          s.batteryStatus == 'Charging' ? Icons.battery_charging_full : Icons.battery_std,
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${s.batteryPercent?.toStringAsFixed(0) ?? '—'}%',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 12),
                        Text(s.batteryStatus ?? 'onbekend', style: TextStyle(color: Colors.grey.shade500)),
                        const Spacer(),
                        if (s.acOnline != null)
                          Chip(label: Text(s.acOnline! ? 'Stroom aangesloten' : 'Op batterij')),
                      ],
                    ),
                    if (_batteryHealthPercent != null) ...[
                      const Divider(height: 20),
                      Row(
                        children: [
                          Icon(Icons.favorite_border, size: 18, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          const Text('Batterijgezondheid'),
                          const Spacer(),
                          Text(
                            '${_batteryHealthPercent!.toStringAsFixed(0)}%',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Huidige maximale capaciteit t.o.v. de originele, fabrieksnieuwe capaciteit — '
                        'daalt vanzelf naarmate de batterij ouder wordt.',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                      ),
                    ],
                    if (_batteryCycleCount != null) ...[
                      const Divider(height: 20),
                      Row(
                        children: [
                          Icon(Icons.autorenew, size: 18, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          const Text('Laadcycli'),
                          const Spacer(),
                          Text('$_batteryCycleCount', style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        // "Hours in use" isn't something either OS
                        // actually tracks — cycle count (one cycle =
                        // one full charge/discharge, spread over any
                        // number of partial charges) is the real,
                        // standard measure of how much a battery has
                        // been used, the same figure every OS's own
                        // battery report is built around.
                        'Aantal volledige laad-/ontlaadcycli — de gangbare maatstaf voor hoeveel de batterij '
                        'al gebruikt is (er bestaat geen betrouwbaar "aantal uren gebruikt").',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // --- Control panel ---
            _section(
              title: 'Bediening',
              icon: Icons.tune,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Governor', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                      if (s.availableGovernors.isNotEmpty)
                        DropdownButton<String>(
                          value: s.governor,
                          items: s.availableGovernors
                              .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                              .toList(),
                          onChanged: _busy ? null : _changeGovernor,
                        )
                      else
                        Text(s.governor ?? 'onbekend', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const Divider(height: 20),
                  _infoRow(
                    'Frequency driver',
                    s.frequencyDriver ?? (Platform.isWindows ? 'niet van toepassing (Windows)' : 'onbekend'),
                  ),
                  _infoRow(
                    'Frequentiebereik',
                    s.minFreqMHz != null && s.maxFreqMHz != null
                        ? '${(s.minFreqMHz! / 1000).toStringAsFixed(2)} – ${(s.maxFreqMHz! / 1000).toStringAsFixed(2)} GHz'
                        // Windows only ever supplies the rated maximum
                        // (Win32_Processor.MaxClockSpeed) — there's no
                        // stock-Windows equivalent of Linux's
                        // OS-adjustable scaling_min_freq, so showing
                        // "onbekend" for the whole range when max is
                        // genuinely known would hide real data rather
                        // than honestly represent a platform gap.
                        : s.maxFreqMHz != null
                            ? 'tot ${(s.maxFreqMHz! / 1000).toStringAsFixed(2)} GHz'
                            : 'onbekend',
                  ),
                  if (s.turboEnabled != null) ...[
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Turbo/Boost', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                        Switch(value: s.turboEnabled!, onChanged: _busy ? null : _toggleTurbo),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),

            // --- Per-core detail ---
            _section(
              title: 'Frequentie per kern',
              icon: Icons.memory_outlined,
              child: s.perCoreFrequencyMHz.isEmpty
                  ? Text('Geen frequentiegegevens beschikbaar', style: TextStyle(color: Colors.grey.shade600))
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < s.perCoreFrequencyMHz.length; i++)
                          Container(
                            width: 84,
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              children: [
                                Text('CPU $i', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                                const SizedBox(height: 2),
                                Text(
                                  s.perCoreFrequencyMHz[i] != null
                                      ? '${(s.perCoreFrequencyMHz[i]! / 1000).toStringAsFixed(2)} GHz'
                                      : '—',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bigReadout({required String label, required String value, required String unit, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.35), width: 1.5),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: Colors.grey.shade500)),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(width: 4),
              Text(unit, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color.withOpacity(0.7))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section({required String title, required IconData icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(10),
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
              Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
          const SizedBox(width: 8),
          // Expanded + right-aligned ellipsis: this shared helper is used
          // for values that can genuinely run long (e.g. the "niet van
          // toepassing (Windows)" fallback text), so an unconstrained
          // value Text next to a fixed label can overflow on a narrow
          // window — same overflow class fixed elsewhere in this app.
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
