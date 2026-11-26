import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/logging/app_logger.dart';
import '../core/models/battery_energy_sample.dart';
import '../core/models/battery_sample.dart';
import '../core/models/benchmark_models.dart';
import '../core/models/cpu_detail_info.dart';
import '../core/models/cpu_sample.dart';
import '../core/models/disk_health_info.dart';
import '../core/models/disk_sample.dart';
import '../core/models/gpu_sample.dart';
import '../core/models/load_sample.dart';
import '../core/models/memory_sample.dart';
import '../core/models/network_sample.dart';
import '../core/models/system_info_sample.dart';
import 'benchmark_history_store.dart';
import 'report_icons.dart';
import 'report_snapshot_store.dart';
import 'sensors/system_sensor_service.dart';

const _logSource = 'ReportService';

/// A single donut/pie chart slice, shared between the HTML (SVG) and
/// PDF (pw.Chart) renderers so both are always built from the exact
/// same slice list — see [ReportService._svgDonut]/`pieChart` in
/// [ReportService._buildPdf].
typedef _Slice = ({String label, double value, String color});

/// One computed trend line ("+3°C t.o.v. vorige rapportage") for a
/// dashboard stat card — see [ReportService._trendHtml]/`_trendPdf`.
/// [direction] is -1/0/+1 purely for which way the little arrow points
/// (HTML only); [color] already encodes whether that direction is
/// good, bad, or neutral for this particular metric.
typedef _Trend = ({String label, String color, int direction});
typedef _TrendPdf = ({String label, PdfColor color});

/// The green/orange/red "Systeemstatus" verdict shown at the top of
/// both the HTML and PDF report — see [ReportService._computeVerdict]
/// for how [level] (0=goed, 1=let op, 2=kritiek) and [points] are
/// derived purely from already-computed, genuinely evaluable metrics.
typedef _Verdict = ({int level, String title, String summary, List<String> points});

/// Where [ReportService.generate] wrote the two report files — handed
/// back to the caller (the "Rapport exporteren" button) so it can show
/// both paths in one confirmation, same as every other export action in
/// this app (see e.g. LogViewerScreen._saveToFile,
/// BenchmarksScreen._exportHistoryCsv).
class ReportPaths {
  final String htmlPath;
  final String pdfPath;
  const ReportPaths({required this.htmlPath, required this.pdfPath});
}

/// Builds one combined "everything about this machine, right now"
/// report — static system specs, a live snapshot of every sensor this
/// app can read at the moment of export, and the full persisted
/// benchmark history ([BenchmarkHistoryStore]) — as both a styled HTML
/// file (opens in any browser, easy to skim on-screen) and a colored
/// PDF (for printing or handing to a customer). Both are built from the
/// exact same gathered snapshot, so they can never show different
/// numbers from each other.
///
/// Added on explicit request for a single "Rapport exporteren" button
/// that covers system info + current sensors + benchmark results
/// together, rather than the separate CSV-only benchmark export this
/// app already had (BenchmarksScreen._exportHistoryCsv, kept as-is —
/// this is an addition, not a replacement, since a raw CSV is still the
/// better fit for opening in a spreadsheet).
///
/// **Extended 2026-09-23** for "more detail, much clearer, more
/// color-coding, icons per component, and a first-page visual summary".
/// Since there is no actual photograph of the hardware to embed, "an
/// image of the hardware info" became a "Live overzicht" dashboard of
/// small colored, icon-labeled stat cards, forced onto its own first
/// PDF page via [pw.NewPage]. Every sub-section also got a matching
/// colored icon and, where genuinely meaningful, more detail fields.
///
/// **Extended again 2026-09-23** (same day, follow-up request) to match
/// a business-dashboard look the user shared as reference: solid-color
/// section banners, and real donut/bar/line charts (via hand-written
/// SVG in the HTML, and the `pdf` package's own `pw.Chart`/`PieDataSet`/
/// `BarDataSet`/`LineDataSet` widgets in the PDF — confirmed against
/// real usage examples before writing this, since that API is
/// documented as "in preview" and this can't be compiled here to
/// double-check), plus genuine trend arrows on the dashboard cards.
/// The reference dashboards compared figures to "6 months ago"; this
/// app has no such history for live sensor values (only benchmark runs
/// carry timestamps), so [ReportSnapshotStore] persists just the
/// *previous report's* dashboard figures and every trend is honestly
/// labeled "t.o.v. vorige rapportage" — the first report ever generated
/// on a machine has nothing to compare against and simply shows no
/// trend lines (see the class-level "no fabricated verdicts" reasoning
/// carried over from the rest of this app's sensor code).
/// Also carried over: load/clock/power-draw figures still never get a
/// good/bad color or a judged trend direction — only genuinely
/// evaluable figures (temperature, disk space used%, disk wear/
/// remaining-life%, battery health%) do. A trend on CPU load, for
/// instance, only ever gets a neutral color: higher load is not
/// inherently worse.
///
/// **Extended 2026-09-24** on explicit request ("kun je dit
/// integreren in mijn app?" → "alles") after several rounds of
/// standalone HTML mockups exploring report layout ideas:
/// - The hand-drawn SVG glyphs are replaced everywhere (both HTML and
///   PDF) by real images from a user-supplied icon set — see
///   report_icons.dart and [_iconImg]/`iconImg` below.
/// - A green/orange/red "Systeemstatus" verdict banner now sits right
///   under the header, in both outputs. [_computeVerdict] derives it
///   the same honest way as every trend arrow in this file: purely
///   from metrics this report already color-codes elsewhere
///   (temperature, disk space used%, disk/battery health%) — never a
///   generic template sentence, and never load/clock/power.
/// - A closing "Rapportinformatie" explainer and a "Nuttige links"
///   section are appended after the benchmark history, in both
///   outputs.
///
/// **Extended again 2026-09-24** (same day, follow-up feedback after
/// trying the above):
/// - Every icon doubled in size again (both outputs) — still not
///   "big enough" at the first pass.
/// - The disk-usage-per-volume/per-core-load bar chart's PDF side
///   ([barChartPdf]) is rewritten from the `pdf` package's own
///   pw.Chart/BarDataSet/CartesianGrid combo to a hand-built
///   Container/Row/Column widget: that combo is documented as "in
///   preview" and, per direct report, was rendering nothing. The HTML
///   side ([_barChartHtml]) is hardened the same way — a fixed pixel
///   height instead of a CSS percentage of a flex-resolved parent
///   height — even though it tested fine, to remove any remaining
///   doubt and keep both renderers on the same technique.
/// - The First Choice Computers contact card and the "Vragen over dit
///   rapport?" link (both HTML and PDF) are removed entirely, on
///   request — this report no longer names or links the shop.
///   "Darkerst Inc." (the software maker, not the shop) is unrelated
///   and stays in the header/footer attribution.
class ReportService {
  final SystemSensorService _sensors;
  const ReportService(this._sensors);

  Future<ReportPaths> generate() async {
    // Read the previous report's dashboard figures BEFORE this run's
    // snapshot overwrites them — see ReportSnapshotStore's class doc.
    const snapshotStore = ReportSnapshotStore();
    final previousSnapshot = await snapshotStore.readPrevious();

    // Gather everything up front, so a slow sensor read partway through
    // can't leave the HTML and PDF built from two different moments in
    // time — both are built below from these same, already-resolved
    // values.
    final info = await _sensors.readSystemInfo();
    final cpu = await _sensors.readCpu();
    final memory = await _sensors.readMemory();
    final gpus = await _sensors.readGpus();
    final disks = await _sensors.readDisks();
    List<DiskHealthInfo> diskHealth;
    try {
      diskHealth = await _sensors.readDiskHealth();
    } catch (e) {
      // Best-effort, same "never let one sensor take down the whole
      // report" reasoning as every other read here — an empty list
      // renders as "geen gegevens beschikbaar" further down rather than
      // aborting the entire export.
      AppLogger.instance.debug(_logSource, 'readDiskHealth() mislukte tijdens rapportage: $e');
      diskHealth = const [];
    }
    final battery = await _sensors.readBattery();

    // Extra detail sensors added for the 2026-09-23 "meer details"
    // expansion — every one wrapped the same defensive way as
    // readDiskHealth() above, since none of these are essential to a
    // usable report and some are Windows/Linux-specific in how much
    // they actually populate.
    final cpuDetails = await _safe(() => _sensors.readCpuDetails(), CpuDetailInfo.unknown(), label: 'readCpuDetails()');
    final cpuPowerWatts = await _safeNullable<double>(() => _sensors.readCpuPowerWatts(), label: 'readCpuPowerWatts()');
    final threadCount = await _safeNullable<int>(() => _sensors.readThreadCount(), label: 'readThreadCount()');
    final diskActivityPercent = await _safeNullable<double>(() => _sensors.readDiskActivity(), label: 'readDiskActivity()');
    List<NetworkSample> network;
    try {
      network = await _sensors.readNetwork();
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'readNetwork() mislukte tijdens rapportage: $e');
      network = const [];
    }
    final batteryEnergy =
        await _safeNullable<BatteryEnergySample>(() => _sensors.readBatteryEnergy(), label: 'readBatteryEnergy()');
    final load = await _safe(() => _sensors.readLoad(), LoadSample.empty(), label: 'readLoad()');

    // Newest first — "what did I just test" is almost always the more
    // relevant read order for a report than chronological.
    final benchmarks = BenchmarkHistoryStore.instance.entries.reversed.toList(growable: false);
    final generatedAt = DateTime.now();

    final data = _ReportData(
      generatedAt: generatedAt,
      info: info,
      cpu: cpu,
      cpuDetails: cpuDetails,
      cpuPowerWatts: cpuPowerWatts,
      threadCount: threadCount,
      diskActivityPercent: diskActivityPercent,
      load: load,
      memory: memory,
      gpus: gpus,
      disks: disks,
      diskHealth: diskHealth,
      network: network,
      battery: battery,
      batteryEnergy: batteryEnergy,
      benchmarks: benchmarks,
      previous: previousSnapshot,
    );

    final html = _buildHtml(data);
    final pdfBytes = await _buildPdf(data);

    // Persist this run's own dashboard figures so the *next* report can
    // show a genuine trend against them.
    await snapshotStore.save(ReportSnapshot(
      generatedAt: generatedAt,
      cpuTemperatureC: cpu.temperatureC,
      cpuLoadPercent: cpu.overallLoadPercent,
      gpuTemperaturesC: {for (final g in gpus) if (g.temperatureC != null) g.id: g.temperatureC!},
      gpuLoadPercent: {for (final g in gpus) if (g.loadPercent != null) g.id: g.loadPercent!},
      memoryUsedPercent: memory.usedPercent,
      diskUsedPercent: {for (final ds in disks) ds.device: ds.usedPercent},
      batteryCapacityPercent: battery.present ? battery.capacityPercent : null,
      batteryHealthPercent: battery.healthPercent,
    ));

    final timestamp = generatedAt.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final baseName = 'darktask_rapport_$timestamp';

    // Same save-location pattern as every other export in this app
    // (LogViewerScreen._saveToFile, BenchmarksScreen._exportHistoryCsv):
    // Downloads when the platform exposes one, else the app's own
    // documents folder.
    Directory? targetDir;
    try {
      targetDir = await getDownloadsDirectory();
    } catch (_) {
      targetDir = null;
    }
    targetDir ??= await getApplicationDocumentsDirectory();

    final htmlFile = File('${targetDir.path}/$baseName.html');
    await htmlFile.writeAsString(html);
    final pdfFile = File('${targetDir.path}/$baseName.pdf');
    await pdfFile.writeAsBytes(pdfBytes);

    AppLogger.instance.info(
      _logSource,
      'Rapport gegenereerd: ${htmlFile.path} en ${pdfFile.path} '
      '(${benchmarks.length} benchmarkregel(s) uit de geschiedenis meegenomen).',
    );

