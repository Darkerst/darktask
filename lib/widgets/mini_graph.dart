import 'package:flutter/material.dart';

/// A small, dependency-free line graph for a rolling window of values
/// (0-100 range by default). Used for the live CPU/RAM/GPU history strips
/// on the monitoring dashboard, in the spirit of TMOG's smooth-motion
/// mini-graphs — but hand-rolled so we're not pulling in a heavy charting
/// package just for a sparkline.
class MiniGraph extends StatelessWidget {
  final List<double> values;
  final double minValue;
  final double maxValue;
  final Color color;
  final double height;

  /// Optional soft glow drawn behind the line, 0 (off, default) to 1
  /// (strongest) — see MultiLineChart's identical parameter.
  final double glowIntensity;

  const MiniGraph({
    super.key,
    required this.values,
    this.minValue = 0,
    this.maxValue = 100,
    this.color = Colors.cyanAccent,
    this.height = 60,
    this.glowIntensity = 0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _MiniGraphPainter(
          values: values,
          minValue: minValue,
          maxValue: maxValue,
          color: color,
          glowIntensity: glowIntensity,
        ),
      ),
    );
  }
}

class _MiniGraphPainter extends CustomPainter {
  final List<double> values;
  final double minValue;
  final double maxValue;
  final Color color;
  final double glowIntensity;

  _MiniGraphPainter({
    required this.values,
    required this.minValue,
    required this.maxValue,
    required this.color,
    this.glowIntensity = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = color.withOpacity(0.08)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.length < 2) return;

    final range = (maxValue - minValue).clamp(0.0001, double.infinity);
    final stepX = size.width / (values.length - 1);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withOpacity(0.28), color.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final linePath = Path();
    final fillPath = Path();

    for (var i = 0; i < values.length; i++) {
      final normalized = ((values[i] - minValue) / range).clamp(0.0, 1.0);
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

    fillPath.lineTo(stepX * (values.length - 1), size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);

    if (glowIntensity > 0) {
      final glowPaint = Paint()
        ..color = color.withOpacity(0.55 * glowIntensity)
        ..strokeWidth = 2 + 6 * glowIntensity
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 5 * glowIntensity);
      canvas.drawPath(linePath, glowPaint);
    }

    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(covariant _MiniGraphPainter oldDelegate) {
    return oldDelegate.values != values;
  }
}
