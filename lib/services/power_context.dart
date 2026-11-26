import 'dart:convert';
import 'dart:io';

import '../core/logging/app_logger.dart';
import 'sensors/windows/native_battery_reader.dart';

const _logSource = 'PowerContext';

/// Momentopname van "onder welke stroomcondities draait deze meting":
/// netstroom of accu, en welk energieplan/-modus actief is.
///
/// Waarom dit bestaat: dezelfde laptop haalt op netstroom met het plan
/// "Hoge prestaties" een duidelijk andere benchmarkscore dan op accu met
/// "Energiebesparing" (CPU-boost, klokbeperking en vermogenslimieten
/// verschillen). Zonder deze context kun je twee scores van dezelfde
/// machine niet eerlijk vergelijken. De momentopname wordt bij de start
/// van elke test gelogd en in de details van het resultaat bewaard; aan
/// het eind wordt gekeken of er tijdens de test iets veranderd is
/// (bijv. de oplader eruit getrokken).
///
/// Alles hier is best-effort: elke fout levert 'onbekend' op en breekt
/// nooit een benchmark af.
class PowerContext {
  /// true = netstroom, false = accu, null = onbekend.
  final bool? onAc;
  final bool hasBattery;
  final int? batteryPercent;

  /// Bron zonder accupercentage (stabiel te vergelijken), bv. "netstroom".
  final String source;

  /// Energieplan (+ Windows-energiemodus), bv. "Evenwichtig, modus beste prestaties".
  final String plan;

  const PowerContext._({
    required this.onAc,
    required this.hasBattery,
    required this.batteryPercent,
    required this.source,
    required this.plan,
  });

  static const PowerContext unknown = PowerContext._(
    onAc: null,
    hasBattery: false,
    batteryPercent: null,
    source: 'onbekend',
    plan: 'onbekend',
  );

  /// Bron met accupercentage erbij, voor logs en resultaatdetails.
  String get sourceLabel =>
      batteryPercent != null ? '$source, accu $batteryPercent%' : source;

