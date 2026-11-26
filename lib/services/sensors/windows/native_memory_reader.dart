import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeMemoryReader';

/// Direct `dart:ffi` binding to `kernel32.dll`'s `GlobalMemoryStatusEx`
/// — the same safety philosophy as the PDH readers in `pdh_ffi.dart`
/// (see [PdhCpuReader]'s class doc for the full reasoning on crash
/// risk and disable-on-any-failure), but genuinely the simplest and
/// safest native call in this app so far:
///
/// - One function, no query/counter handles to open, prime, or close
/// - One flat struct with natural 8-byte-aligned fields throughout
///   (two leading 4-byte DWORDs, then all 8-byte fields — no manual
///   padding calculation needed, unlike PDH_FMT_COUNTERVALUE's union)
/// - No wildcard instances, no locale-dependent counter names, no
///   string marshaling of any kind
///
/// Deliberately reads *only* the physical-memory fields
/// (`ullTotalPhys`/`ullAvailPhys`) — `MEMORYSTATUSEX`'s page-file
/// fields are documented by Microsoft as "the current committed
/// memory limit for the system," not a clean physical-RAM-plus-swap
/// sum, so back-deriving a "swap" figure from them would be a guess
/// dressed up as a measurement. Swap continues to come from the
/// existing, purpose-built `Win32_PageFileUsage` WMI query — a small,
/// infrequently-changing value where the WMI round-trip cost barely
/// matters anyway.
class NativeMemoryReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _kernel32;
  late final int Function(Pointer<_MemoryStatusEx>) _globalMemoryStatusEx;
  bool _bound = false;

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      _globalMemoryStatusEx = _kernel32!.lookupFunction<Int32 Function(Pointer<_MemoryStatusEx>),
          int Function(Pointer<_MemoryStatusEx>)>('GlobalMemoryStatusEx');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe geheugenuitlezing (dart:ffi GlobalMemoryStatusEx, zonder WMI) actief voor fysiek geheugen.',
      );
      return true;
    } catch (e, st) {
      disable('Failed to bind kernel32.dll GlobalMemoryStatusEx: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _bound = false;
    AppLogger.instance.info(
      _logSource,
      'Directe geheugenuitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode. Dit bericht komt niet terug.',
    );
  }

  /// Returns `{'totalKiB': ..., 'availableKiB': ..., 'usedKiB': ...}`,
  /// or null if this path isn't usable (falls back to the existing
  /// WMI-based reading — see [WindowsSensorService.readMemory]).
  Map<String, int>? read() {
    if (!_ensureBound()) return null;

    final buf = calloc<_MemoryStatusEx>();
    try {
      // Required by the Win32 contract: GlobalMemoryStatusEx fails
      // outright if dwLength isn't set to sizeof(MEMORYSTATUSEX)
      // before the call — this is how the API tells which struct
      // version/size the caller expects.
      buf.ref.dwLength = sizeOf<_MemoryStatusEx>();

      final ok = _globalMemoryStatusEx(buf);
      if (ok == 0) {
        disable('GlobalMemoryStatusEx returned FALSE');
        return null;
      }

      final totalPhys = buf.ref.ullTotalPhys;
      final availPhys = buf.ref.ullAvailPhys;

      // Plausibility check, not just a happy-path read — the same
      // principle as every other reader in this file: a value that
      // couldn't possibly be real memory (zero total, or "available"
      // exceeding "total") means something read the struct wrong, not
      // that the machine actually has those numbers.
      if (totalPhys <= 0 || availPhys < 0 || availPhys > totalPhys) {
        disable('Plausibiliteitscontrole mislukte (total=$totalPhys, avail=$availPhys)');
        return null;
      }

      final totalKiB = totalPhys ~/ 1024;
      final availableKiB = availPhys ~/ 1024;

      return {
        'totalKiB': totalKiB,
        'availableKiB': availableKiB,
        'usedKiB': totalKiB - availableKiB,
      };
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      calloc.free(buf);
    }
  }
}

/// MEMORYSTATUSEX — every field naturally falls on an aligned offset
/// (two leading 4-byte DWORDs = 8 bytes, then seven 8-byte fields),
/// so unlike PDH_FMT_COUNTERVALUE this needs no explicit padding
/// field to match the real C layout; Dart FFI's [Struct] computes the
/// correct x64 layout directly from the field types and order below,
/// which here happens to need no help to match Microsoft's documented
/// layout.
final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int dwLength;

  @Uint32()
  external int dwMemoryLoad;

  @Uint64()
  external int ullTotalPhys;

  @Uint64()
  external int ullAvailPhys;

  @Uint64()
  external int ullTotalPageFile;

  @Uint64()
  external int ullAvailPageFile;

  @Uint64()
  external int ullTotalVirtual;

  @Uint64()
  external int ullAvailVirtual;

  @Uint64()
  external int ullAvailExtendedVirtual;
}
