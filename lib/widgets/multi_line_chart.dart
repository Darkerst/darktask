import 'package:flutter/material.dart';

class ChartSeries {
  final List<double> values;
  final Color color;
  final bool filled;

  const ChartSeries({required this.values, required this.color, this.filled = false});
}

/// A larger, multi-series line chart with a light background grid —
/// used for the CPU Overview / Memory Utilization cards. Each series
/// is normalized independently against [maxValue] (or the series' own
/// max if maxValue is null), so temperature and utilization can share
/// one chart on different implicit scales, matching how the reference
/// layout overlays them.
class MultiLineChart extends StatelessWidget {
  final List<ChartSeries> series;
  final double minValue;
  final double maxValue;
  final double height;
  final Color backgroundColor;
  final Color gridColor;

  /// Optional soft glow drawn behind each line, 0 (off, default) to 1
  /// (strongest) — purely decorative, from the Colors screen's "Glow"
  /// slider.
  final double glowIntensity;

  const MultiLineChart({
    super.key,
    required this.series,
    this.minValue = 0,
    this.maxValue = 100,
    this.height = 160,
    this.backgroundColor = Colors.transparent,
    this.gridColor = Colors.grey,
    this.glowIntensity = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: CustomPaint(
        painter: _MultiLineChartPainter(
          series: series,
          minValue: minValue,
          maxValue: maxValue,
          gridColor: gridColor,
          glowIntensity: glowIntensity,
        ),
      ),
    );
  }
}

class _MultiLineChartPainter extends CustomPainter {
  final List<ChartSeries> series;
  final double minValue;
  final double maxValue;
  final Color gridColor;
  final double glowIntensity;

  _MultiLineChartPainter({
    required this.series,
    required this.minValue,
    required this.maxValue,
    required this.gridColor,
    this.glowIntensity = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = gridColor.withOpacity(0.15)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    for (var i = 0; i <= 6; i++) {
      final x = size.width * (i / 6);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    final range = (maxValue - minValue).clamp(0.0001, double.infinity);

    for (final s in series) {
      if (s.values.length < 2) continue;
      final stepX = size.width / (s.values.length - 1);

      final linePath = Path();
      final fillPath = Path();

      for (var i = 0; i < s.values.length; i++) {
        final normalized = ((s.values[i] - minValue) / range).clamp(0.0, 1.0);
        final x = stepX * i;
        final y = size.height - (normalized * size.height);
        if (i == 0) {
          linePath.moveTo(x, y);
          fillPath.moveTo(x, size.height);
          fillPath.lineTo(x, y);
        } else {
          linePath.lineTo(x, y);
          fillPath.lineTo(x, y);
        }
      }

      if (s.filled) {
        fillPath.lineTo(stepX * (s.values.length - 1), size.height);
        fillPath.close();
        final fillPaint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [s.color.withOpacity(0.25), s.color.withOpacity(0.0)],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
        canvas.drawPath(fillPath, fillPaint);
      }

      if (glowIntensity > 0) {
        // Blurred, wider, semi-transparent copy of the line drawn first
        // so the sharp line on top reads as "glowing" rather than the
        // whole chart just looking blurry — same trick as a CSS
        // box-shadow/text-shadow glow.
        final glowPaint = Paint()
          ..color = s.color.withOpacity(0.55 * glowIntensity)
          ..strokeWidth = 2 + 6 * glowIntensity
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 5 * glowIntensity);
        canvas.drawPath(linePath, glowPaint);
      }

      final linePaint = Paint()
        ..color = s.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(linePath, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MultiLineChartPainter oldDelegate) {
    // Same reasoning as _MiniGraphPainter/_SparkBarsPainter: skip the
    // repaint when nothing this painter actually draws from has
    // changed, instead of unconditionally repainting on every build
    // (e.g. a parent rebuild triggered by an unrelated setState).
    return oldDelegate.series != series ||
        oldDelegate.minValue != minValue ||
        oldDelegate.maxValue != maxValue ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.glowIntensity != glowIntensity;
  }
}
