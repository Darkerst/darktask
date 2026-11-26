import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeBatteryReader';

/// Direct `dart:ffi` binding to `kernel32.dll`'s `GetSystemPowerStatus`
/// — same safety philosophy as every other native reader in this
/// directory (see `pdh_ffi.dart`'s [PdhCpuReader] class doc for the
/// full reasoning on crash risk and disable-on-any-failure), and
/// arguably the simplest of them all: one function, one flat struct
/// with every field naturally aligned (four single-byte fields sum to
/// exactly 4 bytes, so the two trailing DWORDs that follow are already
/// on a 4-byte boundary — no padding, no length field to set before
/// calling, unlike GlobalMemoryStatusEx).
///
/// Battery is polled far less often than CPU/memory/disk/network, so
/// this isn't really about speed — it's the same native-call approach
/// applied for consistency and completeness, closing one more
/// WMI (`Win32_Battery`) round-trip.
class NativeBatteryReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _kernel32;
  late final int Function(Pointer<_SystemPowerStatus>) _getSystemPowerStatus;
  bool _bound = false;

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      _getSystemPowerStatus = _kernel32!.lookupFunction<Int32 Function(Pointer<_SystemPowerStatus>),
          int Function(Pointer<_SystemPowerStatus>)>('GetSystemPowerStatus');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe batterij-uitlezing (dart:ffi GetSystemPowerStatus, zonder WMI) actief.',
      );
      return true;
    } catch (e, st) {
      disable('Failed to bind kernel32.dll GetSystemPowerStatus: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _bound = false;
    AppLogger.instance.info(
      _logSource,
      'Directe batterij-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode. Dit bericht komt niet terug.',
    );
  }

  /// Returns `{'present': bool, 'capacityPercent': int?, 'status':
  /// String?}`, or null if this path isn't usable (falls back to the
  /// existing WMI-based reading — see
  /// [WindowsSensorService.readBattery]).
  Map<String, dynamic>? read() {
    if (!_ensureBound()) return null;

    final buf = calloc<_SystemPowerStatus>();
    try {
      final ok = _getSystemPowerStatus(buf);
      if (ok == 0) {
        disable('GetSystemPowerStatus returned FALSE');
        return null;
      }

      final batteryFlag = buf.ref.batteryFlag;
      final acLineStatus = buf.ref.acLineStatus;
      final lifePercent = buf.ref.batteryLifePercent;

      // Bit 128 ("no system battery") and the 255 ("unknown") sentinel
      // both mean "don't trust this reading" per Microsoft's own
      // documented values for this struct — not a plausibility guess,
      // this is what the API contract itself defines those values to
      // mean.
      if (batteryFlag == 255) {
        disable('GetSystemPowerStatus returned an unknown BatteryFlag (255)');
        return null;
      }
      final present = (batteryFlag & 0x80) == 0; // 0x80 = BATTERY_FLAG_NO_BATTERY

      if (!present) {
        return {'present': false, 'capacityPercent': null, 'status': null};
      }

      final capacityPercent = lifePercent == 255 ? null : lifePercent;

      // Bit 8 = BATTERY_FLAG_CHARGING. AC line status: 0 = offline (on
      // battery), 1 = online (external power connected), 255 = unknown.
      String? status;
      if ((batteryFlag & 0x08) != 0) {
        status = 'Charging';
      } else if (acLineStatus == 1) {
        status = (capacityPercent != null && capacityPercent >= 100) ? 'Full' : 'AC';
      } else if (acLineStatus == 0) {
        status = 'Discharging';
      }

      return {'present': true, 'capacityPercent': capacityPercent, 'status': status};
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      calloc.free(buf);
    }
  }
}

/// SYSTEM_POWER_STATUS — four single-byte fields (summing to exactly
/// 4 bytes) followed by two DWORDs, so — like MEMORYSTATUSEX and
/// unlike PDH_FMT_COUNTERVALUE's union — every field already falls on
/// a naturally aligned offset with no manual padding needed.
final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;

  @Uint8()
  external int batteryFlag;

  @Uint8()
  external int batteryLifePercent;

  @Uint8()
  external int systemStatusFlag;

  @Uint32()
  external int batteryLifeTime;

  @Uint32()
  external int batteryFullLifeTime;
}