    return ReportPaths(htmlPath: htmlFile.path, pdfPath: pdfFile.path);
  }

  /// Runs [read], falling back to [fallback] (and a debug log line) on
  /// any failure — the same "one flaky sensor can't take down the
  /// whole report" reasoning already used for readDiskHealth() above,
  /// generalized so every extra detail sensor added in the 2026-09-23
  /// expansion doesn't need its own bespoke try/catch block.
  Future<T> _safe<T>(Future<T> Function() read, T fallback, {required String label}) async {
    try {
      return await read();
    } catch (e) {
      AppLogger.instance.debug(_logSource, '$label mislukte tijdens rapportage: $e');
      return fallback;
    }
  }

  /// Same as [_safe], for reads whose "unavailable" state is already
  /// represented by null rather than a dedicated fallback object.
  Future<T?> _safeNullable<T>(Future<T?> Function() read, {required String label}) async {
    try {
      return await read();
    } catch (e) {
      AppLogger.instance.debug(_logSource, '$label mislukte tijdens rapportage: $e');
      return null;
    }
  }

  // ==================================================================
  // Category colors — purely for visual organization/branding (see the
  // class doc above for why these are distinct from the semantic
  // green/orange/red status colors defined further down). One shared
  // set of hex strings for BOTH renderers: the HTML uses them directly
  // in inline CSS, the PDF converts them with PdfColor.fromHex — so the
  // two versions of the report can never drift into different colors
  // for the same category.
  // ==================================================================

  static const _accSystem = '#475569';
  static const _accOverview = '#4f46e5';
  static const _accSensors = '#1d4ed8';
  static const _accBenchmarks = '#db2777';
  static const _accCpu = '#2563eb';
  static const _accLoad = '#64748b';
  static const _accMem = '#0d9488';
  static const _accGpu = '#7c3aed';
  static const _accDisk = '#d97706';
  static const _accNetwork = '#0891b2';
  static const _accCrypto = '#65a30d';
  static const _accBattery = '#16a34a';

  /// A small hand-drawn (not a third-party icon set) glyph per
  /// category — plain geometric shapes only, so there's no font/asset
  /// dependency and nothing to license. `currentColor` lets each call
  /// site tint it via CSS without needing a separate colored variant.
  String _svgIcon(String name) {
    String shapes;
    switch (name) {
      case 'cpu':
        shapes = '<rect x="7" y="7" width="10" height="10" rx="1.5"/><rect x="9.5" y="9.5" width="5" height="5" rx="0.5"/>'
            '<line x1="7" y1="10" x2="4" y2="10"/><line x1="7" y1="14" x2="4" y2="14"/>'
            '<line x1="17" y1="10" x2="20" y2="10"/><line x1="17" y1="14" x2="20" y2="14"/>'
            '<line x1="10" y1="7" x2="10" y2="4"/><line x1="14" y1="7" x2="14" y2="4"/>'
            '<line x1="10" y1="17" x2="10" y2="20"/><line x1="14" y1="17" x2="14" y2="20"/>';
        break;
      case 'gpu':
        shapes = '<rect x="2.5" y="7" width="19" height="10" rx="2"/><circle cx="8" cy="12" r="2.4"/><circle cx="14" cy="12" r="2.4"/>'
            '<line x1="4.5" y1="17" x2="4.5" y2="19.5"/><line x1="19.5" y1="17" x2="19.5" y2="19.5"/>';
        break;
      case 'memory':
        shapes = '<rect x="6" y="2" width="12" height="17" rx="1.5"/>'
            '<line x1="9" y1="19" x2="9" y2="22"/><line x1="12" y1="19" x2="12" y2="22"/><line x1="15" y1="19" x2="15" y2="22"/>';
        break;
      case 'disk':
        shapes = '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2.2"/><line x1="12" y1="3" x2="12" y2="7"/>';
        break;
      case 'battery':
        shapes = '<rect x="3" y="8" width="15" height="8" rx="1.5"/><rect x="18.5" y="10.5" width="2" height="3" rx="0.6"/>';
        break;
      case 'network':
        shapes = '<line x1="6" y1="18" x2="6" y2="14"/><line x1="11" y1="18" x2="11" y2="10"/><line x1="16" y1="18" x2="16" y2="6"/>';
        break;
      case 'system':
        shapes = '<rect x="3" y="4" width="18" height="12" rx="1.5"/><line x1="8" y1="20" x2="16" y2="20"/><line x1="12" y1="16" x2="12" y2="20"/>';
        break;
      case 'gauge':
        shapes = '<path d="M4 15a8 8 0 1 1 16 0"/><line x1="12" y1="15" x2="15.5" y2="10"/><circle cx="12" cy="15" r="1.2"/>';
        break;
      default:
        shapes = '<circle cx="12" cy="12" r="9"/>';
    }
    return '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" '
        'stroke-linecap="round" stroke-linejoin="round">$shapes</svg>';
  }

  /// Wraps one of the images in [reportIconPngBase64] (see that file's
  /// doc — a user-supplied icon set, replacing the earlier hand-drawn
  /// [_svgIcon] glyphs above) as a `data:` URI for direct use in an
  /// HTML `<img src="...">`.
  String _iconDataUri(String key) => 'data:image/png;base64,${reportIconPngBase64[key]}';

  /// Renders a [reportIconPngBase64] image at the given pixel size.
  /// These tiles already carry their own background/shading (unlike
  /// the old `currentColor` SVGs), so there's no accent-color circle
  /// to draw behind them here — just a soft border-radius so the
  /// square PNG corners match the rounded look used everywhere else in
  /// this report.
  String _iconImg(String key, {required double size, required double radius}) {
    final s = size.toStringAsFixed(0);
    return '<img src="${_iconDataUri(key)}" width="$s" height="$s" '
        'style="display:block;border-radius:${radius.toStringAsFixed(0)}px" alt="">';
  }

  /// Small check/warning/× glyph for the verdict banner — unlike the
  /// hardware-category icons above, this is generic UI chrome (not a
  /// photo of a component), so a plain hand-drawn SVG stays appropriate
  /// here, same reasoning as [_trendArrowSvg].
  String _verdictIconSvg(int level) {
    switch (level) {
      case 2:
        return '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#fff" stroke-width="2" '
            'stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/>'
            '<line x1="12" y1="8" x2="12" y2="13"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>';
      case 1:
        return '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#fff" stroke-width="2" '
            'stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z"/>'
            '<path d="M12 9v4"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>';
      default:
        return '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#fff" stroke-width="2" '
            'stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
    }
  }

  /// Small "i" info-circle glyph for the closing "Rapportinformatie"
  /// card's heading — same reasoning as [_verdictIconSvg]: generic UI
  /// chrome, not a hardware photo.
  String _infoIconSvg() => '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="#93c5fd" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/>'
      '<path d="M12 16v-4"/><path d="M12 8h.01"/></svg>';

  /// Tiny filled triangle, used only for the HTML trend lines (see
  /// class doc: the PDF relies on the +/− sign already in the trend
  /// label text instead, since the PDF's core font isn't guaranteed to
  /// carry an arrow glyph).
  String _trendArrowSvg(bool up, String color) =>
      '<svg viewBox="0 0 10 10" width="9" height="9" style="vertical-align:middle">'
      '${up ? '<polygon points="5,1 9,8 1,8" fill="$color"/>' : '<polygon points="5,9 1,2 9,2" fill="$color"/>'}'
      '</svg>';

  DiskSample? _worstDisk(List<DiskSample> disks) =>
      disks.isEmpty ? null : disks.reduce((a, b) => a.usedPercent >= b.usedPercent ? a : b);

  String _networkTypeLabel(NetworkInterfaceType t) {
    switch (t) {
      case NetworkInterfaceType.ethernet:
        return 'Ethernet';
      case NetworkInterfaceType.wifi:
        return 'WiFi';
      case NetworkInterfaceType.other:
        return 'Overig';
    }
  }

  String _benchmarkTypeAccent(BenchmarkType t) {
    switch (t) {
      case BenchmarkType.cpu:
        return _accCpu;
      case BenchmarkType.memory:
        return _accMem;
      case BenchmarkType.disk:
        return _accDisk;
      case BenchmarkType.network:
        return _accNetwork;
      case BenchmarkType.crypto:
        return _accCrypto;
      case BenchmarkType.gpu:
        return _accGpu;
    }
  }

  static const _diskPalette = ['#d97706', '#f59e0b', '#fbbf24', '#92400e', '#b45309', '#78350f'];

  /// One trend line, or null when there's genuinely nothing to compare
  /// against (no previous report, or this particular value/GPU/disk
  /// wasn't available last time either) — never a fabricated "0%
  /// change". [goodDirection]: -1 = lower is better (temperature,
  /// used%), +1 = higher is better (battery health%), 0 = neither
  /// direction is "bad" (load/clock/power) — that case only ever gets
  /// the neutral color, same "no judged verdict where none is
  /// warranted" reasoning as the rest of this class.
  _Trend? _trendHtml(double? current, double? previous, {required String unit, int goodDirection = 0, int decimals = 0}) {
    if (current == null || previous == null) return null;
    final delta = current - previous;
    final threshold = decimals == 0 ? 0.5 : 0.05;
    if (delta.abs() < threshold) {
      return (label: 'Gelijk t.o.v. vorige rapportage', color: _muted, direction: 0);
    }
    final sign = delta > 0 ? '+' : '';
    final label = '$sign${delta.toStringAsFixed(decimals)}$unit t.o.v. vorige rapportage';
    final direction = delta > 0 ? 1 : -1;
    if (goodDirection == 0) return (label: label, color: _muted, direction: direction);
    final improved = goodDirection > 0 ? delta > 0 : delta < 0;
    return (label: label, color: improved ? _green : _red, direction: direction);
  }

  _TrendPdf? _trendPdf(double? current, double? previous, {required String unit, int goodDirection = 0, int decimals = 0}) {
    if (current == null || previous == null) return null;
    final delta = current - previous;
    final threshold = decimals == 0 ? 0.5 : 0.05;
    if (delta.abs() < threshold) {
      return (label: 'Gelijk t.o.v. vorige rapportage', color: PdfColors.grey500);
    }
    final sign = delta > 0 ? '+' : '';
    final label = '$sign${delta.toStringAsFixed(decimals)}$unit t.o.v. vorige rapportage';
    if (goodDirection == 0) return (label: label, color: PdfColors.grey500);
    final improved = goodDirection > 0 ? delta > 0 : delta < 0;
    return (label: label, color: improved ? PdfColors.green700 : PdfColors.red700);
  }

  /// Derives the "Systeemstatus" verdict banner purely from metrics
  /// this report already color-codes elsewhere (CPU/GPU temperature,
  /// worst disk used%, disk SMART remaining-life%, battery health%) —
  /// never load/clock/power, and never a fabricated "everything is
  /// fine" when it isn't. Shared between [_buildHtml] and [_buildPdf]
  /// so both renderers always show the exact same verdict for the
  /// exact same underlying data. See the class doc's "Extended
  /// 2026-09-24" note and the long-standing "no fabricated verdicts"
  /// reasoning carried throughout this file.
  _Verdict _computeVerdict(_ReportData d, DiskSample? worstDisk) {
    final points = <({int level, String text})>[];

    void addTemp(String label, double? c) {
      if (c == null) return;
      final lvl = c < 60 ? 0 : (c < 80 ? 1 : 2);
      if (lvl > 0) {
        points.add((
          level: lvl,
          text: '$label-temperatuur is ${c.toStringAsFixed(0)}°C — ${lvl == 2 ? 'kritiek hoog' : 'aan de hoge kant'}.',
        ));
      }
    }

    addTemp('CPU', d.cpu.temperatureC);
    for (final g in d.gpus) {
      addTemp('GPU (${g.name})', g.temperatureC);
    }

    if (worstDisk != null) {
      final v = worstDisk.usedPercent;
      final lvl = v < 60 ? 0 : (v < 85 ? 1 : 2);
      if (lvl > 0) {
        final label = worstDisk.mountPoint.isNotEmpty ? worstDisk.mountPoint : worstDisk.device;
        points.add((
          level: lvl,
          text: 'Schijf ($label) is met ${v.toStringAsFixed(1)}% ${lvl == 2 ? 'bijna vol' : 'behoorlijk vol'} — opschonen wordt aangeraden.',
        ));
      }
    }

    for (final dh in d.diskHealth) {
      final life = dh.lifeRemainingPercent;
      if (life == null) continue;
      final effective = 100 - life;
      final lvl = effective < 60 ? 0 : (effective < 85 ? 1 : 2);
      if (lvl > 0) {
        points.add((level: lvl, text: 'Schijf ${dh.deviceId} heeft nog maar ${life.toStringAsFixed(0)}% resterende levensduur.'));
      }
    }

    if (d.battery.present && d.battery.healthPercent != null) {
      final h = d.battery.healthPercent!;
      final effective = 100 - h;
      final lvl = effective < 60 ? 0 : (effective < 85 ? 1 : 2);
      if (lvl > 0) {
        points.add((level: lvl, text: 'Batterijgezondheid is gedaald tot ${h.toStringAsFixed(0)}% van de oorspronkelijke capaciteit.'));
      }
    }

    final level = points.isEmpty ? 0 : points.map((p) => p.level).reduce((a, b) => a > b ? a : b);
    final title = level == 0 ? 'Systeemstatus: Goed' : (level == 1 ? 'Systeemstatus: Let op' : 'Systeemstatus: Kritiek');

    final String summary;
    if (level == 0) {
      final checkedItems = <String>[
        'temperatuur',
        'schijfruimte',
        'schijfgezondheid',
        if (d.battery.present) 'batterijgezondheid',
      ];
      summary = 'Dit systeem is gecontroleerd en werkt naar behoren. Geen van de gemeten waarden '
          '(${checkedItems.join(', ')}) geeft aanleiding tot zorgen.';
    } else if (level == 1) {
      summary = points.length == 1
          ? 'Over het algemeen werkt dit systeem goed. Eén aandachtspunt gevonden — zie hieronder.'
          : 'Over het algemeen werkt dit systeem goed. ${points.length} aandachtspunten gevonden — zie hieronder.';
    } else {
      final criticalCount = points.where((p) => p.level == 2).length;
      summary = 'Bij het controleren van dit systeem ${criticalCount == 1 ? 'is één kritiek punt' : 'zijn kritieke punten'} '
          'gevonden die op korte termijn aandacht verdienen.';
    }

    final List<String> displayPoints;
    if (level == 0) {
      displayPoints = [
        'Alle temperaturen (CPU${d.gpus.isNotEmpty ? '/GPU' : ''}) binnen normale grenzen',
        if (d.disks.isNotEmpty) 'Voldoende vrije schijfruimte op alle volumes',
        if (d.diskHealth.hasAnyMeaningfulData && d.battery.present)
          'Geen tekenen van slijtage aan schijven of batterij'
        else if (d.diskHealth.hasAnyMeaningfulData)
          'Geen tekenen van slijtage aan schijven'
        else if (d.battery.present)
          'Geen tekenen van slijtage aan de batterij',
      ];
    } else {
      final sorted = [...points]..sort((a, b) => b.level.compareTo(a.level));
      displayPoints = [for (final p in sorted) p.text];
    }

    return (level: level, title: title, summary: summary, points: displayPoints);
  }

  // ==================================================================
  // HTML
  // ==================================================================

  String _buildHtml(_ReportData d) {
    final worstDisk = _worstDisk(d.disks);
    final trendCpu = _trendHtml(d.cpu.temperatureC, d.previous?.cpuTemperatureC, unit: '°C', goodDirection: -1);
    final trendMem = _trendHtml(d.memory.usedPercent, d.previous?.memoryUsedPercent, unit: '%', goodDirection: -1, decimals: 1);
    final trendDisk = worstDisk != null
        ? _trendHtml(worstDisk.usedPercent, d.previous?.diskUsedPercent[worstDisk.device], unit: '%', goodDirection: -1, decimals: 1)
        : null;
    final trendBattery = d.battery.healthPercent != null
        ? _trendHtml(d.battery.healthPercent, d.previous?.batteryHealthPercent, unit: '%', goodDirection: 1, decimals: 1)
        : null;
    final verdict = _computeVerdict(d, worstDisk);
    final verdictClass = verdict.level == 0 ? 'good' : (verdict.level == 1 ? 'warn' : 'bad');

    final b = StringBuffer();
    b.writeln('<!DOCTYPE html>');
    b.writeln('<html lang="nl">');
    b.writeln('<head>');
    b.writeln('<meta charset="utf-8">');
    b.writeln('<title>DarkTask rapport — ${_esc(d.info.hostname)}</title>');
    b.writeln('<style>${_css}</style>');
    b.writeln('</head>');
    b.writeln('<body>');
    b.writeln('<div class="page">');

    // --- Header banner --------------------------------------------
    b.writeln('<header class="banner">');
    b.writeln('<h1>DarkTask systeemrapport</h1>');
    b.writeln('<p class="sub">${_esc(d.info.hostname)} · gegenereerd op ${_fmtDateTime(d.generatedAt)}</p>');
    b.writeln('<p class="sub small">Darkerst Inc. — DarkTask</p>');
    b.writeln('</header>');

    // --- Systeemstatus verdict-banner ---------------------------------
    // See _computeVerdict's doc: derived purely from metrics already
    // color-coded further down in this same report, never fabricated.
    b.writeln('<div class="verdict-banner $verdictClass">');
    b.writeln('<div class="verdict-icon">${_verdictIconSvg(verdict.level)}</div>');
    b.writeln('<div class="verdict-text">');
    b.writeln('<h2>${_esc(verdict.title)}</h2>');
    b.writeln('<p>${_esc(verdict.summary)}</p>');
    if (verdict.points.isNotEmpty) {
      b.writeln('<ul>');
      for (final p in verdict.points) {
        b.writeln('<li>${_esc(p)}</li>');
      }
      b.writeln('</ul>');
    }
    b.writeln('</div>');
    b.writeln('</div>');

    // --- Live overzicht (dashboard) -----------------------------------
    // "Eerste blad"/at-a-glance summary — see the class doc for why
    // this is a colored stat-card dashboard rather than an actual
    // photograph.
    b.writeln(_sectionOpen('Live overzicht', icon: 'gauge', accent: _accOverview));
    if (d.previous == null) {
      b.writeln('<p class="muted">Dit is de eerste rapportage van dit apparaat — trends t.o.v. een vorige '
          'rapportage verschijnen vanaf de volgende keer.</p>');
    }
    b.writeln('<div class="cards">');
    b.writeln(_statCardHtml(
      icon: 'cpu',
      accent: _accCpu,
      title: 'CPU',
      bigValue: _fmtTemp(d.cpu.temperatureC),
      bigValueColor: _tempColorHex(d.cpu.temperatureC),
      lines: [
        'Belasting: ${_fmtPercent(d.cpu.overallLoadPercent)}',
        if (d.cpu.clockMHz != null) '${d.cpu.clockMHz!.toStringAsFixed(0)} MHz',
      ],
      dotColor: _tempColorHex(d.cpu.temperatureC),
      trend: trendCpu,
    ));
    for (final g in d.gpus.take(2)) {
      final title = g.name.length > 22 ? '${g.name.substring(0, 22)}…' : g.name;
      final trendGpu = _trendHtml(g.temperatureC, d.previous?.gpuTemperaturesC[g.id], unit: '°C', goodDirection: -1);
      b.writeln(_statCardHtml(
        icon: 'gpu',
        accent: _accGpu,
        title: title,
        bigValue: _fmtTemp(g.temperatureC),
        bigValueColor: _tempColorHex(g.temperatureC),
        lines: [
          if (g.loadPercent != null) 'Belasting: ${_fmtPercent(g.loadPercent!)}',
          if (g.powerDrawWatts != null) 'Vermogen: ${g.powerDrawWatts!.toStringAsFixed(1)} W',
        ],
        dotColor: _tempColorHex(g.temperatureC),
        trend: trendGpu,
      ));
    }
    b.writeln(_statCardHtml(
      icon: 'memory',
      accent: _accMem,
      title: 'Geheugen',
      bigValue: _fmtPercent(d.memory.usedPercent),
      bigValueColor: _percentColorHex(d.memory.usedPercent, highIsBad: true),
      lines: ['${_fmtKiB(d.memory.usedKiB)} / ${_fmtKiB(d.memory.totalKiB)}'],
      dotColor: _percentColorHex(d.memory.usedPercent, highIsBad: true),
      trend: trendMem,
    ));
    if (worstDisk != null) {
      b.writeln(_statCardHtml(
        icon: 'disk',
        accent: _accDisk,
        title: 'Schijf (${worstDisk.mountPoint})',
        bigValue: _fmtPercent(worstDisk.usedPercent),
        bigValueColor: _percentColorHex(worstDisk.usedPercent, highIsBad: true),
        lines: ['${_fmtBytesGiB(worstDisk.usedBytes)} / ${_fmtBytesGiB(worstDisk.totalBytes)}'],
        dotColor: _percentColorHex(worstDisk.usedPercent, highIsBad: true),
        trend: trendDisk,
      ));
    }
    if (d.battery.present) {
      b.writeln(_statCardHtml(
        icon: 'battery',
        accent: _accBattery,
        title: 'Batterij',
        bigValue: '${d.battery.capacityPercent ?? '?'}%',
        bigValueColor: '#1e293b',
        lines: [
          d.battery.status ?? 'onbekend',
          if (d.battery.healthPercent != null) 'Gezondheid: ${_fmtPercent(d.battery.healthPercent!)}',
        ],
        dotColor: d.battery.healthPercent != null ? _percentColorHex(d.battery.healthPercent!, highIsBad: false) : null,
        trend: trendBattery,
      ));
    }
    b.writeln('</div>');
    if (d.gpus.length > 2) {
      b.writeln('<p class="muted">+ ${d.gpus.length - 2} andere GPU(\'s) — zie de tabel verderop.</p>');
    }
    b.writeln(_sectionClose());

    // --- Systeeminformatie ------------------------------------------
    b.writeln(_sectionOpen('Systeeminformatie', icon: 'system', accent: _accSystem));
    b.writeln('<table class="kv">');
    b.writeln(_kvRow('Hostname', d.info.hostname));
    b.writeln(_kvRow('Besturingssysteem', d.info.osName));
    b.writeln(_kvRow('Kernel', d.info.kernelVersion));
    b.writeln(_kvRow('Architectuur', d.info.architecture));
    b.writeln(_kvRow('Uptime', _fmtDuration(d.info.uptime)));
    b.writeln(_kvRow('CPU', '${d.info.cpuModel} (${d.info.cpuCores} cores)'));
    b.writeln(_kvRow('Geheugen (totaal)', _fmtGiB(d.info.totalMemoryGiB)));
    b.writeln(_kvRow('GPU(\'s)', d.info.gpuNames.isNotEmpty ? d.info.gpuNames.join(', ') : 'geen gevonden'));
    if (d.info.systemVendor != null || d.info.systemModel != null) {
      b.writeln(_kvRow('Systeem', [d.info.systemVendor, d.info.systemModel].where((s) => s != null && s.isNotEmpty).join(' ')));
    }
    if (d.info.biosVersion != null) {
      b.writeln(_kvRow('BIOS', [d.info.biosVersion, d.info.biosDate].where((s) => s != null && s.isNotEmpty).join(' — ')));
    }
    if (d.info.desktopEnvironment != null) b.writeln(_kvRow('Bureaubladomgeving', d.info.desktopEnvironment!));
    if (d.info.displayServer != null) b.writeln(_kvRow('Display-server', d.info.displayServer!));
    if (d.info.shell != null) b.writeln(_kvRow('Shell', d.info.shell!));
    if (d.info.locale != null) b.writeln(_kvRow('Locale', d.info.locale!));
    b.writeln('</table>');
    b.writeln(_sectionClose());

    // --- Huidige sensorwaarden ---------------------------------------
    b.writeln(_sectionOpen('Huidige sensorwaarden (momentopname)', icon: 'gauge', accent: _accSensors));

    b.writeln(_h3('CPU', icon: 'cpu', accent: _accCpu));
    b.writeln('<table class="kv">');
    b.writeln(_kvRow('Belasting', _fmtPercent(d.cpu.overallLoadPercent)));
    if (d.cpu.clockMHz != null) b.writeln(_kvRow('Kloksnelheid', '${d.cpu.clockMHz!.toStringAsFixed(0)} MHz'));
    b.writeln(_kvColorRow('Temperatuur', _fmtTemp(d.cpu.temperatureC), _tempColorHex(d.cpu.temperatureC)));
    if (d.cpu.fanRpm != null) b.writeln(_kvRow('Fan', '${d.cpu.fanRpm} RPM'));
    if (d.cpuDetails.physicalCores != null || d.cpuDetails.logicalProcessors != null) {
      b.writeln(_kvRow('Cores (fysiek/logisch)', '${d.cpuDetails.physicalCores ?? '?'} / ${d.cpuDetails.logicalProcessors ?? '?'}'));
    }
    if (d.cpuDetails.baseSpeedMHz != null) b.writeln(_kvRow('Basissnelheid', '${d.cpuDetails.baseSpeedMHz!.toStringAsFixed(0)} MHz'));
    if (d.cpuPowerWatts != null) b.writeln(_kvRow('Vermogen (CPU package)', '${d.cpuPowerWatts!.toStringAsFixed(1)} W'));
    if (d.cpuDetails.governor != null) b.writeln(_kvRow('Energieschema', d.cpuDetails.governor!));
    if (d.cpuDetails.virtualizationSupport != null) b.writeln(_kvRow('Virtualisatie', d.cpuDetails.virtualizationSupport!));
    if (d.cpuDetails.isVirtualMachine == true) b.writeln(_kvRow('Omgeving', 'Draait in een virtuele machine'));
    b.writeln('</table>');
    if (d.cpu.perCoreLoadPercent.isNotEmpty) {
      b.writeln('<p class="mini-caption">Belasting per core (${d.cpu.perCoreLoadPercent.length})</p>');
      b.writeln('<div class="core-bars">');
      for (final l in d.cpu.perCoreLoadPercent) {
        final h = l.clamp(0, 100);
        b.writeln('<div class="core-bar" style="height:${h.toStringAsFixed(0)}%" title="${h.toStringAsFixed(0)}%"></div>');
      }
      b.writeln('</div>');
    }

    b.writeln(_h3('Systeembelasting', icon: 'system', accent: _accLoad));
    b.writeln('<table class="kv">');
    b.writeln(_kvRow('Actieve processen', '${d.load.totalTasks}'));
    if (d.threadCount != null) b.writeln(_kvRow('Threads', '${d.threadCount}'));
    b.writeln(_kvRow('Schijfactiviteit (alle schijven)', d.diskActivityPercent != null ? _fmtPercent(d.diskActivityPercent!) : 'n.v.t.'));
    b.writeln('</table>');

    b.writeln(_h3('Geheugen', icon: 'memory', accent: _accMem));
    b.writeln('<table class="kv">');
    b.writeln(_kvRow('Gebruikt', '${_fmtKiB(d.memory.usedKiB)} / ${_fmtKiB(d.memory.totalKiB)} (${_fmtPercent(d.memory.usedPercent)})'));
    b.writeln(_kvRow('Beschikbaar', _fmtKiB(d.memory.availableKiB)));
    if (d.memory.cachedKiB > 0) b.writeln(_kvRow('Gecached', _fmtKiB(d.memory.cachedKiB)));
    if (d.memory.swapTotalKiB > 0) {
      b.writeln(_kvRow('Swap', '${_fmtKiB(d.memory.swapUsedKiB)} / ${_fmtKiB(d.memory.swapTotalKiB)} (${_fmtPercent(d.memory.swapUsedPercent)})'));
    }
    b.writeln('</table>');
    final memSlices = <_Slice>[
      (label: 'Gebruikt', value: d.memory.usedKiB.toDouble(), color: _accMem),
      (label: 'Vrij', value: (d.memory.totalKiB - d.memory.usedKiB).toDouble(), color: '#e2e8f0'),
    ];
    b.writeln('<div class="chart-row">');
    b.writeln('<div class="donut-wrap">${_svgDonut(memSlices)}</div>');
    b.writeln(_chartLegendHtml(memSlices, formatValue: (v) => _fmtKiB(v.round())));
    b.writeln('</div>');

    b.writeln(_h3('GPU(\'s)', icon: 'gpu', accent: _accGpu));
    if (d.gpus.isEmpty) {
      b.writeln('<p class="muted">Geen GPU gevonden op dit systeem.</p>');
    } else {
      b.writeln('<table class="grid">');
      b.writeln('<tr><th>Naam</th><th>Belasting</th><th>Temperatuur</th><th>Vermogen</th><th>Klok</th><th>Fan</th></tr>');
      for (final g in d.gpus) {
        final tempLabel = g.temperatureIsSharedWithCpu ? '${_fmtTemp(g.temperatureC)} (gedeeld met CPU)' : _fmtTemp(g.temperatureC);
        b.writeln('<tr>'
            '<td>${_esc(g.name)}</td>'
            '<td>${g.loadPercent != null ? _fmtPercent(g.loadPercent!) : 'n.v.t.'}</td>'
            '<td style="color:${_tempColorHex(g.temperatureC)}">${_esc(tempLabel)}</td>'
            '<td>${g.powerDrawWatts != null ? '${g.powerDrawWatts!.toStringAsFixed(1)} W' : 'n.v.t.'}</td>'
            '<td>${g.clockMHz != null ? '${g.clockMHz!.toStringAsFixed(0)} MHz' : 'n.v.t.'}</td>'
            '<td>${g.fanRpm != null ? '${g.fanRpm} RPM' : 'n.v.t.'}</td>'
            '</tr>');
      }
      b.writeln('</table>');
    }

    b.writeln(_h3('Schijfruimte', icon: 'disk', accent: _accDisk));
    if (d.disks.isEmpty) {
      b.writeln('<p class="muted">Geen schijven gevonden.</p>');
    } else {
      b.writeln('<table class="grid">');
      b.writeln('<tr><th>Volume</th><th>Koppelpunt</th><th>Bestandssysteem</th><th>Gebruikt</th><th>%</th></tr>');
      for (final ds in d.disks) {
        b.writeln('<tr>'
            '<td>${_esc(ds.device)}</td>'
            '<td>${_esc(ds.mountPoint)}</td>'
            '<td>${_esc(ds.fsType)}</td>'
            '<td>${_fmtBytesGiB(ds.usedBytes)} / ${_fmtBytesGiB(ds.totalBytes)}</td>'
            '<td style="color:${_percentColorHex(ds.usedPercent, highIsBad: true)}">${_fmtPercent(ds.usedPercent)}</td>'
            '</tr>');
      }
      b.writeln('</table>');
      b.writeln('<p class="mini-caption">Schijfgebruik per volume</p>');
      b.writeln(_barChartHtml(d.disks));
      if (d.disks.length > 1) {
        final diskSlices = <_Slice>[
          for (var i = 0; i < d.disks.length; i++)
            (label: d.disks[i].mountPoint.isNotEmpty ? d.disks[i].mountPoint : d.disks[i].device,
              value: d.disks[i].usedBytes.toDouble(),
              color: _diskPalette[i % _diskPalette.length]),
        ];
        b.writeln('<p class="mini-caption">Aandeel in totaal gebruikte schijfruimte</p>');
        b.writeln('<div class="chart-row">');
        b.writeln('<div class="donut-wrap">${_svgDonut(diskSlices)}</div>');
        b.writeln(_chartLegendHtml(diskSlices, formatValue: (v) => _fmtBytesGiB(v.round())));
        b.writeln('</div>');
      }
    }

    b.writeln(_h3('Schijfgezondheid', icon: 'diskhealth', accent: _accDisk));
    if (d.diskHealth.isEmpty || !d.diskHealth.hasAnyMeaningfulData) {
      b.writeln('<p class="muted">Geen gezondheidsgegevens (SMART) beschikbaar op dit systeem.</p>');
    } else {
      b.writeln('<table class="grid">');
      b.writeln('<tr><th>Schijf</th><th>Model</th><th>Type</th><th>Aan-uren</th><th>Resterende levensduur</th><th>Temperatuur</th></tr>');
      for (final dh in d.diskHealth) {
        final life = dh.lifeRemainingPercent;
        b.writeln('<tr>'
            '<td>${_esc(dh.deviceId)}</td>'
            '<td>${_esc(dh.model ?? 'onbekend')}</td>'
            '<td>${dh.isSsd == true ? 'SSD' : (dh.isSsd == false ? 'HDD' : 'n.v.t.')}</td>'
            '<td>${dh.powerOnHours ?? 'n.v.t.'}</td>'
            '<td style="color:${life != null ? _percentColorHex(life, highIsBad: false) : _muted}">${life != null ? _fmtPercent(life) : 'n.v.t.'}</td>'
            '<td style="color:${_tempColorHex(dh.temperatureC)}">${_fmtTemp(dh.temperatureC)}</td>'
            '</tr>');
      }
      b.writeln('</table>');
    }

    b.writeln(_h3('Netwerk', icon: 'network', accent: _accNetwork));
    final networkSorted = List<NetworkSample>.from(d.network)..sort((a, b) => a.type.index.compareTo(b.type.index));
    if (networkSorted.isEmpty) {
      b.writeln('<p class="muted">Geen netwerkinterfaces gevonden.</p>');
    } else {
      b.writeln('<table class="grid">');
      b.writeln('<tr><th>Interface</th><th>Type</th><th>Ontvangen (totaal)</th><th>Verzonden (totaal)</th></tr>');
      for (final n in networkSorted) {
        b.writeln('<tr>'
            '<td>${_esc(n.interfaceName)}</td>'
            '<td>${_networkTypeLabel(n.type)}</td>'
            '<td>${_fmtBytesAuto(n.totalRxBytes)}</td>'
            '<td>${_fmtBytesAuto(n.totalTxBytes)}</td>'
            '</tr>');
      }
      b.writeln('</table>');
    }

    b.writeln(_h3('Batterij', icon: 'battery', accent: _accBattery));
    if (!d.battery.present) {
      b.writeln('<p class="muted">Geen batterij aanwezig (desktop-systeem).</p>');
    } else {
      b.writeln('<table class="kv">');
      b.writeln(_kvRow('Niveau', '${d.battery.capacityPercent ?? '?'}% (${d.battery.status ?? 'onbekend'})'));
      if (d.battery.healthPercent != null) {
        b.writeln(_kvColorRow('Gezondheid (t.o.v. ontwerpcapaciteit)', _fmtPercent(d.battery.healthPercent!), _percentColorHex(d.battery.healthPercent!, highIsBad: false)));
      }
      if (d.battery.cycleCount != null) b.writeln(_kvRow('Laadcycli', '${d.battery.cycleCount}'));
      if (d.batteryEnergy?.drawMW != null && d.batteryEnergy!.discharging == true) {
        b.writeln(_kvRow('Verbruik', '${(d.batteryEnergy!.drawMW! / 1000).toStringAsFixed(1)} W'));
      }
      b.writeln('</table>');
    }

    b.writeln(_sectionClose());

    // --- Benchmarkgeschiedenis ---------------------------------------
    b.writeln(_sectionOpen('Benchmarkgeschiedenis (${d.benchmarks.length} resultaat/resultaten)', icon: 'gauge', accent: _accBenchmarks));
    if (d.benchmarks.isEmpty) {
      b.writeln('<p class="muted">Nog geen benchmarks gedraaid op dit apparaat.</p>');
    } else {
      final typeCounts = <BenchmarkType, int>{};
      for (final r in d.benchmarks) {
        typeCounts[r.type] = (typeCounts[r.type] ?? 0) + 1;
      }
      final benchSlices = <_Slice>[
        for (final t in BenchmarkType.values)
          if ((typeCounts[t] ?? 0) > 0) (label: _typeLabel(t), value: (typeCounts[t] ?? 0).toDouble(), color: _benchmarkTypeAccent(t)),
      ];
      b.writeln('<p class="mini-caption">Benchmarks per testtype</p>');
      b.writeln('<div class="chart-row">');
      b.writeln('<div class="donut-wrap">${_svgDonut(benchSlices)}</div>');
      b.writeln(_chartLegendHtml(benchSlices, formatValue: (v) => v.toStringAsFixed(0)));
      b.writeln('</div>');

      final tempHistory = d.benchmarks.reversed.where((r) => r.peakTemperatureC != null).toList();
      final tempRecent = tempHistory.length > 20 ? tempHistory.sublist(tempHistory.length - 20) : tempHistory;
      if (tempRecent.length >= 2) {
        b.writeln('<p class="mini-caption">Piektemperatuur per test in de tijd (laatste ${tempRecent.length})</p>');
        b.writeln(_svgAreaLine([for (final r in tempRecent) r.peakTemperatureC!], color: _accBenchmarks));
        b.writeln('<div class="area-range">'
            '<span>${_fmtShortDate(tempRecent.first.timestamp)}</span>'
            '<span>${_fmtShortDate(tempRecent.last.timestamp)}</span>'
            '</div>');
      }

      b.writeln('<table class="grid">');
      b.writeln('<tr><th>Tijdstip</th><th>Test</th><th>Intensiteit</th><th>Resultaat</th><th>Piektemp.</th><th>Status</th></tr>');
      for (final r in d.benchmarks) {
        final statusLabel = r.aborted ? 'Gestopt' : (r.throttleDetected ? 'Throttling' : 'OK');
        final statusColor = r.aborted ? _red : (r.throttleDetected ? _orange : _green);
        b.writeln('<tr>'
            '<td>${_fmtDateTime(r.timestamp)}</td>'
            '<td>${_typeLabel(r.type)}</td>'
            '<td>${r.intensity.label}</td>'
            '<td>${_esc(r.summaryLine)}</td>'
            '<td style="color:${_tempColorHex(r.peakTemperatureC)}">${_fmtTemp(r.peakTemperatureC)}</td>'
            '<td style="color:$statusColor">$statusLabel</td>'
            '</tr>');
      }
      b.writeln('</table>');
    }
    b.writeln(_sectionClose());

    // --- Rapportinformatie (afsluitende uitleg) ------------------------
    b.writeln('<div class="closing-card">');
    b.writeln('<h2>${_infoIconSvg()}Rapportinformatie — wat is er gecontroleerd?</h2>');
    b.writeln('<div class="info-grid">');
    b.writeln('<div class="info-item"><b>Systeeminformatie</b><span>Versie, build en actuele uptime van Windows/Linux.</span></div>');
    b.writeln('<div class="info-item"><b>Sensorwaarden</b><span>CPU/GPU/geheugen op basis van live sensoruitlezing op het moment van genereren.</span></div>');
    b.writeln('<div class="info-item"><b>Schijfgezondheid</b><span>SMART-gegevens: resterende levensduur en temperatuur per schijf, indien beschikbaar.</span></div>');
    b.writeln('<div class="info-item"><b>Benchmarkgeschiedenis</b><span>Alle eerder op dit apparaat uitgevoerde tests, met piektemperatuur en status.</span></div>');
    b.writeln('</div>');
    b.writeln('</div>');

    // --- Nuttige links ---------------------------------------------
    b.writeln(_sectionOpen('Nuttige links', icon: 'links', accent: _accSystem));
    b.writeln('<ul class="links-list">');
    b.writeln('<li><b>Schijf bijna vol?</b><span>Zie onze gids over opschonen en uitbreiden van opslag.</span></li>');
    b.writeln('<li><b>Hoge temperaturen?</b><span>Tips voor stofvrij houden en koeling controleren.</span></li>');
    b.writeln('</ul>');
    b.writeln(_sectionClose());

    b.writeln('<footer>Dit rapport is automatisch gegenereerd door DarkTask (Darkerst Inc.) op ${_fmtDateTime(d.generatedAt)}.</footer>');

    b.writeln('</div>');
    b.writeln('</body>');
    b.writeln('</html>');
    return b.toString();
  }

  static const _css = '''
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 0; background: #eef1f5;
      font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif;
      color: #1e293b;
    }
    .page { max-width: 960px; margin: 0 auto; padding: 24px 24px 48px; }
    header.banner {
      background: linear-gradient(135deg, #1d4ed8, #2563eb);
      color: #fff; border-radius: 12px; padding: 24px 28px; margin-bottom: 20px;
    }
    header.banner h1 { margin: 0 0 6px; font-size: 24px; }
    header.banner p.sub { margin: 2px 0; opacity: 0.92; font-size: 14px; }
    header.banner p.small { opacity: 0.75; font-size: 12px; }
    section.card {
      background: #fff; border-radius: 10px; padding: 18px 22px;
      margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08);
      overflow: hidden;
    }
    section.card h2 {
      display: flex; align-items: center; gap: 12px;
      font-size: 16px; margin: -18px -22px 18px; padding: 10px 22px;
      color: #fff; font-weight: 700;
    }
    section.card h3 {
      display: flex; align-items: center; gap: 10px;
      font-size: 12px; margin: 20px 0 10px; padding: 6px 12px 6px 6px;
      color: #fff; border-radius: 8px; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.04em;
    }
    section.card h3:first-of-type { margin-top: 0; }
    .h-icon { display: inline-flex; }

    .verdict-banner {
      border-radius: 10px; padding: 20px 24px; margin-bottom: 20px;
      display: flex; align-items: center; gap: 18px; color: #fff;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }
    .verdict-banner.good { background: linear-gradient(135deg, #16a34a, #15803d); }
    .verdict-banner.warn { background: linear-gradient(135deg, #f59e0b, #c2410c); }
    .verdict-banner.bad  { background: linear-gradient(135deg, #ef4444, #b91c1c); }
    .verdict-icon {
      width: 48px; height: 48px; border-radius: 50%;
      background: rgba(255,255,255,0.25); display: flex;
      align-items: center; justify-content: center; flex: 0 0 auto;
    }
    .verdict-text h2 { margin: 0 0 4px; font-size: 18px; }
    .verdict-text p { margin: 0; font-size: 13px; opacity: 0.95; line-height: 1.5; }
    .verdict-text ul { margin: 10px 0 0; padding-left: 18px; font-size: 12.5px; opacity: 0.95; }
    .verdict-text li { margin-bottom: 3px; }

    .closing-card { background: #0f172a; color: #fff; border-radius: 12px; padding: 28px; margin-bottom: 16px; }
    .closing-card h2 { margin: 0 0 12px; font-size: 16px; color: #fff; display: flex; align-items: center; gap: 10px; }
    .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
    .info-item { background: rgba(255,255,255,0.06); border-radius: 8px; padding: 12px 14px; }
    .info-item b { display: block; font-size: 12.5px; margin-bottom: 4px; color: #93c5fd; }
    .info-item span { font-size: 11.5px; color: #cbd5e1; line-height: 1.5; }

    .links-list { list-style: none; margin: 0; padding: 0; }
    .links-list li { padding: 9px 0; border-bottom: 1px solid #f1f5f9; font-size: 13px; }
    .links-list li:last-child { border-bottom: none; }
    .links-list b { color: #334155; }
    .links-list span { color: #64748b; font-size: 12px; display: block; margin-top: 2px; }

    table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 4px; }
    table.kv td { padding: 5px 6px; border-bottom: 1px solid #f1f5f9; }
    table.kv td:first-child { color: #64748b; width: 42%; }
    table.kv td:last-child { font-weight: 600; }
    table.grid th, table.grid td { padding: 6px 8px; border-bottom: 1px solid #f1f5f9; text-align: left; }
    table.grid th { background: #f1f5f9; color: #475569; font-size: 11.5px; text-transform: uppercase; letter-spacing: 0.03em; }
    table.grid tr:nth-child(even) td { background: #fafbfc; }
    p.muted { color: #94a3b8; font-size: 13px; font-style: italic; }
    p.mini-caption { color: #64748b; font-size: 11.5px; font-weight: 600; margin: 10px 0 6px; }
    footer { text-align: center; color: #94a3b8; font-size: 11px; margin-top: 20px; }

    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; margin: 2px 0 4px; }
    .stat-card { background: #fff; border-radius: 10px; padding: 14px 16px; border: 1px solid #eef1f5; border-left: 5px solid #2563eb; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
    .stat-head { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; }
    .badge-icon { flex: 0 0 auto; box-shadow: 0 2px 5px rgba(0,0,0,0.25); border-radius: 12px; }
    .stat-title { font-weight: 600; font-size: 13.5px; color: #334155; flex: 1; }
    .status-dot { width: 10px; height: 10px; border-radius: 50%; flex: 0 0 auto; }
    .stat-big { font-size: 26px; font-weight: 700; margin-bottom: 4px; }
    .stat-line { font-size: 11.5px; color: #64748b; }
    .stat-trend { font-size: 10.5px; font-weight: 600; margin-top: 6px; display: flex; align-items: center; gap: 4px; }

    .core-bars { display: flex; align-items: flex-end; gap: 3px; height: 46px; margin: 2px 0 12px; flex-wrap: wrap; }
    .core-bar { flex: 0 0 7px; background: linear-gradient(#60a5fa, #2563eb); border-radius: 2px 2px 0 0; min-height: 3px; }

    .chart-row { display: flex; align-items: center; gap: 20px; flex-wrap: wrap; margin: 4px 0 10px; }
    .donut-wrap { flex: 0 0 auto; }
    .chart-legend { list-style: none; margin: 0; padding: 0; flex: 1 1 180px; min-width: 160px; }
    .chart-legend li { display: flex; align-items: center; gap: 7px; font-size: 12px; padding: 3px 0; }
    .chart-legend .dot { width: 10px; height: 10px; border-radius: 50%; flex: 0 0 auto; }
    .chart-legend .legend-label { flex: 1; color: #334155; }
    .chart-legend .legend-value { font-weight: 700; color: #1e293b; }

    .bar-chart { display: flex; align-items: flex-end; gap: 14px; height: 150px; padding-top: 22px; }
    .bar-col { display: flex; flex-direction: column; align-items: center; flex: 0 0 46px; height: 100%; }
    .bar-value { font-size: 11px; font-weight: 700; color: #334155; margin-bottom: 4px; }
    .bar-track { height: 108px; width: 26px; background: #f1f5f9; border-radius: 4px 4px 0 0; display: flex; align-items: flex-end; overflow: hidden; }
    .bar-fill { width: 100%; border-radius: 4px 4px 0 0; min-height: 3px; }
    .bar-label { font-size: 10px; color: #64748b; margin-top: 4px; max-width: 62px; text-align: center; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

    .area-range { display: flex; justify-content: space-between; font-size: 10.5px; color: #94a3b8; margin-top: -4px; }

    @media print {
      body { background: #fff; }
      section.card { box-shadow: none; border: 1px solid #e2e8f0; }
      .stat-card { box-shadow: none; }
    }
  ''';

  String _sectionOpen(String title, {required String icon, required String accent}) =>
      '<section class="card"><h2 style="background:$accent">'
      '${_iconImg(icon, size: 80, radius: 18)}${_esc(title)}</h2>';
  String _sectionClose() => '</section>';
  String _h3(String title, {required String icon, required String accent}) =>
      '<h3 style="background:$accent">${_iconImg(icon, size: 60, radius: 14)}${_esc(title)}</h3>';
  String _kvRow(String k, String v) => '<tr><td>${_esc(k)}</td><td>${_esc(v)}</td></tr>';
  String _kvColorRow(String k, String v, String colorHex) => '<tr><td>${_esc(k)}</td><td style="color:$colorHex">${_esc(v)}</td></tr>';

  String _statCardHtml({
    required String icon,
    required String accent,
    required String title,
    required String bigValue,
    required String bigValueColor,
    required List<String> lines,
    String? dotColor,
    _Trend? trend,
  }) {
    final dot = dotColor != null ? '<span class="status-dot" style="background:$dotColor"></span>' : '';
    final linesHtml = lines.map((l) => '<div class="stat-line">${_esc(l)}</div>').join();
    final trendHtml = trend != null
        ? '<div class="stat-trend" style="color:${trend.color}">'
            '${trend.direction != 0 ? _trendArrowSvg(trend.direction > 0, trend.color) : ''}'
            '${_esc(trend.label)}</div>'
        : '';
    return '<div class="stat-card" style="border-left-color:$accent">'
        '<div class="stat-head">'
        '<span class="badge-icon">${_iconImg(icon, size: 112, radius: 24)}</span>'
        '<span class="stat-title">${_esc(title)}</span>'
        '$dot'
        '</div>'
        '<div class="stat-big" style="color:$bigValueColor">${_esc(bigValue)}</div>'
        '$linesHtml'
        '$trendHtml'
        '</div>';
  }

  /// Standard SVG "stroke-dasharray around a circle" donut technique —
  /// a background track circle, then one colored circle segment per
  /// slice, rotated -90° so the first slice starts at 12 o'clock.
  String _svgDonut(List<_Slice> slices, {double size = 148, double thickness = 26}) {
    final total = slices.fold<double>(0, (s, e) => s + e.value);
    if (total <= 0) return '<p class="muted">Geen gegevens.</p>';
    final r = (size - thickness) / 2;
    final c = size / 2;
    final circumference = 2 * math.pi * r;
    final buf = StringBuffer();
    buf.write('<svg viewBox="0 0 $size $size" width="$size" height="$size">');
    buf.write('<g transform="rotate(-90 $c $c)">');
    buf.write('<circle cx="$c" cy="$c" r="${r.toStringAsFixed(2)}" fill="none" stroke="#e2e8f0" stroke-width="$thickness"/>');
    var offset = 0.0;
    for (final s in slices) {
      if (s.value <= 0) continue;
      final len = circumference * (s.value / total);
      buf.write('<circle cx="$c" cy="$c" r="${r.toStringAsFixed(2)}" fill="none" stroke="${s.color}" stroke-width="$thickness" '
          'stroke-dasharray="${len.toStringAsFixed(2)} ${(circumference - len).toStringAsFixed(2)}" '
          'stroke-dashoffset="-${offset.toStringAsFixed(2)}"/>');
      offset += len;
    }
    buf.write('</g></svg>');
    return buf.toString();
  }

  String _chartLegendHtml(List<_Slice> slices, {String Function(double)? formatValue}) {
    final total = slices.fold<double>(0, (s, e) => s + e.value);
    final fmt = formatValue ?? (v) => v.toStringAsFixed(0);
    final buf = StringBuffer('<ul class="chart-legend">');
    for (final s in slices) {
      if (s.value <= 0) continue;
      final pct = total > 0 ? (s.value / total * 100) : 0.0;
      buf.write('<li><span class="dot" style="background:${s.color}"></span>'
          '<span class="legend-label">${_esc(s.label)}</span>'
          '<span class="legend-value">${fmt(s.value)} (${pct.toStringAsFixed(0)}%)</span></li>');
    }
    buf.write('</ul>');
    return buf.toString();
  }

  /// Filled area/line chart via a hand-built SVG path — no charting
  /// library, just a polyline through evenly-spaced x positions (the
  /// benchmark runs themselves aren't evenly spaced in time, so this
  /// deliberately plots "run order", not a true time axis — the date
  /// range is shown as the two endpoint labels underneath instead of a
  /// dense, likely-unreadable per-point axis).
  String _svgAreaLine(List<double> values, {double width = 560, double height = 150, String color = '#2563eb'}) {
    if (values.length < 2) return '<p class="muted">Onvoldoende gegevens.</p>';
    final maxRaw = values.reduce((a, b) => a > b ? a : b);
    final maxVal = maxRaw <= 0 ? 1.0 : maxRaw * 1.2;
    final n = values.length;
    final stepX = width / (n - 1);
    final pts = <String>[];
    for (var i = 0; i < n; i++) {
      final x = i * stepX;
      final y = height - (values[i] / maxVal) * height;
      pts.add('${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}');
    }
    final linePath = 'M${pts.join(' L')}';
    final areaPath = '$linePath L${width.toStringAsFixed(1)},${height.toStringAsFixed(1)} L0,${height.toStringAsFixed(1)} Z';
    final buf = StringBuffer();
    buf.write('<svg viewBox="0 0 $width $height" width="100%" height="$height" preserveAspectRatio="none">');
    buf.write('<path d="$areaPath" fill="$color" fill-opacity="0.15" stroke="none"/>');
    buf.write('<path d="$linePath" fill="none" stroke="$color" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>');
    for (final p in pts) {
      final parts = p.split(',');
      buf.write('<circle cx="${parts[0]}" cy="${parts[1]}" r="3.2" fill="$color"/>');
    }
    buf.write('</svg>');
    return buf.toString();
  }

  /// Simple colored, labeled bar chart for disk-space-used% per volume
  /// — own CSS/flexbox implementation (not SVG) so each bar can carry
  /// its own genuine status color (green/orange/red), which a single
  /// PDF `BarDataSet` (one color per whole series) can't do — see the
  /// PDF build's equivalent for why that one uses a single accent color
  /// instead.
  String _barChartHtml(List<DiskSample> disks) {
    // Fixed pixel height (matching .bar-track's own fixed CSS height)
    // rather than a CSS percentage — a percentage height only resolves
    // when the parent's own height is unambiguously definite, and this
    // removes that dependency entirely so the fill can never silently
    // fail to show. See barChartPdf's doc for the PDF side of the same
    // fix.
    const trackHeightPx = 108.0;
    final buf = StringBuffer('<div class="bar-chart">');
    for (final ds in disks) {
      final color = _percentColorHex(ds.usedPercent, highIsBad: true);
      final pct = ds.usedPercent.clamp(0, 100).toDouble();
      var px = trackHeightPx * pct / 100;
      if (px < 3) px = 3;
      if (px > trackHeightPx) px = trackHeightPx;
      final label = ds.mountPoint.isNotEmpty ? ds.mountPoint : ds.device;
      buf.write('<div class="bar-col">'
          '<div class="bar-value">${_fmtPercent(ds.usedPercent)}</div>'
          '<div class="bar-track"><div class="bar-fill" style="height:${px.toStringAsFixed(0)}px;background:$color"></div></div>'
          '<div class="bar-label" title="${_esc(label)}">${_esc(label)}</div>'
          '</div>');
    }
    buf.write('</div>');
    return buf.toString();
  }

  static const _green = '#15803d';
  static const _orange = '#c2410c';
  static const _red = '#b91c1c';
  static const _muted = '#64748b';

  /// Same "implausible-looking is worse" and "no fabricated verdicts"
  /// spirit as the rest of this app: a null value gets the neutral
  /// muted color, never a false green/red.
  String _tempColorHex(double? c) {
    if (c == null) return _muted;
    if (c < 60) return _green;
    if (c < 80) return _orange;
    return _red;
  }

  /// [highIsBad] flips the direction: disk-space-used% is bad when
  /// high, remaining-life%/battery-health% is bad when low.
  String _percentColorHex(double v, {required bool highIsBad}) {
    final effective = highIsBad ? v : (100 - v);
    if (effective < 60) return _green;
    if (effective < 85) return _orange;
    return _red;
  }

  // ==================================================================
  // PDF
  // ==================================================================

  Future<Uint8List> _buildPdf(_ReportData d) async {
    final doc = pw.Document();

    // Same hex palette as the HTML — see the class-level accent
    // constants' doc comment.
    final accCpu = PdfColor.fromHex(_accCpu);
    final accGpu = PdfColor.fromHex(_accGpu);
    final accMem = PdfColor.fromHex(_accMem);
    final accDisk = PdfColor.fromHex(_accDisk);
    final accNetwork = PdfColor.fromHex(_accNetwork);
    final accBattery = PdfColor.fromHex(_accBattery);
    final accSystem = PdfColor.fromHex(_accSystem);
    final accSensors = PdfColor.fromHex(_accSensors);
    final accLoad = PdfColor.fromHex(_accLoad);
    final accOverview = PdfColor.fromHex(_accOverview);
    final accBenchmarks = PdfColor.fromHex(_accBenchmarks);

    // Same reportIconPngBase64 images as the HTML side (see that
    // file's doc and _iconImg above) — decoded once per report into
    // pw.MemoryImage so every icon call site below just looks one up
    // instead of re-decoding the same bytes over and over.
    final iconImages = <String, pw.MemoryImage>{
      for (final entry in reportIconPngBase64.entries) entry.key: pw.MemoryImage(base64Decode(entry.value)),
    };
    pw.Widget iconImg(String key, double size) {
      final img = iconImages[key];
      if (img == null) return pw.SizedBox(width: size, height: size);
      return pw.Image(img, width: size, height: size, fit: pw.BoxFit.cover);
    }

    final worstDisk = _worstDisk(d.disks);
    final verdict = _computeVerdict(d, worstDisk);
    final trendCpu = _trendPdf(d.cpu.temperatureC, d.previous?.cpuTemperatureC, unit: '°C', goodDirection: -1);
    final trendMem = _trendPdf(d.memory.usedPercent, d.previous?.memoryUsedPercent, unit: '%', goodDirection: -1, decimals: 1);
    final trendDisk = worstDisk != null
        ? _trendPdf(worstDisk.usedPercent, d.previous?.diskUsedPercent[worstDisk.device], unit: '%', goodDirection: -1, decimals: 1)
        : null;
    final trendBattery = d.battery.healthPercent != null
        ? _trendPdf(d.battery.healthPercent, d.previous?.batteryHealthPercent, unit: '%', goodDirection: 1, decimals: 1)
        : null;

    final labelStyle = const pw.TextStyle(fontSize: 9, color: PdfColors.grey700);

    pw.Widget kvTable(List<List<String>> rows, {List<PdfColor?>? valueColors}) {
      return pw.Table(
        columnWidths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(3)},
        children: [
          for (var i = 0; i < rows.length; i++)
            pw.TableRow(children: [
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Text(rows[i][0], style: labelStyle),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Text(
                  rows[i][1],
                  style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                    color: (valueColors != null && i < valueColors.length) ? (valueColors[i] ?? PdfColors.black) : PdfColors.black,
                  ),
                ),
              ),
            ]),
        ],
      );
    }

    // Solid-color banner, matching the reference dashboards' section
    // headers (a full-width colored bar with white text) rather than
    // the earlier thin-bottom-border style. [iconKey] indexes into
    // [iconImages] — see the class doc's "Extended 2026-09-24" note;
    // this replaced a single-letter circle badge.
    pw.Widget sectionTitleIcon(String iconKey, PdfColor accent, String t) => pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(top: 14, bottom: 10),
          padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(
            children: [
              iconImg(iconKey, 44),
              pw.SizedBox(width: 8),
              pw.Text(t, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
            ],
          ),
        );

    pw.Widget subTitleIcon(String iconKey, PdfColor accent, String t) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 10, bottom: 6),
          padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Row(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              iconImg(iconKey, 30),
              pw.SizedBox(width: 5),
              pw.Text(t.toUpperCase(), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
            ],
          ),
        );

    pw.Widget statCard({
      required String iconKey,
      required PdfColor accent,
      required String title,
      required String bigValue,
      required PdfColor bigValueColor,
      required List<String> lines,
      PdfColor? dotColor,
      _TrendPdf? trend,
    }) =>
        pw.Container(
          width: 190,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border.all(color: PdfColors.grey300, width: 0.6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                children: [
                  iconImg(iconKey, 56),
                  pw.SizedBox(width: 8),
                  pw.Expanded(
                    child: pw.Text(title, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800)),
                  ),
                  if (dotColor != null)
                    pw.Container(width: 7, height: 7, decoration: pw.BoxDecoration(shape: pw.BoxShape.circle, color: dotColor)),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Text(bigValue, style: pw.TextStyle(fontSize: 19, fontWeight: pw.FontWeight.bold, color: bigValueColor)),
              pw.SizedBox(height: 3),
              for (final l in lines) pw.Text(l, style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600)),
              if (trend != null) ...[
                pw.SizedBox(height: 3),
                pw.Text(trend.label, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: trend.color)),
              ],
            ],
          ),
        );

    // --- Real charts, via the `pdf` package's own (preview-status, but
    // verified against live usage examples before writing this) Chart
    // API: PieGrid/PieDataSet for donuts-as-pies, CartesianGrid with
    // BarDataSet/LineDataSet for bar and area/line charts. ------------

    pw.Widget pieLegend(List<_Slice> slices, {String Function(double)? formatValue}) {
      final total = slices.fold<double>(0, (s, e) => s + e.value);
      final fmt = formatValue ?? (v) => v.toStringAsFixed(0);
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          for (final s in slices)
            if (s.value > 0)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
                child: pw.Row(
                  children: [
                    pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(shape: pw.BoxShape.circle, color: PdfColor.fromHex(s.color))),
                    pw.SizedBox(width: 5),
                    pw.Expanded(child: pw.Text(s.label, style: const pw.TextStyle(fontSize: 8))),
                    pw.SizedBox(width: 4),
                    pw.Text('${fmt(s.value)} (${total > 0 ? (s.value / total * 100).toStringAsFixed(0) : '0'}%)',
                        style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
        ],
      );
    }

    pw.Widget pieChartRow(List<_Slice> slices, {String Function(double)? formatValue}) {
      final total = slices.fold<double>(0, (s, e) => s + e.value);
      if (total <= 0) {
        return pw.Text('Geen gegevens.', style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey500));
      }
      return pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.SizedBox(
            width: 110,
            height: 110,
            child: pw.Chart(
              grid: pw.PieGrid(),
              datasets: [
                for (final s in slices)
                  if (s.value > 0)
                    pw.PieDataSet(
                      value: s.value,
                      legend: s.label,
                      color: PdfColor.fromHex(s.color),
                      legendPosition: pw.PieLegendPosition.none,
                    ),
              ],
            ),
          ),
          pw.SizedBox(width: 14),
          pw.Expanded(child: pieLegend(slices, formatValue: formatValue)),
        ],
      );
    }

    // Hand-built bar chart — plain Container/Row/Column with explicit
    // pixel heights, rather than the `pdf` package's own pw.Chart/
    // BarDataSet/CartesianGrid combo (used here until now). That combo
    // is documented as "in preview" and, per direct user report, the
    // "Schijfgebruik per volume" bar chart it produced showed nothing
    // at all — so it's replaced with the same reliable technique every
    // other custom-drawn widget in this file already uses, nothing left
    // to a preview-status chart engine. Percent-style values only
    // (0-100) — used for per-core CPU load and disk-usage-per-volume.
    pw.Widget barChartPdf({
      required List<String> xLabels,
      required List<double> values,
      required PdfColor color,
      double height = 90,
    }) {
      if (values.isEmpty) return pw.SizedBox();
      return pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < values.length; i++)
            pw.Expanded(
              child: pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 3),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  mainAxisAlignment: pw.MainAxisAlignment.end,
                  children: [
                    pw.Text(
                      '${values[i].toStringAsFixed(0)}%',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Container(
                      height: _pdfBarHeight(values[i], height),
                      decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(2)),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(
                      xLabels[i],
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.grey600),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    pw.Widget lineChartPdf({
      required List<String> xLabels,
      required List<double> values,
      required PdfColor color,
      double height = 140,
    }) {
      if (values.length < 2) return pw.SizedBox();
      final maxRaw = values.reduce((a, b) => a > b ? a : b);
      final ceilVal = maxRaw <= 60 ? 60 : (maxRaw <= 90 ? 90 : 120);
      return pw.SizedBox(
        height: height,
        child: pw.Chart(
          grid: pw.CartesianGrid(
            xAxis: pw.FixedAxis.fromStrings(xLabels, marginStart: 20, marginEnd: 20, ticks: true, angle: xLabels.length > 8 ? 45 : 0),
            yAxis: pw.FixedAxis([0, ceilVal ~/ 2, ceilVal], format: (v) => '${v.toStringAsFixed(0)}°C', divisions: true),
          ),
          datasets: [
            pw.LineDataSet(
              legend: 'Piektemperatuur',
              color: color,
              drawSurface: true,
              surfaceColor: color,
              surfaceOpacity: 0.18,
              data: [for (var i = 0; i < values.length; i++) pw.PointChartValue(i.toDouble(), values[i])],
            ),
          ],
        ),
      );
    }

    final systeemRows = <List<String>>[
      ['Hostname', d.info.hostname],
      ['Besturingssysteem', d.info.osName],
      ['Kernel', d.info.kernelVersion],
      ['Architectuur', d.info.architecture],
      ['Uptime', _fmtDuration(d.info.uptime)],
      ['CPU', '${d.info.cpuModel} (${d.info.cpuCores} cores)'],
      ['Geheugen (totaal)', _fmtGiB(d.info.totalMemoryGiB)],
      ['GPU(\'s)', d.info.gpuNames.isNotEmpty ? d.info.gpuNames.join(', ') : 'geen gevonden'],
    ];
    if (d.info.systemVendor != null || d.info.systemModel != null) {
      systeemRows.add(['Systeem', [d.info.systemVendor, d.info.systemModel].where((s) => s != null && s.isNotEmpty).join(' ')]);
    }
    if (d.info.biosVersion != null) {
      systeemRows.add(['BIOS', [d.info.biosVersion, d.info.biosDate].where((s) => s != null && s.isNotEmpty).join(' — ')]);
    }
    if (d.info.desktopEnvironment != null) systeemRows.add(['Bureaubladomgeving', d.info.desktopEnvironment!]);
    if (d.info.displayServer != null) systeemRows.add(['Display-server', d.info.displayServer!]);
    if (d.info.shell != null) systeemRows.add(['Shell', d.info.shell!]);
    if (d.info.locale != null) systeemRows.add(['Locale', d.info.locale!]);

    final cpuRows = <List<String>>[
      ['Belasting', _fmtPercent(d.cpu.overallLoadPercent)],
      if (d.cpu.clockMHz != null) ['Kloksnelheid', '${d.cpu.clockMHz!.toStringAsFixed(0)} MHz'],
      ['Temperatuur', _fmtTemp(d.cpu.temperatureC)],
      if (d.cpu.fanRpm != null) ['Fan', '${d.cpu.fanRpm} RPM'],
      if (d.cpuDetails.physicalCores != null || d.cpuDetails.logicalProcessors != null)
        ['Cores (fysiek/logisch)', '${d.cpuDetails.physicalCores ?? '?'} / ${d.cpuDetails.logicalProcessors ?? '?'}'],
      if (d.cpuDetails.baseSpeedMHz != null) ['Basissnelheid', '${d.cpuDetails.baseSpeedMHz!.toStringAsFixed(0)} MHz'],
      if (d.cpuPowerWatts != null) ['Vermogen (CPU package)', '${d.cpuPowerWatts!.toStringAsFixed(1)} W'],
      if (d.cpuDetails.governor != null) ['Energieschema', d.cpuDetails.governor!],
      if (d.cpuDetails.virtualizationSupport != null) ['Virtualisatie', d.cpuDetails.virtualizationSupport!],
      if (d.cpuDetails.isVirtualMachine == true) ['Omgeving', 'Draait in een virtuele machine'],
    ];
    // Mirrors cpuRows entry-for-entry (same conditions, same order) so
    // kvTable's index-based valueColors lookup lines up correctly —
    // keep any future edit to cpuRows' conditional entries in sync with
    // this list.
    final cpuColors = <PdfColor?>[
      null,
      if (d.cpu.clockMHz != null) null,
      _tempColorPdf(d.cpu.temperatureC),
      if (d.cpu.fanRpm != null) null,
      if (d.cpuDetails.physicalCores != null || d.cpuDetails.logicalProcessors != null) null,
      if (d.cpuDetails.baseSpeedMHz != null) null,
      if (d.cpuPowerWatts != null) null,
      if (d.cpuDetails.governor != null) null,
      if (d.cpuDetails.virtualizationSupport != null) null,
      if (d.cpuDetails.isVirtualMachine == true) null,
    ];

    final loadRows = <List<String>>[
      ['Actieve processen', '${d.load.totalTasks}'],
      if (d.threadCount != null) ['Threads', '${d.threadCount}'],
      ['Schijfactiviteit (alle schijven)', d.diskActivityPercent != null ? _fmtPercent(d.diskActivityPercent!) : 'n.v.t.'],
    ];

    final memRows = <List<String>>[
      ['Gebruikt', '${_fmtKiB(d.memory.usedKiB)} / ${_fmtKiB(d.memory.totalKiB)} (${_fmtPercent(d.memory.usedPercent)})'],
      ['Beschikbaar', _fmtKiB(d.memory.availableKiB)],
      if (d.memory.cachedKiB > 0) ['Gecached', _fmtKiB(d.memory.cachedKiB)],
      if (d.memory.swapTotalKiB > 0)
        ['Swap', '${_fmtKiB(d.memory.swapUsedKiB)} / ${_fmtKiB(d.memory.swapTotalKiB)} (${_fmtPercent(d.memory.swapUsedPercent)})'],
    ];
    final memSlices = <_Slice>[
      (label: 'Gebruikt', value: d.memory.usedKiB.toDouble(), color: _accMem),
      (label: 'Vrij', value: (d.memory.totalKiB - d.memory.usedKiB).toDouble(), color: '#e2e8f0'),
    ];

    final gpuTableRows = d.gpus
        .map((g) => [
              g.name,
              g.loadPercent != null ? _fmtPercent(g.loadPercent!) : 'n.v.t.',
              g.temperatureIsSharedWithCpu ? '${_fmtTemp(g.temperatureC)} (CPU)' : _fmtTemp(g.temperatureC),
              g.powerDrawWatts != null ? '${g.powerDrawWatts!.toStringAsFixed(1)} W' : 'n.v.t.',
              g.clockMHz != null ? '${g.clockMHz!.toStringAsFixed(0)} MHz' : 'n.v.t.',
              g.fanRpm != null ? '${g.fanRpm} RPM' : 'n.v.t.',
            ])
        .toList();

    final diskTableRows = d.disks
        .map((ds) => [
              ds.device,
              ds.mountPoint,
              '${_fmtBytesGiB(ds.usedBytes)} / ${_fmtBytesGiB(ds.totalBytes)}',
              _fmtPercent(ds.usedPercent),
            ])
        .toList();
    final diskUsageXLabels = [for (final ds in d.disks) ds.mountPoint.isNotEmpty ? ds.mountPoint : ds.device];
    final diskUsageValues = [for (final ds in d.disks) ds.usedPercent];
    final diskSlices = <_Slice>[
      for (var i = 0; i < d.disks.length; i++)
        (label: d.disks[i].mountPoint.isNotEmpty ? d.disks[i].mountPoint : d.disks[i].device,
          value: d.disks[i].usedBytes.toDouble(),
          color: _diskPalette[i % _diskPalette.length]),
    ];

    final diskHealthTableRows = d.diskHealth
        .map((dh) => [
              dh.deviceId,
              dh.model ?? 'onbekend',
              dh.isSsd == true ? 'SSD' : (dh.isSsd == false ? 'HDD' : 'n.v.t.'),
              dh.powerOnHours?.toString() ?? 'n.v.t.',
              dh.lifeRemainingPercent != null ? _fmtPercent(dh.lifeRemainingPercent!) : 'n.v.t.',
              _fmtTemp(dh.temperatureC),
            ])
        .toList();

    final networkSorted = List<NetworkSample>.from(d.network)..sort((a, b) => a.type.index.compareTo(b.type.index));
    final networkTableRows = networkSorted
        .map((n) => [
              n.interfaceName,
              _networkTypeLabel(n.type),
              _fmtBytesAuto(n.totalRxBytes),
              _fmtBytesAuto(n.totalTxBytes),
            ])
        .toList();

    final benchmarkTableRows = d.benchmarks
        .map((r) => [
              _fmtDateTime(r.timestamp),
              _typeLabel(r.type),
              r.intensity.label,
              r.summaryLine,
              _fmtTemp(r.peakTemperatureC),
              r.aborted ? 'Gestopt' : (r.throttleDetected ? 'Throttling' : 'OK'),
            ])
        .toList();

    final typeCounts = <BenchmarkType, int>{};
    for (final r in d.benchmarks) {
      typeCounts[r.type] = (typeCounts[r.type] ?? 0) + 1;
    }
    final benchSlices = <_Slice>[
      for (final t in BenchmarkType.values)
        if ((typeCounts[t] ?? 0) > 0) (label: _typeLabel(t), value: (typeCounts[t] ?? 0).toDouble(), color: _benchmarkTypeAccent(t)),
    ];
    final tempHistory = d.benchmarks.reversed.where((r) => r.peakTemperatureC != null).toList();
    final tempRecent = tempHistory.length > 20 ? tempHistory.sublist(tempHistory.length - 20) : tempHistory;
    final tempXLabels = [for (final r in tempRecent) _fmtShortDate(r.timestamp)];
    final tempValues = [for (final r in tempRecent) r.peakTemperatureC!];

    // Built from plain pw.Table/pw.TableRow rather than the package's
    // pw.Table.fromTextArray/pw.TableHelper.fromTextArray convenience
    // wrapper: that helper's exact name/location has moved between
    // `pdf` package versions (deprecated on Table, later moved onto a
    // separate TableHelper class), and since this can't be compiled
    // here to confirm which one the resolved version exposes, the
    // handful of core widgets below are used instead — those have been
    // stable across every version of this package.
    pw.Widget tableCell(String text, {bool isHeader = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: pw.Text(
            text,
            style: isHeader
                ? pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white)
                : const pw.TextStyle(fontSize: 8.5),
          ),
        );

    pw.Widget dataTable(List<String> headers, List<List<String>> rows, {PdfColor headerColor = PdfColors.blue800}) {
      if (rows.isEmpty) {
        return pw.Text('Geen gegevens beschikbaar.', style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey500));
      }
      return pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: headerColor),
            children: [for (final h in headers) tableCell(h, isHeader: true)],
          ),
          for (var i = 0; i < rows.length; i++)
            pw.TableRow(
              decoration: i.isOdd ? const pw.BoxDecoration(color: PdfColors.grey100) : null,
              children: [for (final v in rows[i]) tableCell(v)],
            ),
        ],
      );
    }

    final dashCards = <pw.Widget>[
      statCard(
        iconKey: 'cpu',
        accent: accCpu,
        title: 'CPU',
        bigValue: _fmtTemp(d.cpu.temperatureC),
        bigValueColor: _tempColorPdf(d.cpu.temperatureC),
        lines: [
          'Belasting: ${_fmtPercent(d.cpu.overallLoadPercent)}',
          if (d.cpu.clockMHz != null) '${d.cpu.clockMHz!.toStringAsFixed(0)} MHz',
        ],
        dotColor: _tempColorPdf(d.cpu.temperatureC),
        trend: trendCpu,
      ),
      for (final g in d.gpus.take(2))
        statCard(
          iconKey: 'gpu',
          accent: accGpu,
          title: g.name.length > 20 ? '${g.name.substring(0, 20)}…' : g.name,
          bigValue: _fmtTemp(g.temperatureC),
          bigValueColor: _tempColorPdf(g.temperatureC),
          lines: [
            if (g.loadPercent != null) 'Belasting: ${_fmtPercent(g.loadPercent!)}',
            if (g.powerDrawWatts != null) 'Vermogen: ${g.powerDrawWatts!.toStringAsFixed(1)} W',
          ],
          dotColor: _tempColorPdf(g.temperatureC),
          trend: _trendPdf(g.temperatureC, d.previous?.gpuTemperaturesC[g.id], unit: '°C', goodDirection: -1),
        ),
      statCard(
        iconKey: 'memory',
        accent: accMem,
        title: 'Geheugen',
        bigValue: _fmtPercent(d.memory.usedPercent),
        bigValueColor: _percentColorPdf(d.memory.usedPercent, highIsBad: true),
        lines: ['${_fmtKiB(d.memory.usedKiB)} / ${_fmtKiB(d.memory.totalKiB)}'],
        dotColor: _percentColorPdf(d.memory.usedPercent, highIsBad: true),
        trend: trendMem,
      ),
      if (worstDisk != null)
        statCard(
          iconKey: 'disk',
          accent: accDisk,
          title: 'Schijf (${worstDisk.mountPoint})',
          bigValue: _fmtPercent(worstDisk.usedPercent),
          bigValueColor: _percentColorPdf(worstDisk.usedPercent, highIsBad: true),
          lines: ['${_fmtBytesGiB(worstDisk.usedBytes)} / ${_fmtBytesGiB(worstDisk.totalBytes)}'],
          dotColor: _percentColorPdf(worstDisk.usedPercent, highIsBad: true),
          trend: trendDisk,
        ),
      if (d.battery.present)
        statCard(
          iconKey: 'battery',
          accent: accBattery,
          title: 'Batterij',
          bigValue: '${d.battery.capacityPercent ?? '?'}%',
          bigValueColor: PdfColors.grey800,
          lines: [
            d.battery.status ?? 'onbekend',
            if (d.battery.healthPercent != null) 'Gezondheid: ${_fmtPercent(d.battery.healthPercent!)}',
          ],
          dotColor: d.battery.healthPercent != null ? _percentColorPdf(d.battery.healthPercent!, highIsBad: false) : null,
          trend: trendBattery,
        ),
    ];

    // --- Systeemstatus verdict-banner (see _computeVerdict's doc) -----
    final verdictAccents = verdict.level == 0
        ? [PdfColor.fromHex('#16a34a'), PdfColor.fromHex('#15803d')]
        : verdict.level == 1
            ? [PdfColor.fromHex('#f59e0b'), PdfColor.fromHex('#c2410c')]
            : [PdfColor.fromHex('#ef4444'), PdfColor.fromHex('#b91c1c')];
    final verdictGlyph = verdict.level == 0 ? '✓' : (verdict.level == 1 ? '!' : '✕');
    final verdictBanner = pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: 14),
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        gradient: pw.LinearGradient(colors: verdictAccents),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: 26,
            height: 26,
            alignment: pw.Alignment.center,
            decoration: const pw.BoxDecoration(shape: pw.BoxShape.circle, color: PdfColors.white),
            child: pw.Text(verdictGlyph, style: pw.TextStyle(color: verdictAccents[1], fontWeight: pw.FontWeight.bold, fontSize: 13)),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(verdict.title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
                pw.SizedBox(height: 3),
                pw.Text(verdict.summary, style: const pw.TextStyle(fontSize: 9, color: PdfColors.white)),
                if (verdict.points.isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  for (final p in verdict.points)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 1),
                      child: pw.Text('•  $p', style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.white)),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    // --- Afsluitende "Rapportinformatie" / "Nuttige links" / FCC-kaart -
    pw.Widget infoItem(String title, String desc) => pw.Container(
          width: 235,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(color: PdfColor.fromHex('#1e293b'), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(title, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#93c5fd'))),
              pw.SizedBox(height: 3),
              pw.Text(desc, style: pw.TextStyle(fontSize: 8, color: PdfColor.fromHex('#cbd5e1'))),
            ],
          ),
        );

    final closingCard = pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: 14),
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(color: PdfColor.fromHex('#0f172a'), borderRadius: pw.BorderRadius.circular(10)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Rapportinformatie — wat is er gecontroleerd?',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          pw.SizedBox(height: 10),
          pw.Wrap(spacing: 10, runSpacing: 10, children: [
            infoItem('Systeeminformatie', 'Versie, build en actuele uptime van Windows/Linux.'),
            infoItem('Sensorwaarden', 'CPU/GPU/geheugen op basis van live sensoruitlezing op het moment van genereren.'),
            infoItem('Schijfgezondheid', 'SMART-gegevens: resterende levensduur en temperatuur per schijf, indien beschikbaar.'),
            infoItem('Benchmarkgeschiedenis', 'Alle eerder op dit apparaat uitgevoerde tests, met piektemperatuur en status.'),
          ]),
        ],
      ),
    );

    pw.Widget linkItem(String title, String desc) => pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 6),
          decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey200, width: 0.6))),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(title, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800)),
              pw.SizedBox(height: 2),
              pw.Text(desc, style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey600)),
            ],
          ),
        );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => context.pageNumber == 1
            ? pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 12),
                padding: const pw.EdgeInsets.all(14),
                decoration: pw.BoxDecoration(
                  gradient: const pw.LinearGradient(colors: [PdfColors.blue800, PdfColors.blue600]),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('DarkTask systeemrapport', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
                    pw.SizedBox(height: 3),
                    pw.Text('${d.info.hostname} — gegenereerd op ${_fmtDateTime(d.generatedAt)}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.white)),
                    pw.Text('Darkerst Inc. — DarkTask', style: pw.TextStyle(fontSize: 8, color: PdfColors.blue100)),
                  ],
                ),
              )
            : pw.Container(),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 6),
          child: pw.Text('Pagina ${context.pageNumber} van ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500)),
        ),
        build: (context) => [
          // --- Systeemstatus verdict-banner (zie _computeVerdict) -----
          verdictBanner,

          // --- Pagina 1: live overzicht (dashboard) ------------------
          sectionTitleIcon('gauge', accOverview, 'Live overzicht'),
          if (d.previous == null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                'Dit is de eerste rapportage van dit apparaat — trends t.o.v. een vorige rapportage verschijnen vanaf de volgende keer.',
                style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic, color: PdfColors.grey500),
              ),
            ),
          pw.Wrap(spacing: 10, runSpacing: 10, children: dashCards),
          if (d.gpus.length > 2)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                '+ ${d.gpus.length - 2} andere GPU(\'s) — zie de tabel verderop.',
                style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic, color: PdfColors.grey500),
              ),
            ),
          pw.NewPage(),

          // --- Vanaf pagina 2: alle details ---------------------------
          sectionTitleIcon('system', accSystem, 'Systeeminformatie'),
          kvTable(systeemRows),

          sectionTitleIcon('gauge', accSensors, 'Huidige sensorwaarden (momentopname)'),
          subTitleIcon('cpu', accCpu, 'CPU'),
          kvTable(cpuRows, valueColors: cpuColors),
          if (d.cpu.perCoreLoadPercent.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text('Belasting per core (${d.cpu.perCoreLoadPercent.length})', style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey500)),
            pw.SizedBox(height: 3),
            barChartPdf(
              xLabels: [for (var i = 0; i < d.cpu.perCoreLoadPercent.length; i++) 'C$i'],
              values: d.cpu.perCoreLoadPercent,
              color: accCpu,
            ),
          ],
          subTitleIcon('system', accLoad, 'Systeembelasting'),
          kvTable(loadRows),
          subTitleIcon('memory', accMem, 'Geheugen'),
          kvTable(memRows),
          pw.SizedBox(height: 4),
          pieChartRow(memSlices, formatValue: (v) => _fmtKiB(v.round())),
          subTitleIcon('gpu', accGpu, 'GPU(\'s)'),
          dataTable(['Naam', 'Belasting', 'Temperatuur', 'Vermogen', 'Klok', 'Fan'], gpuTableRows, headerColor: accGpu),
          subTitleIcon('disk', accDisk, 'Schijfruimte'),
          dataTable(['Volume', 'Koppelpunt', 'Gebruikt', '%'], diskTableRows, headerColor: accDisk),
          if (diskUsageValues.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            pw.Text('Schijfgebruik per volume', style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey500)),
            pw.SizedBox(height: 3),
            barChartPdf(xLabels: diskUsageXLabels, values: diskUsageValues, color: accDisk),
          ],
          if (diskSlices.length > 1) ...[
            pw.SizedBox(height: 6),
            pw.Text('Aandeel in totaal gebruikte schijfruimte', style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey500)),
            pw.SizedBox(height: 3),
            pieChartRow(diskSlices, formatValue: (v) => _fmtBytesGiB(v.round())),
          ],
          subTitleIcon('diskhealth', accDisk, 'Schijfgezondheid'),
          (d.diskHealth.hasAnyMeaningfulData)
              ? dataTable(['Schijf', 'Model', 'Type', 'Aan-uren', 'Levensduur', 'Temp.'], diskHealthTableRows, headerColor: accDisk)
              : pw.Text('Geen gezondheidsgegevens (SMART) beschikbaar op dit systeem.', style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey500)),
          subTitleIcon('network', accNetwork, 'Netwerk'),
          dataTable(['Interface', 'Type', 'Ontvangen', 'Verzonden'], networkTableRows, headerColor: accNetwork),
          subTitleIcon('battery', accBattery, 'Batterij'),
          d.battery.present
              ? kvTable([
                  ['Niveau', '${d.battery.capacityPercent ?? '?'}% (${d.battery.status ?? 'onbekend'})'],
                  if (d.battery.healthPercent != null) ['Gezondheid', _fmtPercent(d.battery.healthPercent!)],
                  if (d.battery.cycleCount != null) ['Laadcycli', '${d.battery.cycleCount}'],
                  if (d.batteryEnergy?.drawMW != null && d.batteryEnergy!.discharging == true)
                    ['Verbruik', '${(d.batteryEnergy!.drawMW! / 1000).toStringAsFixed(1)} W'],
                ])
              : pw.Text('Geen batterij aanwezig (desktop-systeem).', style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey500)),

          sectionTitleIcon('gauge', accBenchmarks, 'Benchmarkgeschiedenis (${d.benchmarks.length} resultaat/resultaten)'),
          if (benchSlices.isNotEmpty) ...[
            pw.Text('Benchmarks per testtype', style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey500)),
            pw.SizedBox(height: 3),
            pieChartRow(benchSlices),
            pw.SizedBox(height: 8),
          ],
          if (tempValues.length >= 2) ...[
            pw.Text('Piektemperatuur per test in de tijd (laatste ${tempValues.length})', style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey500)),
            pw.SizedBox(height: 3),
            lineChartPdf(xLabels: tempXLabels, values: tempValues, color: accBenchmarks),
            pw.SizedBox(height: 8),
          ],
          dataTable(['Tijdstip', 'Test', 'Intensiteit', 'Resultaat', 'Piektemp.', 'Status'], benchmarkTableRows, headerColor: accBenchmarks),

          // --- Afsluitende pagina: Rapportinformatie / Nuttige links ---
          pw.NewPage(),
          closingCard,
          sectionTitleIcon('links', accSystem, 'Nuttige links'),
          linkItem('Schijf bijna vol?', 'Zie onze gids over opschonen en uitbreiden van opslag.'),
          linkItem('Hoge temperaturen?', 'Tips voor stofvrij houden en koeling controleren.'),
        ],
      ),
    );

    return doc.save();
  }

  /// Pixel height for one bar in [barChartPdf] — plain proportional
  /// math (never a percentage CSS-style resolve), clamped so a 0%
  /// value still shows a sliver rather than vanishing entirely.
  double _pdfBarHeight(double value, double maxHeight) {
    var h = maxHeight * value / 100;
    if (h < 2) h = 2;
    if (h > maxHeight) h = maxHeight;
    return h;
  }

  PdfColor _tempColorPdf(double? c) {
    if (c == null) return PdfColors.grey500;
    if (c < 60) return PdfColors.green700;
    if (c < 80) return PdfColors.orange700;
    return PdfColors.red700;
  }

  /// PDF counterpart of [_percentColorHex] — same "high is bad" flip
  /// and thresholds, just returning a [PdfColor] instead of a hex
  /// string.
  PdfColor _percentColorPdf(double v, {required bool highIsBad}) {
    final effective = highIsBad ? v : (100 - v);
    if (effective < 60) return PdfColors.green700;
    if (effective < 85) return PdfColors.orange700;
    return PdfColors.red700;
  }

  // ==================================================================
  // Shared formatting helpers
  // ==================================================================

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String _fmtGiB(double v) => '${v.toStringAsFixed(1)} GiB';
  String _fmtBytesGiB(int bytes) => '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  String _fmtKiB(int kib) => '${(kib / (1024 * 1024)).toStringAsFixed(1)} GiB';
  String _fmtPercent(double v) => '${v.toStringAsFixed(1)}%';
  String _fmtTemp(double? v) => v != null ? '${v.toStringAsFixed(0)}°C' : 'n.v.t.';

  /// Auto-scaling byte formatter (B/KiB/MiB/GiB/TiB) — unlike
  /// [_fmtBytesGiB] (always GiB, fine for whole disks) this is used for
  /// network totals, which can genuinely be anywhere from a few KiB to
  /// several TiB and would otherwise show as a meaningless "0.0 GiB".
  String _fmtBytesAuto(int bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return i == 0 ? '${v.toStringAsFixed(0)} ${units[i]}' : '${v.toStringAsFixed(1)} ${units[i]}';
  }

  String _fmtDateTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}-${two(t.month)}-${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  String _fmtShortDate(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}-${two(t.month)}';
  }

  String _fmtDuration(Duration d) {
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    final parts = <String>[];
    if (days > 0) parts.add('${days}d');
    if (hours > 0 || days > 0) parts.add('${hours}u');
    parts.add('${minutes}m');
    return parts.join(' ');
  }

  String _typeLabel(BenchmarkType type) {
    switch (type) {
      case BenchmarkType.cpu:
        return 'CPU';
      case BenchmarkType.memory:
        return 'Geheugen';
      case BenchmarkType.disk:
        return 'Schijf';
      case BenchmarkType.network:
        return 'Netwerk';
      case BenchmarkType.crypto:
        return 'Crypto';
      case BenchmarkType.gpu:
        return 'GPU';
    }
  }
}

