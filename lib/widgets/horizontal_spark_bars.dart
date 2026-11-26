import 'package:flutter/material.dart';

/// A compact stat card with a row of thin vertical bars (left = oldest,
/// right = newest) instead of a line — the look used for the small
/// CPU Power / Thermals / Disk / Network cards.
class HorizontalSparkBarCard extends StatelessWidget {
  final String title;
  final String value;
  final List<double> history;
  final double maxValue;
  final Color color;

  const HorizontalSparkBarCard({
    super.key,
    required this.title,
    required this.value,
    required this.history,
    required this.maxValue,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              // Expanded + ellipsis rather than a bare Text: this card
              // gets narrower every time another one is added to the
              // same Row (e.g. a "GPU Thermals · AMD"/"· INTEL" pair on
              // a dual-GPU system), and an unconstrained title Text next
              // to the value Text overflows the Row's right edge once
              // the two combined no longer fit — the classic yellow/black
              // "RIGHT OVERFLOWED BY n PIXELS" banner. Ellipsizing keeps
              // the card usable at any width instead of just failing.
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
              const SizedBox(width: 6),
              Text(value, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 26,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparkBarsPainter(history: history, maxValue: maxValue, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkBarsPainter extends CustomPainter {
  final List<double> history;
  final double maxValue;
  final Color color;

  _SparkBarsPainter({required this.history, required this.maxValue, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    const barGap = 1.5;
    final barWidth = (size.width / history.length) - barGap;
    if (barWidth <= 0) return;

    final safeMax = maxValue <= 0 ? 1.0 : maxValue;
    final unfilledPaint = Paint()..color = color.withOpacity(0.12);
    final filledPaint = Paint()..color = color;

    for (var i = 0; i < history.length; i++) {
      final x = i * (barWidth + barGap);
      final fraction = (history[i] / safeMax).clamp(0.0, 1.0);
      final barHeight = size.height * fraction;

      // Unfilled background segment for the full bar height.
      canvas.drawRect(Rect.fromLTWH(x, 0, barWidth, size.height), unfilledPaint);
      // Filled portion, bottom-aligned.
      canvas.drawRect(
        Rect.fromLTWH(x, size.height - barHeight, barWidth, barHeight),
        filledPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparkBarsPainter oldDelegate) {
    // Same reasoning as _MiniGraphPainter: skip the repaint when this is
    // literally the same history list/max/color as last time (e.g. a
    // poll tick where this particular tile's data didn't change, or a
    // parent rebuild triggered by an unrelated setState elsewhere on
    // the same screen) instead of unconditionally repainting every
    // single build.
    return oldDelegate.history != history ||
        oldDelegate.maxValue != maxValue ||
        oldDelegate.color != color;
  }
}
