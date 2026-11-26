import 'dart:ffi';
import 'dart:io';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeUptimeReader';

/// Direct `dart:ffi` binding to `kernel32.dll`'s `GetTickCount64` — the
/// simplest possible native call in this app: no struct at all, just
/// a single 64-bit millisecond count since boot, returned directly.
///
/// This isn't only about speed (system info is read once per session,
/// so the WMI round-trip it replaces barely matters either way) — it's
/// also a genuine correctness improvement. The WMI-based uptime
/// calculation had to parse `Win32_OperatingSystem.LastBootUpTime`, a
/// CIM `DateTime` that PowerShell's `ConvertTo-Json` can serialize as
/// either a .NET `/Date(ms)/` string or an ISO string depending on
/// PowerShell version — exactly the kind of format ambiguity this app
/// has hit real bugs from before (see the `lscpu` locale issue on the
/// Linux side). `GetTickCount64` sidesteps that entirely: no date
/// parsing, no locale, no serialization format to guess at.
///
/// One documented limitation, inherited from the Win32 API itself:
/// `GetTickCount64` counts *elapsed* time and pauses during sleep/
/// hibernate, so it under-reports uptime across a sleep cycle — the
/// same trade-off Windows' own Task Manager accepts for this counter.
class NativeUptimeReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _kernel32;
  late final int Function() _getTickCount64;
  bool _bound = false;

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      _getTickCount64 = _kernel32!.lookupFunction<Uint64 Function(), int Function()>('GetTickCount64');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe uptime-uitlezing (dart:ffi GetTickCount64, zonder WMI) actief.',
      );
      return true;
    } catch (e, st) {
      disable('Failed to bind kernel32.dll GetTickCount64: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _bound = false;
    AppLogger.instance.info(
      _logSource,
      'Directe uptime-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode. Dit bericht komt niet terug.',
    );
  }

  /// Returns uptime as a [Duration], or null if this path isn't usable
  /// (falls back to parsing `LastBootUpTime` from WMI — see
  /// [WindowsSensorService.readSystemInfo]).
  Duration? read() {
    if (!_ensureBound()) return null;
    try {
      final ms = _getTickCount64();
      if (ms < 0) {
        disable('GetTickCount64 returned a negative value ($ms)');
        return null;
      }
      return Duration(milliseconds: ms);
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }
}
