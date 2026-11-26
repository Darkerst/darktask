import 'package:flutter/material.dart';

/// A full-width horizontal segmented gauge, filled left-to-right in
/// proportion to [fraction]. Used for the wide bar at the top of each
/// Performance detail view (e.g. the CPU utilization bar).
class HorizontalGaugeBar extends StatelessWidget {
  final double fraction; // 0.0–1.0
  final Color color;
  final int segments;
  final double height;

  const HorizontalGaugeBar({
    super.key,
    required this.fraction,
    required this.color,
    this.segments = 40,
    this.height = 28,
  });

  @override
  Widget build(BuildContext context) {
    // See VerticalGaugeBar's identical comment — same implicit-animation
    // idiom, applied here too so every gauge in the app eases between
    // values instead of only some of them.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: fraction, end: fraction),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      builder: (context, animatedFraction, _) {
        final filledCount = (animatedFraction.clamp(0.0, 1.0) * segments).round();
        return SizedBox(
          height: height,
          child: Row(
            children: List.generate(segments, (i) {
              final isFilled = i < filledCount;
              return Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: isFilled ? color : color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}
