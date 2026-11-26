import 'package:flutter/material.dart';

import '../models/app_settings.dart';

/// Identity colors for every metric that appears as a graph, gauge, or
/// sparkline somewhere in the app — one palette assigns all of these at
/// once, so a metric keeps the same color everywhere it's shown.
class GraphColors {
  final Color cpu;
  final Color cpuKernel;
  final Color cpuTemp;
  final Color cpuPower;
  final Color memory;
  final Color disk;
  final Color network;
  final Color gpu;
  final Color gpuTemp;
  final Color crypto;

  const GraphColors({
    required this.cpu,
    required this.cpuKernel,
    required this.cpuTemp,
    required this.cpuPower,
    required this.memory,
    required this.disk,
    required this.network,
    required this.gpu,
    required this.gpuTemp,
    required this.crypto,
  });
}

extension GraphPaletteColors on GraphPalette {
  /// Base colors for this palette, before the saturation setting is
  /// applied (see [applySaturation] / [GraphColorScheme]).
  GraphColors get baseColors {
    switch (this) {
      case GraphPalette.standard:
        // Matches DarkTask's original per-screen color choices as
        // closely as possible — existing users shouldn't see anything
        // change unless they deliberately pick a different palette.
        return const GraphColors(
          cpu: Colors.greenAccent,
          cpuKernel: Colors.redAccent,
          cpuTemp: Colors.orangeAccent,
          cpuPower: Colors.yellowAccent,
          memory: Colors.purpleAccent,
          disk: Colors.cyanAccent,
          network: Colors.tealAccent,
          gpu: Colors.lightBlueAccent,
          gpuTemp: Colors.deepOrangeAccent,
          crypto: Colors.pinkAccent,
        );
      case GraphPalette.green:
        // Classic monochrome-green phosphor terminal — every metric is
        // a shade of green, distinguished by brightness rather than hue.
        return const GraphColors(
          cpu: Color(0xFF39FF6A),
          cpuKernel: Color(0xFF00C853),
          cpuTemp: Color(0xFF76FF9C),
          cpuPower: Color(0xFF00E676),
          memory: Color(0xFF1DE9B6),
          disk: Color(0xFF64DD17),
          network: Color(0xFFB2FF59),
          gpu: Color(0xFF00BFA5),
          gpuTemp: Color(0xFFAEEA00),
          crypto: Color(0xFF00E5A0),
        );
      case GraphPalette.amber:
        // Classic amber phosphor terminal.
        return const GraphColors(
          cpu: Color(0xFFFFC107),
          cpuKernel: Color(0xFFFF6D00),
          cpuTemp: Color(0xFFFFAB00),
          cpuPower: Color(0xFFFFE082),
          memory: Color(0xFFFFD54F),
          disk: Color(0xFFFF9800),
          network: Color(0xFFFFCA28),
          gpu: Color(0xFFFFA726),
          gpuTemp: Color(0xFFFF7043),
          crypto: Color(0xFFFFD54F),
        );
      case GraphPalette.blue:
        return const GraphColors(
          cpu: Color(0xFF40C4FF),
          cpuKernel: Color(0xFF2979FF),
          cpuTemp: Color(0xFF00B0FF),
          cpuPower: Color(0xFF80D8FF),
          memory: Color(0xFF448AFF),
          disk: Color(0xFF18FFFF),
          network: Color(0xFF64B5F6),
          gpu: Color(0xFF536DFE),
          gpuTemp: Color(0xFF00E5FF),
          crypto: Color(0xFF7C4DFF),
        );
      case GraphPalette.mono:
        // Pure grayscale — every metric distinguished by brightness
        // only, for a minimal/high-contrast look.
        return const GraphColors(
          cpu: Color(0xFFEEEEEE),
          cpuKernel: Color(0xFF9E9E9E),
          cpuTemp: Color(0xFFBDBDBD),
          cpuPower: Color(0xFFE0E0E0),
          memory: Color(0xFFCFCFCF),
          disk: Color(0xFFA6A6A6),
          network: Color(0xFF8C8C8C),
          gpu: Color(0xFFD6D6D6),
          gpuTemp: Color(0xFF969696),
          crypto: Color(0xFFBFBFBF),
        );
    }
  }

  String get label {
    switch (this) {
      case GraphPalette.standard:
        return 'Standaard';
      case GraphPalette.green:
        return 'Classic Green';
      case GraphPalette.amber:
        return 'Amber';
      case GraphPalette.blue:
        return 'Blue';
      case GraphPalette.mono:
        return 'Monochrome';
    }
  }
}

/// Multiplies [base]'s HSL saturation by [saturation] (clamped to
/// 0.0–1.0 after multiplying), leaving hue and lightness untouched. A
/// saturation of 1.0 returns the color essentially unchanged; lower
/// values gradually pull it toward gray.
Color applySaturation(Color base, double saturation) {
  if (saturation >= 1.0) return base; // no-op fast path — also avoids
  // floating point round-trip through HSL for the (common) default.
  final hsl = HSLColor.fromColor(base);
  final adjusted = (hsl.saturation * saturation).clamp(0.0, 1.0);
  return hsl.withSaturation(adjusted).toColor();
}

/// Convenience bundle: a [GraphPalette]'s colors with the current
/// saturation setting already applied, so call sites just read
/// `scheme.cpu`, `scheme.memory`, etc. without repeating the
/// palette-lookup-then-adjust dance everywhere a graph needs a color.
class GraphColorScheme {
  final GraphColors _base;
  final double saturation;

  GraphColorScheme(GraphPalette palette, this.saturation) : _base = palette.baseColors;

  factory GraphColorScheme.fromSettings(AppSettings settings) =>
      GraphColorScheme(settings.graphPalette, settings.colorSaturation);

  Color get cpu => applySaturation(_base.cpu, saturation);
  Color get cpuKernel => applySaturation(_base.cpuKernel, saturation);
  Color get cpuTemp => applySaturation(_base.cpuTemp, saturation);
  Color get cpuPower => applySaturation(_base.cpuPower, saturation);
  Color get memory => applySaturation(_base.memory, saturation);
  Color get disk => applySaturation(_base.disk, saturation);
  Color get network => applySaturation(_base.network, saturation);
  Color get gpu => applySaturation(_base.gpu, saturation);
  Color get gpuTemp => applySaturation(_base.gpuTemp, saturation);
  Color get crypto => applySaturation(_base.crypto, saturation);
}
