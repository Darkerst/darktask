import 'package:flutter/material.dart';

/// A vertical segmented gauge: a stack of thin bars filled bottom-up in
/// proportion to [fraction] (0.0–1.0), unfilled segments shown dark.
/// Used for the compact CPU/Clock/Temp/GPU at-a-glance columns.
class VerticalGaugeBar extends StatelessWidget {
  final String topLabel;
  final String bottomValue;
  final double fraction; // 0.0–1.0
  final Color color;
  final int segments;
  final double barWidth;

  const VerticalGaugeBar({
    super.key,
    required this.topLabel,
    required this.bottomValue,
    required this.fraction,
    required this.color,
    this.segments = 22,
    this.barWidth = 18,
  });

  @override
  Widget build(BuildContext context) {
    // TweenAnimationBuilder with begin == end == the current target
    // value is the standard Flutter idiom for smoothly animating an
    // externally-driven number: on each rebuild (every poll, ~1-3s)
    // it detects the target changed and eases from whatever was
    // currently displayed to the new value, instead of the segments
    // instantly snapping — a small but real "feels alive" touch for a
    // dashboard that updates constantly.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: fraction, end: fraction),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      builder: (context, animatedFraction, _) {
        final filledCount = (animatedFraction.clamp(0.0, 1.0) * segments).round();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              topLabel,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: List.generate(segments, (i) {
                // i=0 is the top segment; fill from the bottom, so a
                // segment is lit when its index falls within the last
                // `filledCount`.
                final isFilled = i >= segments - filledCount;
                return Container(
                  width: barWidth,
                  height: 5,
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  decoration: BoxDecoration(
                    color: isFilled ? color : color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(1),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Text(
              bottomValue,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        );
      },
    );
  }
}
