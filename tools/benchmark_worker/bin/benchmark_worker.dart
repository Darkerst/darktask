// bin/benchmark_worker.dart
//
// Standalone, pure-Dart (GEEN Flutter) CLI-hulpprogramma dat straks als
// apart OS-proces wordt gestart door BenchmarkService bij de "zwaar"/
// "duurtest"-intensiteiten, in plaats van een Dart-isolate.
//
// WAAROM (root cause, bevestigd door het Dart-team zelf, zie
// dart-lang/sdk#51254 en flutter/flutter#161224): de Dart VM staat maar
// een vast, klein aantal isolates toe dat écht parallel mag draaien
// binnen ÉÉN VM-instantie, ongeacht het aantal CPU-cores — en spawnt
// daarbovenop nog eigen GC-hulpthreads (marker_tasks/compactor_tasks)
// zodra er genoeg garbage is opgebouwd. Een los OS-proces heeft zijn
// EIGEN Dart VM-instantie, dus die limiet geldt daar niet overheen —
// exact zoals stress-ng, AIDA64 en andere "echte" benchmarktools hun
// workers als losse processen draaien i.p.v. threads/isolates binnen
// één proces.
//
// Gebruik: benchmark_worker <cpu|crypto> <duur-in-ms>
// Output (één regel per ~200ms op stdout):
//   P <opsOfBytesSindsVorigeRapportage>
// En als laatste regel, zodra de duur voorbij is:
//   DONE
//
// Bevat BEWUST geen enkele Flutter-afhankelijkheid (geen
// package:flutter/...), zodat dit met "dart compile exe" compileert tot
// een kleine, losse, native executable zonder GTK/window-overhead —
// dus ook geen risico op een (ongewenst) leeg venster per workerproces.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('Gebruik: benchmark_worker <cpu|crypto> <duur-in-ms>');
    exit(64);
  }

  final mode = args[0];
  final durationMs = int.tryParse(args[1]);
  if (durationMs == null || durationMs <= 0) {
    stderr.writeln('Ongeldige duur: ${args[1]}');
    exit(64);
  }
  final duration = Duration(milliseconds: durationMs);

  switch (mode) {
    case 'cpu':
      await _runCpu(duration);
      break;
    case 'crypto':
      await _runCrypto(duration);
      break;
    default:
      stderr.writeln('Onbekende modus: $mode (verwacht "cpu" of "crypto")');
      exit(64);
  }
}

/// Identieke rekenlus als de huidige _cpuWorkerEntry in
/// benchmark_service.dart, zodat de score vergelijkbaar blijft met de
/// oude isolate-gebaseerde aanpak.
Future<void> _runCpu(Duration duration) async {
  final stopwatch = Stopwatch()..start();
  var opsSinceReport = 0;
  var lastReportMs = 0;
  var x = 1.000001;

  while (stopwatch.elapsed < duration) {
    for (var i = 0; i < 200000; i++) {
      x = x * 1.0000001 + 0.0000001;
      if (x > 1e6 || x.isNaN || x.isInfinite) x = 1.000001;
    }
    opsSinceReport += 200000;

    final nowMs = stopwatch.elapsedMilliseconds;
    if (nowMs - lastReportMs >= 200) {
      stdout.writeln('P $opsSinceReport');
      await stdout.flush();
      opsSinceReport = 0;
      lastReportMs = nowMs;
    }
  }
  if (opsSinceReport > 0) {
    stdout.writeln('P $opsSinceReport');
    await stdout.flush();
  }
  stdout.writeln('DONE');
  await stdout.flush();
}

/// Identieke hash-lus als de huidige _cryptoWorkerEntry in
/// benchmark_service.dart.
Future<void> _runCrypto(Duration duration) async {
  final stopwatch = Stopwatch()..start();
  final data = Uint8List(4 * 1024 * 1024);
  for (var i = 0; i < data.length; i += 4096) {
    data[i] = 1;
  }

  var bytesSinceReport = 0;
  var lastReportMs = 0;

  while (stopwatch.elapsed < duration) {
    sha256.convert(data);
    bytesSinceReport += data.length;

    final nowMs = stopwatch.elapsedMilliseconds;
    if (nowMs - lastReportMs >= 200) {
      stdout.writeln('P $bytesSinceReport');
      await stdout.flush();
      bytesSinceReport = 0;
      lastReportMs = nowMs;
    }
  }
  if (bytesSinceReport > 0) {
    stdout.writeln('P $bytesSinceReport');
    await stdout.flush();
  }
  stdout.writeln('DONE');
  await stdout.flush();
}