/// Bundles one fully-resolved snapshot so [ReportService._buildHtml]
/// and [ReportService._buildPdf] always render from identical data
/// instead of each taking their own separate sensor reads.
class _ReportData {
  final DateTime generatedAt;
  final SystemInfoSample info;
  final CpuSample cpu;
  final CpuDetailInfo cpuDetails;
  final double? cpuPowerWatts;
  final int? threadCount;
  final double? diskActivityPercent;
  final LoadSample load;
  final MemorySample memory;
  final List<GpuSample> gpus;
  final List<DiskSample> disks;
  final List<DiskHealthInfo> diskHealth;
  final List<NetworkSample> network;
  final BatterySample battery;
  final BatteryEnergySample? batteryEnergy;
  final List<BenchmarkResult> benchmarks;

  /// The previous report's dashboard figures, or null when this is the
  /// first report ever generated on this machine — see
  /// [ReportSnapshotStore]'s class doc and this class's own doc above.
  final ReportSnapshot? previous;

  const _ReportData({
    required this.generatedAt,
    required this.info,
    required this.cpu,
    required this.cpuDetails,
    required this.cpuPowerWatts,
    required this.threadCount,
    required this.diskActivityPercent,
    required this.load,
    required this.memory,
    required this.gpus,
    required this.disks,
    required this.diskHealth,
    required this.network,
    required this.battery,
    required this.batteryEnergy,
    required this.benchmarks,
    required this.previous,
  });
}
