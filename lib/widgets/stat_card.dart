import 'package:flutter/material.dart';

import 'mini_graph.dart';

/// A single dashboard tile: title, big current-value readout, a couple of
/// secondary readouts, and a history mini-graph underneath.
class StatCard extends StatelessWidget {
  final String title;
  final String primaryValue;
  final List<String> secondaryValues;
  final List<double> history;
  final Color accentColor;

  const StatCard({
    super.key,
    required this.title,
    required this.primaryValue,
    this.secondaryValues = const [],
    required this.history,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            primaryValue,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: accentColor,
            ),
          ),
          if (secondaryValues.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              children: secondaryValues
                  .map((v) => Text(
                        v,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 10),
          MiniGraph(values: history, color: accentColor),
        ],
      ),
    );
  }
}
