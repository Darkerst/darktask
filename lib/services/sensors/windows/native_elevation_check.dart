import 'dart:ffi';
import 'dart:io';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeElevationCheck';

/// Direct `dart:ffi` binding to `shell32.dll`'s `IsUserAnAdmin` — the
/// simplest possible native call in this app: no parameters, no
/// struct, just a `BOOL` answer to "is this process running
/// elevated?".
///
/// Added specifically to end the back-and-forth of manually checking
/// Task Manager's "Elevated" column after every launch attempt — this
/// logs the definitive answer once, right at startup, straight from
/// Windows itself rather than from how the person *believes* they
/// launched the app.
///
/// `IsUserAnAdmin` is technically marked deprecated by Microsoft in
/// favor of checking the process token's elevation type directly
/// (`GetTokenInformation` with `TokenElevation`) — but the deprecation
/// is about it not distinguishing *why* a non-elevated admin-group
/// user isn't elevated (UAC prompt available vs. not), which doesn't
/// matter for this app's purposes. It still reliably answers "is this
/// specific process elevated right now," which is exactly the
/// question being asked here, and remains present and functional on
/// every supported Windows version.
class NativeElevationCheck {
  static bool? _cachedResult;

  /// Returns true/false, or null if the check itself couldn't run
  /// (never throws) — logged once, the very first time this is
  /// called, so it shows up near the top of every session's log
  /// without needing to be triggered from anywhere else.
  static bool? isElevated() {
    if (_cachedResult != null) return _cachedResult;
    if (!Platform.isWindows) return null;

    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final isUserAnAdmin =
          shell32.lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      final result = isUserAnAdmin() != 0;
      _cachedResult = result;
      AppLogger.instance.info(
        _logSource,
        result
            ? 'Dit proces draait verhoogd (als Administrator) — MSR-afhankelijke sensoren (CPU-temperatuur/-vermogen) zouden nu beschikbaar moeten zijn als LibreHardwareMonitorLib aanwezig is.'
            : 'Dit proces draait NIET verhoogd — MSR-afhankelijke sensoren (CPU-temperatuur/-vermogen) blijven leeg ongeacht wat het manifest zegt of hoe de app gestart lijkt te zijn. '
                'Dit is de directe, definitieve verklaring als temperatuur/vermogen leeg blijven.',
      );
      return result;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to check elevation status: $e\n$st');
      return null;
    }
  }
}
