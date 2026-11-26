import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeSystemInfoReader';

/// Direct `dart:ffi` bindings to two `kernel32.dll` functions:
/// `GetSystemInfo` (logical processor count) and `GetComputerNameExW`
/// (hostname). Same safety philosophy as every other native reader in
/// this directory (see `pdh_ffi.dart`'s `PdhCpuReader` class doc for
/// the full reasoning on crash risk and disable-on-any-failure).
///
/// **Written for completeness, not speed — this is worth stating
/// plainly.** `readSystemInfo()`/`readCpuDetails()` still need one
/// combined WMI query regardless of what happens here, because OS
/// version and CPU model name have no safe native equivalent
/// (`GetVersionEx` lies without a manifest change; the CPU's marketing
/// name isn't obtainable without a registry read or raw CPUID). So
/// converting just these two fields doesn't remove a round-trip the
/// way the CPU/disk/network/memory/battery readers did — it's added
/// purely so hostname and logical-processor-count don't come from a
/// locale/format-fragile WMI string when a direct, unambiguous native
/// call is available for them specifically.
///
/// `SYSTEM_INFO` is the most structurally complex struct in this app's
/// native readers so far — it has pointer-sized fields
/// (`lpMinimumApplicationAddress`, `dwActiveProcessorMask`) that must
/// be modeled with the correct native word size for the surrounding
/// fields to land on the right byte offsets, and its leading field is
/// a C union collapsed here to a plain 4-byte value (its *size*, not
/// its interpretation, is all that matters for correct layout, since
/// this reader never reads that field).
class NativeSystemInfoReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _kernel32;
  late final void Function(Pointer<_SystemInfo>) _getSystemInfo;
  late final int Function(int nameType, Pointer<Utf16> buffer, Pointer<Uint32> size) _getComputerNameEx;
  bool _bound = false;

  static const _computerNameDnsHostname = 1;
  static const _hostnameBufferChars = 256; // comfortably exceeds any real DNS hostname (max 255 chars)

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      // GetSystemInfo returns void (not BOOL, unlike most Win32 calls
      // in this app) — there's no success/failure signal from the call
      // itself, which is exactly why the plausibility check on its
      // output below matters more here than elsewhere.
      _getSystemInfo =
          _kernel32!.lookupFunction<Void Function(Pointer<_SystemInfo>), void Function(Pointer<_SystemInfo>)>(
        'GetSystemInfo',
      );
      _getComputerNameEx = _kernel32!.lookupFunction<Int32 Function(Int32, Pointer<Utf16>, Pointer<Uint32>),
          int Function(int, Pointer<Utf16>, Pointer<Uint32>)>('GetComputerNameExW');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe uitlezing (dart:ffi GetSystemInfo/GetComputerNameExW) actief voor processortelling en hostnaam.',
      );
      return true;
    } catch (e, st) {
      disable('Failed to bind kernel32.dll functions: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _bound = false;
    AppLogger.instance.info(
      _logSource,
      'Directe systeeminfo-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode. Dit bericht komt niet terug.',
    );
  }

  /// Returns the logical processor count, or null if this path isn't
  /// usable (falls back to WMI's `NumberOfLogicalProcessors` — see
  /// [WindowsSensorService.readCpuDetails]).
  int? readLogicalProcessorCount() {
    if (!_ensureBound()) return null;

    final buf = calloc<_SystemInfo>();
    try {
      _getSystemInfo(buf);
      final count = buf.ref.dwNumberOfProcessors;
      // No status code to check (see the class doc on GetSystemInfo's
      // void return) — a plausibility check is the only signal
      // available that the struct was actually read correctly.
      // Real-world logical processor counts top out in the low
      // thousands on the largest server hardware; anything beyond
      // that or non-positive means the layout/offset was wrong, not
      // that the machine has that many processors.
      if (count <= 0 || count > 4096) {
        disable('Plausibiliteitscontrole mislukte (dwNumberOfProcessors=$count)');
        return null;
      }
      return count;
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      calloc.free(buf);
    }
  }

  /// Returns the DNS hostname, or null if this path isn't usable
  /// (falls back to WMI's `Win32_ComputerSystem.Name` — see
  /// [WindowsSensorService.readSystemInfo]).
  String? readHostname() {
    if (!_ensureBound()) return null;

    final buf = calloc<Uint16>(_hostnameBufferChars);
    final sizePtr = calloc<Uint32>();
    try {
      // On input this is the buffer's capacity in UTF-16 code units;
      // GetComputerNameExW overwrites it on output with the actual
      // string length (excluding the null terminator) — a fixed,
      // generously-sized buffer is used here specifically to avoid the
      // usual two-call "ask for required size, then allocate exactly"
      // Win32 pattern, which would mean handling a distinct
      // ERROR_MORE_DATA failure path for no real benefit at this
      // buffer size.
      sizePtr.value = _hostnameBufferChars;
      final ok = _getComputerNameEx(_computerNameDnsHostname, buf.cast<Utf16>(), sizePtr);
      if (ok == 0) {
        disable('GetComputerNameExW returned FALSE');
        return null;
      }

      final length = sizePtr.value;
      if (length <= 0 || length >= _hostnameBufferChars) {
        disable('Plausibiliteitscontrole mislukte (length=$length)');
        return null;
      }
      return buf.cast<Utf16>().toDartString(length: length);
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      calloc.free(buf);
      calloc.free(sizePtr);
    }
  }
}

/// SYSTEM_INFO. The leading `union { DWORD dwOemId; struct { WORD;
/// WORD; }; }` is collapsed here to a plain 4-byte field — this
/// reader only ever reads `dwNumberOfProcessors` further down, so only
/// the union's *size* (4 bytes either way) needs to be right for the
/// fields after it to land on correct offsets, not its interpretation.
/// `Pointer<Void>` and the pointer-sized `dwActiveProcessorMask`
/// (declared `IntPtr`, matching `DWORD_PTR`'s native-word-size
/// definition) are what make this struct's layout genuinely need
/// getting right, unlike the fixed-size-only structs elsewhere in this
/// app's native readers.
final class _SystemInfo extends Struct {
  @Uint32()
  external int dwOemId;

  @Uint32()
  external int dwPageSize;

  external Pointer<Void> lpMinimumApplicationAddress;

  external Pointer<Void> lpMaximumApplicationAddress;

  @IntPtr()
  external int dwActiveProcessorMask;

  @Uint32()
  external int dwNumberOfProcessors;

  @Uint32()
  external int dwProcessorType;

  @Uint32()
  external int dwAllocationGranularity;

  @Uint16()
  external int wProcessorLevel;

  @Uint16()
  external int wProcessorRevision;
}
