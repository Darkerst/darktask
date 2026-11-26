import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/app_settings.dart';
import '../../core/theming/graph_palette.dart';
import '../../services/settings_service.dart';
import '../../widgets/multi_line_chart.dart';

/// Real, working color customization for graphs and gauges app-wide —
/// distinct from Settings > Uiterlijk, which controls the single global
/// accent color used for buttons and selection chrome. This screen
/// controls the *metric identity* colors (CPU, memory, disk, network,
/// GPU, ...) that appear consistently across every chart, gauge, and
/// sparkline, plus saturation and an optional glow effect. Every
/// control here changes actual rendering immediately and persists to
/// disk — no swatches that don't do anything.
class ColorsScreen extends StatefulWidget {
  const ColorsScreen({super.key});

  @override
  State<ColorsScreen> createState() => _ColorsScreenState();
}

class _ColorsScreenState extends State<ColorsScreen> {
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

  Future<void> _resetColors() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kleuren herstellen?'),
        content: const Text('Palet, verzadiging en glow worden teruggezet naar standaard.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuleren')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Herstellen')),
        ],
      ),
    );
    if (confirmed == true) {
      await SettingsService.instance.update((s) => s.copyWith(
            graphPalette: AppSettings.defaults.graphPalette,
            colorSaturation: AppSettings.defaults.colorSaturation,
            glowIntensity: AppSettings.defaults.glowIntensity,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = GraphColorScheme.fromSettings(_settings);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 22),
                const SizedBox(width: 10),
                Text('Colors', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Kleuren voor grafieken en meters, app-breed. Voor de algemene accentkleur '
              '(knoppen, selectie) zie Settings > Uiterlijk.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            _buildPreview(colors),
            const SizedBox(height: 20),
            _buildPaletteSection(),
            const SizedBox(height: 20),
            _buildSaturationSection(),
            const SizedBox(height: 20),
            _buildGlowSection(),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _resetColors,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Kleuren herstellen'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// See the identical comment on SettingsScreen's _sectionCard: using
  /// Material (not Container+BoxDecoration) here too, so any
  /// ListTile-family widget added to a section later paints its
  /// background/ink correctly instead of silently (well — Flutter
  /// throws an assertion, so not silently) being hidden behind this
  /// card's own background color.
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

  /// Live preview using synthetic (non-random, seeded) wave data — not
  /// real telemetry, deliberately: the point is to see how the palette,
  /// saturation, and glow look together without waiting for real CPU
  /// activity to show every color, and it stays identical between
  /// renders so tweaking a slider doesn't also make the preview jitter.
  Widget _buildPreview(GraphColorScheme colors) {
    List<double> wave(double phase, double amplitude, double offset) {
      return List.generate(40, (i) {
        return offset + amplitude * (0.5 + 0.5 * math.sin((i / 40 * 2 * math.pi) + phase));
      });
    }

    return _sectionCard(
      title: 'Voorbeeld',
      description: 'Live weergave met voorbeelddata (geen echte metingen) van het huidige palet, '
          'de verzadiging en de glow-instelling hieronder.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MultiLineChart(
            height: 120,
            minValue: 0,
            maxValue: 100,
            glowIntensity: _settings.glowIntensity,
            series: [
              ChartSeries(values: wave(0, 35, 45), color: colors.cpu, filled: true),
              ChartSeries(values: wave(1.5, 20, 55), color: colors.memory),
              ChartSeries(values: wave(3.0, 25, 40), color: colors.network),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              _legendDot(colors.cpu, 'CPU'),
              _legendDot(colors.cpuKernel, 'Kernel'),
              _legendDot(colors.cpuTemp, 'Temp'),
              _legendDot(colors.cpuPower, 'Power'),
              _legendDot(colors.memory, 'Memory'),
              _legendDot(colors.disk, 'Disk'),
              _legendDot(colors.network, 'Network'),
              _legendDot(colors.gpu, 'GPU'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _buildPaletteSection() {
    return _sectionCard(
      title: 'Grafiekpalet',
      description: 'Wijst elke metriek (CPU, geheugen, schijf, netwerk, GPU, ...) een vaste '
          'kleur toe, consistent op elk scherm waar die metriek verschijnt.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: GraphPalette.values.map((palette) {
          final selected = palette == _settings.graphPalette;
          final swatch = palette.baseColors;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => SettingsService.instance.update((s) => s.copyWith(graphPalette: palette)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? Theme.of(context).colorScheme.primary : Colors.grey.shade700,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(palette.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                    for (final c in [
                      swatch.cpu,
                      swatch.memory,
                      swatch.disk,
                      swatch.network,
                      swatch.gpu,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                        ),
                      ),
                    if (selected) ...[
                      const SizedBox(width: 10),
                      Icon(Icons.check_circle, size: 18, color: Theme.of(context).colorScheme.primary),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSaturationSection() {
    return _sectionCard(
      title: 'Kleurverzadiging',
      description: 'Verlaagt de verzadiging van het hele grafiekpalet richting grijs, zonder tint of '
          'helderheid te veranderen. 100% laat kleuren ongewijzigd.',
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: _settings.colorSaturation.clamp(
                AppSettings.minColorSaturation,
                AppSettings.maxColorSaturation,
              ),
              min: AppSettings.minColorSaturation,
              max: AppSettings.maxColorSaturation,
              divisions: 16,
              label: '${(_settings.colorSaturation * 100).round()}%',
              onChanged: (value) {
                SettingsService.instance.update((s) => s.copyWith(colorSaturation: value));
              },
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '${(_settings.colorSaturation * 100).round()}%',
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlowSection() {
    return _sectionCard(
      title: 'Glow-effect',
      description: 'Zachte gloed achter grafieklijnen, in de kleur van de lijn zelf. Puur '
          'decoratief — heeft geen invloed op de weergegeven waarden.',
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: _settings.glowIntensity.clamp(0.0, 1.0),
              min: 0.0,
              max: 1.0,
              divisions: 10,
              label: _settings.glowIntensity == 0 ? 'Uit' : '${(_settings.glowIntensity * 100).round()}%',
              onChanged: (value) {
                SettingsService.instance.update((s) => s.copyWith(glowIntensity: value));
              },
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _settings.glowIntensity == 0 ? 'Uit' : '${(_settings.glowIntensity * 100).round()}%',
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
