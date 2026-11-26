import 'package:flutter/material.dart';

class BarChartEntry {
  final String label;
  final double value;
  final bool isCurrent;
  const BarChartEntry({required this.label, required this.value, this.isCurrent = false});
}

/// A simple horizontal bar chart — each entry gets a labeled bar sized
/// proportional to the highest value in the set. The "current" run
/// (if flagged) is highlighted in a brighter color so it stands out
/// among past runs from the same session.
class BenchmarkBarChart extends StatelessWidget {
  final List<BarChartEntry> entries;
  final Color color;
  final String Function(double value) formatValue;

  const BenchmarkBarChart({
    super.key,
    required this.entries,
    required this.color,
    required this.formatValue,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final maxValue = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries) _buildBarRow(context, entry, maxValue),
      ],
    );
  }

  Widget _buildBarRow(BuildContext context, BarChartEntry entry, double maxValue) {
    final fraction = maxValue > 0 ? (entry.value / maxValue).clamp(0.0, 1.0) : 0.0;
    final barColor = entry.isCurrent ? color : color.withOpacity(0.4);
    // Was hardcoded Colors.white for the "current run" label — invisible
    // against a light-mode background. onSurface always has good
    // contrast against the theme's own surface, in either brightness.
    final currentLabelColor = Theme.of(context).colorScheme.onSurface;
    final mutedLabelColor = Theme.of(context).colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              entry.label,
              style: TextStyle(
                fontSize: 11.5,
                color: entry.isCurrent ? currentLabelColor : mutedLabelColor,
                fontWeight: entry.isCurrent ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 14,
                backgroundColor: color.withOpacity(0.08),
                valueColor: AlwaysStoppedAnimation(barColor),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              formatValue(entry.value),
              style: TextStyle(
                fontSize: 11.5,
                color: entry.isCurrent ? currentLabelColor : mutedLabelColor,
                fontWeight: entry.isCurrent ? FontWeight.w600 : FontWeight.normal,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