  /// Vergelijkt met een latere momentopname; geeft een korte waarschuwing
  /// terug als de omstandigheden tijdens de test veranderd zijn, anders null.
  String? changeSince(PowerContext later) {
    if (onAc != null && later.onAc != null && onAc != later.onAc) {
      return 'Voeding veranderde tijdens de test ($source -> ${later.source}); '
          'de score is niet vergelijkbaar met runs onder constante voeding.';
    }
    if (plan != 'onbekend' && later.plan != 'onbekend' && plan != later.plan) {
      return 'Energieplan veranderde tijdens de test ($plan -> ${later.plan}); '
          'de score is niet vergelijkbaar.';
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Ophalen (met korte cache zodat "Alles tegelijk" niet vijf keer
  // hetzelfde proces start)
  // ---------------------------------------------------------------------

  static final NativeBatteryReader _winBattery = NativeBatteryReader();
  static Future<PowerContext>? _cached;
  static DateTime? _cachedAt;

  static Future<PowerContext> capture() {
    final cached = _cached;
    final at = _cachedAt;
    if (cached != null && at != null && DateTime.now().difference(at) < const Duration(seconds: 2)) {
      return cached;
    }
    final fresh = _captureUncached();
    _cached = fresh;
    _cachedAt = DateTime.now();
    return fresh;
  }

  static Future<PowerContext> _captureUncached() async {
    try {
      if (Platform.isWindows) return await _captureWindows();
      if (Platform.isLinux) return await _captureLinux();
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Voedingscontext niet uit te lezen: $e');
    }
    return unknown;
  }

  // ------------------------------- Windows -------------------------------

  static final RegExp _guidRe =
      RegExp(r'[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}');

  // Vaste GUID's van de ingebouwde Windows-energieplannen.
  static const Map<String, String> _knownSchemes = {
    '381b4222-f694-41f0-9685-ff5bb260df2e': 'Evenwichtig',
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c': 'Hoge prestaties',
    'a1841308-3541-4fab-bc81-f71556f20b4a': 'Energiebesparing',
    'e9a42b02-d5df-448d-aa00-03f14749eb61': 'Ultieme prestaties',
  };

  // Windows 10/11 "energiemodus"-overlay (de schuifregelaar in Instellingen).
  static const Map<String, String> _knownOverlays = {
    '00000000-0000-0000-0000-000000000000': 'standaard/evenwichtig',
    '961cc777-2547-4f9d-8174-7d86181b8a7a': 'beste energie-efficientie',
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f': 'betere prestaties',
    'ded574b5-45a0-4f42-8737-46345c09c238': 'beste prestaties',
  };

  static Future<PowerContext> _captureWindows() async {
    bool hasBattery = false;
    bool? onAc;
    int? percent;
    String source = 'onbekend';

    final b = _winBattery.read();
    if (b != null) {
      if (b['present'] == false) {
        onAc = true;
        source = 'netstroom (geen accu)';
      } else {
        hasBattery = true;
        percent = b['capacityPercent'] as int?;
        switch (b['status'] as String?) {
          case 'Charging':
            onAc = true;
            source = 'netstroom (accu laadt)';
            break;
          case 'Full':
            onAc = true;
            source = 'netstroom (accu vol)';
            break;
          case 'AC':
            onAc = true;
            source = 'netstroom';
            break;
          case 'Discharging':
            onAc = false;
            source = 'accu';
            break;
          default:
            source = 'onbekend';
        }
      }
    }

    final parts = await Future.wait<String?>([
      _windowsActiveScheme(),
      _windowsOverlay(onAc),
    ]);
    final scheme = parts[0];
    final overlay = parts[1];
    final plan = scheme == null
        ? 'onbekend'
        : (overlay != null ? '$scheme, modus $overlay' : scheme);

    return PowerContext._(
      onAc: onAc,
      hasBattery: hasBattery,
      batteryPercent: percent,
      source: source,
      plan: plan,
    );
  }

  static Future<String?> _windowsActiveScheme() async {
    try {
      final r = await Process.run(
        'powercfg',
        const ['/getactivescheme'],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      ).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      final out = r.stdout as String;
      final guid = _guidRe.firstMatch(out)?.group(0)?.toLowerCase();
      final known = guid != null ? _knownSchemes[guid] : null;
      if (known != null) return known;
      final name = RegExp(r'\(([^)]*)\)').firstMatch(out)?.group(1)?.trim();
      if (name != null && name.isNotEmpty) {
        return guid != null ? '$name (eigen plan ${guid.substring(0, 8)})' : name;
      }
      return guid;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'powercfg /getactivescheme mislukt: $e');
      return null;
    }
  }

  static Future<String?> _windowsOverlay(bool? onAc) async {
    try {
      final valueName = onAc == false ? 'ActiveOverlayDcPowerScheme' : 'ActiveOverlayAcPowerScheme';
      final r = await Process.run(
        'reg',
        ['query', r'HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes', '/v', valueName],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      ).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null; // oudere Windows-versie zonder overlay
      final guid = _guidRe.firstMatch(r.stdout as String)?.group(0)?.toLowerCase();
      if (guid == null) return null;
      return _knownOverlays[guid] ?? guid;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Energiemodus (overlay) uitlezen mislukt: $e');
      return null;
    }
  }

  // -------------------------------- Linux --------------------------------

  static Future<String?> _readTrim(String path) async {
    try {
      return (await File(path).readAsString()).trim();
    } catch (_) {
      return null;
    }
  }

  static Future<PowerContext> _captureLinux() async {
    bool hasBattery = false;
    bool? onAc;
    int? percent;
    String? batStatus;

    final dir = Directory('/sys/class/power_supply');
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        final type = await _readTrim('${e.path}/type');
        if (type == 'Battery') {
          hasBattery = true;
          percent ??= int.tryParse(await _readTrim('${e.path}/capacity') ?? '');
          batStatus ??= await _readTrim('${e.path}/status');
        } else if (type == 'Mains') {
          final online = await _readTrim('${e.path}/online');
          if (online == '1') {
            onAc = true;
          } else if (online == '0' && onAc == null) {
            onAc = false;
          }
        }
      }
    }

    String source;
    if (!hasBattery) {
      onAc = true;
      source = 'netstroom (geen accu)';
    } else {
      onAc ??= batStatus == null ? null : batStatus != 'Discharging';
      if (onAc == null) {
        source = 'onbekend';
      } else if (onAc) {
        source = batStatus == 'Charging' ? 'netstroom (accu laadt)' : 'netstroom';
      } else {
        source = 'accu';
      }
    }

    String? profile;
    try {
      final r = await Process.run('powerprofilesctl', const ['get']).timeout(const Duration(seconds: 3));
      if (r.exitCode == 0) profile = (r.stdout as String).trim();
    } catch (_) {
      // power-profiles-daemon niet aanwezig: geen probleem
    }
    final governor = await _readTrim('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor');
    final planParts = <String>[
      if (profile != null && profile.isNotEmpty) 'profiel $profile',
      if (governor != null && governor.isNotEmpty) 'governor $governor',
    ];

    return PowerContext._(
      onAc: onAc,
      hasBattery: hasBattery,
      batteryPercent: percent,
      source: source,
      plan: planParts.isEmpty ? 'onbekend' : planParts.join(', '),
    );
  }
}
