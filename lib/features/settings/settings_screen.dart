import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/app_settings.dart';
import '../../core/theming/accent_theme.dart';
import '../../core/theming/app_theme.dart';
import '../../services/settings_service.dart';

/// Real, working settings — every control here changes actual app
/// behavior and is persisted to disk immediately, following the same
/// "no fake data, no stub controls" rule as the rest of DarkTask.
///
/// Categories loosely follow how established native system monitors
/// (e.g. TMOG) group their settings: update speed, interface/theming,
/// metric aggregation & layout, process management rules, and
/// confirmations/safety. One category from that list — remote/network
/// monitoring (broadcasting live telemetry to another device) — is
/// deliberately not here; see the note at the bottom of this screen for
/// why.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings = SettingsService.instance.current;

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() => _settings = SettingsService.instance.current);
  }

  Future<void> _resetToDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Standaardwaarden herstellen?'),
        content: const Text('Alle instellingen op deze pagina worden teruggezet naar hun standaardwaarde.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuleren')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Herstellen')),
        ],
      ),
    );
    if (confirmed == true) {
      await SettingsService.instance.resetToDefaults();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.settings_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 22),
                const SizedBox(width: 10),
                Text('Settings', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Alle instellingen hier werken echt en worden meteen opgeslagen — '
              'geen instellingen die niets doen.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
            ),
            const SizedBox(height: 24),
            _buildPollIntervalSection(),
            const SizedBox(height: 20),
            _buildAppearanceSection(),
            const SizedBox(height: 20),
            _buildLayoutSection(),
            const SizedBox(height: 20),
            _buildProcessManagementSection(),
            const SizedBox(height: 20),
            _buildConfirmationsSection(),
            const SizedBox(height: 20),
            _buildBenchmarkSafetySection(),
            const SizedBox(height: 20),
            if (Platform.isWindows || Platform.isLinux) ...[
              _buildTraySection(),
              const SizedBox(height: 20),
            ],
            _buildRemoteMonitoringNote(),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _resetToDefaults,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Standaardwaarden herstellen'),
              ),
            ),
            const SizedBox(height: 24),
            if (SettingsService.instance.filePath != null)
              Text(
                'Opgeslagen in: ${SettingsService.instance.filePath}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11, fontFamily: 'monospace'),
              ),
          ],
        ),
      ),
    );
  }

  /// Uses Material (not a plain Container+BoxDecoration) for the card
  /// background: several sections below contain a SwitchListTile, and
  /// ListTile-family widgets paint their background/ink splashes on the
  /// nearest Material ancestor. A DecoratedBox with its own color sits
  /// in between and hides that painting entirely — Flutter raises
  /// exactly this as a runtime assertion ("ListTile background color or
  /// ink splashes may be invisible") rather than silently rendering
  /// wrong. Making the card itself the Material ancestor fixes it at
  /// the source instead of special-casing every section that happens
  /// to contain a ListTile.
  Widget _sectionCard({required String title, required String description, required Widget child}) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Colors.grey.shade800),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
              const SizedBox(height: 4),
              Text(description, style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5)),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );
  }

  String _pollIntervalLabel(int seconds) => seconds == 0 ? 'Uit' : '${seconds}s';

  Widget _buildPollIntervalSection() {
    return _sectionCard(
      title: 'Bijwerksnelheid',
      description: 'Hoe vaak Summary, Performance en Power & Freq hun sensoren uitlezen. '
          '"Uit" pauzeert live verversing volledig — handig om de laatste meting even '
          'stil te zetten zonder het scherm te verlaten.',
      child: SegmentedButton<int>(
        segments: AppSettings.availablePollIntervals
            .map((s) => ButtonSegment(value: s, label: Text(_pollIntervalLabel(s))))
            .toList(),
        selected: {_settings.pollIntervalSeconds},
        onSelectionChanged: (selection) {
          SettingsService.instance.update((s) => s.copyWith(pollIntervalSeconds: selection.first));
        },
      ),
    );
  }

  Widget _buildAppearanceSection() {
    return _sectionCard(
      title: 'Uiterlijk',
      description: 'Licht/donker, accentkleur en tekstgrootte, app-breed toegepast.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Thema', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          SegmentedButton<AppThemeMode>(
            segments: AppThemeMode.values
                .map((mode) => ButtonSegment(value: mode, label: Text(mode.label)))
                .toList(),
            selected: {_settings.themeMode},
            onSelectionChanged: (selection) {
              SettingsService.instance.update((s) => s.copyWith(themeMode: selection.first));
            },
          ),
          const SizedBox(height: 16),
          const Text('Accentkleur', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: AppAccentTheme.values.map((theme) {
              final selected = theme == _settings.accentTheme;
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => SettingsService.instance.update((s) => s.copyWith(accentTheme: theme)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? theme.seedColor : Colors.grey.shade700,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(color: theme.seedColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(theme.label, style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          const Text('Tekstgrootte', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 0.9, label: Text('Klein')),
              ButtonSegment(value: 1.0, label: Text('Normaal')),
              ButtonSegment(value: 1.15, label: Text('Groot')),
            ],
            selected: {_settings.textScale},
            onSelectionChanged: (selection) {
              SettingsService.instance.update((s) => s.copyWith(textScale: selection.first));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLayoutSection() {
    return _sectionCard(
      title: 'Statistieken & indeling',
      description: 'Hoe telemetrie wordt gegroepeerd en waar de app standaard start.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Per-core CPU-grafieken tonen', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
              'Uit toont in Performance > CPU alleen de totale belasting, geen grid per logische kern.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
            ),
            value: _settings.showPerCoreCpu,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(showPerCoreCpu: value));
            },
          ),
          const SizedBox(height: 4),
          const Text('Standaard starttab', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          DropdownButton<int>(
            value: _settings.defaultStartupTabIndex,
            isDense: true,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Summary')),
              DropdownMenuItem(value: 1, child: Text('Performance')),
              DropdownMenuItem(value: 2, child: Text('Processes')),
              DropdownMenuItem(value: 3, child: Text('System Info')),
              DropdownMenuItem(value: 11, child: Text('Benchmarks')),
            ],
            onChanged: (value) {
              if (value == null) return;
              SettingsService.instance.update((s) => s.copyWith(defaultStartupTabIndex: value));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildProcessManagementSection() {
    return _sectionCard(
      title: 'Procesbeheer',
      description: 'Sorteervolgorde voor de Processes-lijst. Een geneste proces-boomweergave '
          '(parent/child) staat nog niet op de planning — ProcessInfo houdt momenteel geen '
          'parent-PID bij, dus dat zou eerst een eigen datamodel-uitbreiding vergen; liever dat '
          'eerlijk hier vermelden dan een schakelaar tonen die niets doet.',
      child: SegmentedButton<ProcessSortBy>(
        segments: const [
          ButtonSegment(value: ProcessSortBy.cpu, label: Text('CPU %')),
          ButtonSegment(value: ProcessSortBy.memory, label: Text('Geheugen')),
          ButtonSegment(value: ProcessSortBy.name, label: Text('Naam')),
        ],
        selected: {_settings.processSortBy},
        onSelectionChanged: (selection) {
          SettingsService.instance.update((s) => s.copyWith(processSortBy: selection.first));
        },
      ),
    );
  }

  Widget _buildConfirmationsSection() {
    return _sectionCard(
      title: 'Bevestigingen',
      description: 'Vraag om bevestiging voordat een proces wordt beëindigd of een service wordt '
          'gestopt/uitgeschakeld. Geldt niet voor het verwijderen van geïnstalleerde apps — die '
          'bevestiging (met het exacte commando) blijft altijd verplicht, ongeacht deze instelling.',
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bevestig risicovolle acties', style: TextStyle(fontSize: 13.5)),
        value: _settings.confirmDestructiveActions,
        onChanged: (value) {
          SettingsService.instance.update((s) => s.copyWith(confirmDestructiveActions: value));
        },
      ),
    );
  }

  Widget _buildBenchmarkSafetySection() {
    return _sectionCard(
      title: 'Benchmark-veiligheidsgrens',
      description: 'CPU-temperatuur waarbij een lopende CPU-benchmark zichzelf afbreekt in plaats '
          'van door te gaan. Alleen instelbaar binnen een veilige bandbreedte '
          '(${AppSettings.minCpuSafetyCutoffC.toStringAsFixed(0)}–'
          '${AppSettings.maxCpuSafetyCutoffC.toStringAsFixed(0)}°C).',
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: _settings.cpuSafetyCutoffC.clamp(
                AppSettings.minCpuSafetyCutoffC,
                AppSettings.maxCpuSafetyCutoffC,
              ),
              min: AppSettings.minCpuSafetyCutoffC,
              max: AppSettings.maxCpuSafetyCutoffC,
              divisions: (AppSettings.maxCpuSafetyCutoffC - AppSettings.minCpuSafetyCutoffC).round(),
              label: '${_settings.cpuSafetyCutoffC.toStringAsFixed(0)}°C',
              onChanged: (value) {
                SettingsService.instance.update((s) => s.copyWith(cpuSafetyCutoffC: value));
              },
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${_settings.cpuSafetyCutoffC.toStringAsFixed(0)}°C',
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTraySection() {
    return _sectionCard(
      title: 'Systeemvak & meldingen',
      description: 'Laat DarkTask op de achtergrond blijven draaien en waarschuw via een '
          'systeemmelding bij hoge CPU-temperatuur, weinig schijfruimte, hoog geheugengebruik, hoge '
          'GPU-temperatuur, netwerkpieken, hoog swap-gebruik, lage batterij of een zwaar belaste '
          'CPU-kern — ook terwijl het venster verborgen of niet actief is.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sluitknop verbergt naar systeemvak', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
              'Uit: de sluitknop van het venster sluit DarkTask direct af, zoals voor deze '
              'functie bestond.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
            ),
            value: _settings.minimizeToTrayEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(minimizeToTrayEnabled: value));
            },
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij hoge CPU-temperatuur', style: TextStyle(fontSize: 13.5)),
            value: _settings.cpuTempAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(cpuTempAlertEnabled: value));
            },
          ),
          if (_settings.cpuTempAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.cpuTempAlertC.clamp(
                        AppSettings.minCpuTempAlertC,
                        AppSettings.maxCpuTempAlertC,
                      ),
                      min: AppSettings.minCpuTempAlertC,
                      max: AppSettings.maxCpuTempAlertC,
                      divisions: (AppSettings.maxCpuTempAlertC - AppSettings.minCpuTempAlertC).round(),
                      label: '${_settings.cpuTempAlertC.toStringAsFixed(0)}°C',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(cpuTempAlertC: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.cpuTempAlertC.toStringAsFixed(0)}°C',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij weinig schijfruimte', style: TextStyle(fontSize: 13.5)),
            value: _settings.diskSpaceAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(diskSpaceAlertEnabled: value));
            },
          ),
          if (_settings.diskSpaceAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.diskSpaceAlertFreePercent.clamp(
                        AppSettings.minDiskSpaceAlertFreePercent,
                        AppSettings.maxDiskSpaceAlertFreePercent,
                      ),
                      min: AppSettings.minDiskSpaceAlertFreePercent,
                      max: AppSettings.maxDiskSpaceAlertFreePercent,
                      divisions: (AppSettings.maxDiskSpaceAlertFreePercent -
                              AppSettings.minDiskSpaceAlertFreePercent)
                          .round(),
                      label: 'onder ${_settings.diskSpaceAlertFreePercent.toStringAsFixed(0)}% vrij',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(diskSpaceAlertFreePercent: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.diskSpaceAlertFreePercent.toStringAsFixed(0)}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij hoog geheugengebruik', style: TextStyle(fontSize: 13.5)),
            value: _settings.memoryAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(memoryAlertEnabled: value));
            },
          ),
          if (_settings.memoryAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.memoryAlertPercent.clamp(
                        AppSettings.minMemoryAlertPercent,
                        AppSettings.maxMemoryAlertPercent,
                      ),
                      min: AppSettings.minMemoryAlertPercent,
                      max: AppSettings.maxMemoryAlertPercent,
                      divisions: (AppSettings.maxMemoryAlertPercent - AppSettings.minMemoryAlertPercent).round(),
                      label: '${_settings.memoryAlertPercent.toStringAsFixed(0)}%',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(memoryAlertPercent: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.memoryAlertPercent.toStringAsFixed(0)}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij hoge GPU-temperatuur', style: TextStyle(fontSize: 13.5)),
            value: _settings.gpuTempAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(gpuTempAlertEnabled: value));
            },
          ),
          if (_settings.gpuTempAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.gpuTempAlertC.clamp(
                        AppSettings.minGpuTempAlertC,
                        AppSettings.maxGpuTempAlertC,
                      ),
                      min: AppSettings.minGpuTempAlertC,
                      max: AppSettings.maxGpuTempAlertC,
                      divisions: (AppSettings.maxGpuTempAlertC - AppSettings.minGpuTempAlertC).round(),
                      label: '${_settings.gpuTempAlertC.toStringAsFixed(0)}°C',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(gpuTempAlertC: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.gpuTempAlertC.toStringAsFixed(0)}°C',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij netwerkpiek', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
              'Gebaseerd op ontvangen + verzonden verkeer, opgeteld over alle actieve netwerkadapters.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
            ),
            value: _settings.networkAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(networkAlertEnabled: value));
            },
          ),
          if (_settings.networkAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.networkAlertMBps.clamp(
                        AppSettings.minNetworkAlertMBps,
                        AppSettings.maxNetworkAlertMBps,
                      ),
                      min: AppSettings.minNetworkAlertMBps,
                      max: AppSettings.maxNetworkAlertMBps,
                      divisions:
                          (AppSettings.maxNetworkAlertMBps - AppSettings.minNetworkAlertMBps).round(),
                      label: '${_settings.networkAlertMBps.toStringAsFixed(0)} MB/s',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(networkAlertMBps: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      '${_settings.networkAlertMBps.toStringAsFixed(0)} MB/s',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij hoog swap-/pagefile-gebruik', style: TextStyle(fontSize: 13.5)),
            value: _settings.swapAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(swapAlertEnabled: value));
            },
          ),
          if (_settings.swapAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.swapAlertPercent.clamp(
                        AppSettings.minSwapAlertPercent,
                        AppSettings.maxSwapAlertPercent,
                      ),
                      min: AppSettings.minSwapAlertPercent,
                      max: AppSettings.maxSwapAlertPercent,
                      divisions: (AppSettings.maxSwapAlertPercent - AppSettings.minSwapAlertPercent).round(),
                      label: '${_settings.swapAlertPercent.toStringAsFixed(0)}%',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(swapAlertPercent: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.swapAlertPercent.toStringAsFixed(0)}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij lage batterij', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
              'Alleen terwijl de batterij ontlaadt — niet terwijl deze weer oplaadt door dezelfde grens heen.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
            ),
            value: _settings.batteryAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(batteryAlertEnabled: value));
            },
          ),
          if (_settings.batteryAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.batteryAlertPercent.clamp(
                        AppSettings.minBatteryAlertPercent,
                        AppSettings.maxBatteryAlertPercent,
                      ),
                      min: AppSettings.minBatteryAlertPercent,
                      max: AppSettings.maxBatteryAlertPercent,
                      divisions:
                          (AppSettings.maxBatteryAlertPercent - AppSettings.minBatteryAlertPercent).round(),
                      label: '${_settings.batteryAlertPercent.toStringAsFixed(0)}%',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(batteryAlertPercent: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.batteryAlertPercent.toStringAsFixed(0)}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Melding bij zwaar belaste CPU-kern', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
              'Per kern, onafhankelijk van de totale CPU-belasting — vangt een enkel vastgelopen proces '
              'op dat in het totaalpercentage nauwelijks opvalt op een systeem met veel kernen.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
            ),
            value: _settings.perCoreCpuAlertEnabled,
            onChanged: (value) {
              SettingsService.instance.update((s) => s.copyWith(perCoreCpuAlertEnabled: value));
            },
          ),
          if (_settings.perCoreCpuAlertEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _settings.perCoreCpuAlertPercent.clamp(
                        AppSettings.minPerCoreCpuAlertPercent,
                        AppSettings.maxPerCoreCpuAlertPercent,
                      ),
                      min: AppSettings.minPerCoreCpuAlertPercent,
                      max: AppSettings.maxPerCoreCpuAlertPercent,
                      divisions: (AppSettings.maxPerCoreCpuAlertPercent -
                              AppSettings.minPerCoreCpuAlertPercent)
                          .round(),
                      label: '${_settings.perCoreCpuAlertPercent.toStringAsFixed(0)}%',
                      onChanged: (value) {
                        SettingsService.instance.update((s) => s.copyWith(perCoreCpuAlertPercent: value));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_settings.perCoreCpuAlertPercent.toStringAsFixed(0)}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRemoteMonitoringNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Colors.grey.shade500),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Geen "remote monitoring" hier: sommige monitors kunnen live telemetrie naar een '
              'ander apparaat op je netwerk sturen. Dat vraagt om een eigen netwerklistener, '
              'authenticatie/pairing en versleuteling die zorgvuldig ontworpen moeten worden — '
              'niet iets om er terloops bij te bouwen. DarkTask blijft daarom volledig lokaal: '
              'geen open poorten, geen data die deze machine verlaat.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
