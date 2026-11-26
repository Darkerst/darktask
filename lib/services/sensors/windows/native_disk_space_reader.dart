import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeDiskSpaceReader';

/// Direct `dart:ffi` bindings to four plain, decades-old `kernel32.dll`
/// exports — `GetLogicalDrives`, `GetDriveTypeW`, `GetDiskFreeSpaceExW`,
/// `GetVolumeInformationW` — replacing
/// `WindowsSensorService.readDisks()`'s `Get-CimInstance
/// Win32_LogicalDisk -Filter "DriveType=3"` WMI query.
///
/// **Added 2026-09-17.** This isn't just a screen-open cost:
/// [AlertMonitorService] calls `readDisks()` on its own independent
/// 20-second timer for the whole app's lifetime (the low-disk-space
/// alert), so the old WMI query was actually running continuously in
/// the background, PowerShell process included, even while no
/// disk-related screen was ever open. All four functions here are the
/// same safe category of API this app already trusts elsewhere
/// (`NativeMemoryReader`'s `GlobalMemoryStatusEx`,
/// `ProcessSnapshotReader`'s Toolhelp32 calls) — flat exports with a
/// fixed, documented signature, no COM, no vtables — not the
/// higher-risk category `DxgiAdapterNames` is held to.
///
/// `DRIVE_FIXED` (3) is checked via `GetDriveTypeW` to match WMI's own
/// `DriveType=3` filter exactly (local fixed disks only — excludes
/// removable drives, CD-ROM drives, network shares, and RAM disks, same
/// as before).
///
/// **Per-drive, not all-or-nothing.** A single drive letter that fails
/// one of these calls (not ready, permission issue, a flaky external
/// enclosure) is skipped rather than disabling this whole reader —
/// the same "one bad instance doesn't cost every other genuinely-usable
/// one" principle `PdhThermalZoneReader` already applies, and it
/// matches what the old WMI query would effectively do anyway (a drive
/// WMI can't query just doesn't appear in its result set). Only a
/// binding failure or a genuinely unexpected exception disables this
/// reader for the session.
class NativeDiskSpaceReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  static const int _driveFixed = 3;
  static const int _fileSystemNameBufferChars = 64;

  DynamicLibrary? _kernel32;
  late final int Function() _getLogicalDrives;
  late final int Function(Pointer<Utf16>) _getDriveTypeW;
  late final int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>) _getDiskFreeSpaceExW;
  late final int Function(
    Pointer<Utf16>,
    Pointer<Utf16>,
    int,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Utf16>,
    int,
  ) _getVolumeInformationW;

  bool _bound = false;

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      _getLogicalDrives =
          _kernel32!.lookupFunction<Uint32 Function(), int Function()>('GetLogicalDrives');
      _getDriveTypeW = _kernel32!
          .lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('GetDriveTypeW');
      _getDiskFreeSpaceExW = _kernel32!.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
          int Function(
              Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetDiskFreeSpaceExW');
      _getVolumeInformationW = _kernel32!.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Utf16>, int)>('GetVolumeInformationW');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe schijfruimte-uitlezing (dart:ffi, zonder WMI) actief.',
      );
      return true;
    } catch (e, st) {
      disable('Failed to bind kernel32.dll disk-space functions: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _bound = false;
    AppLogger.instance.info(
      _logSource,
      'Directe schijfruimte-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode (Win32_LogicalDisk). Dit bericht komt niet terug.',
    );
  }

  /// Returns one entry per local fixed drive: `{'device': 'C:',
  /// 'fsType': 'NTFS', 'totalBytes': ..., 'freeBytes': ...}`, or null if
  /// this path isn't usable at all (falls back to the existing WMI-based
  /// reading — see [WindowsSensorService.readDisks]).
  List<Map<String, Object>>? read() {
    if (!_ensureBound()) return null;

    try {
      final drivesBitmask = _getLogicalDrives();
      if (drivesBitmask == 0) {
        disable('GetLogicalDrives returned 0');
        return null;
      }

      final results = <Map<String, Object>>[];
      final totalBytesPtr = calloc<Uint64>();
      final freeBytesPtr = calloc<Uint64>();
      final freeToCallerPtr = calloc<Uint64>();
      final fsNameBuf = calloc<Uint16>(_fileSystemNameBufferChars);
      try {
        for (var i = 0; i < 26; i++) {
          if ((drivesBitmask & (1 << i)) == 0) continue;
          final letter = String.fromCharCode('A'.codeUnitAt(0) + i);
          // Trailing backslash required by both GetDriveTypeW's and
          // GetVolumeInformationW's documented contract for a root
          // path — see this class's doc.
          final rootPath = '$letter:\\';
          final rootPathPtr = rootPath.toNativeUtf16();
          try {
            if (_getDriveTypeW(rootPathPtr) != _driveFixed) continue;

            totalBytesPtr.value = 0;
            freeBytesPtr.value = 0;
            freeToCallerPtr.value = 0;
            final freeOk = _getDiskFreeSpaceExW(rootPathPtr, freeToCallerPtr, totalBytesPtr, freeBytesPtr);
            if (freeOk == 0) {
              AppLogger.instance.debug(_logSource, 'GetDiskFreeSpaceExW failed for $rootPath — skipped');
              continue;
            }
            final total = totalBytesPtr.value;
            final free = freeBytesPtr.value;
            if (total == 0) continue;

            fsNameBuf.asTypedList(_fileSystemNameBufferChars)[0] = 0;
            final volOk = _getVolumeInformationW(
              rootPathPtr,
              nullptr,
              0,
              nullptr,
              nullptr,
              nullptr,
              fsNameBuf.cast<Utf16>(),
              _fileSystemNameBufferChars,
            );
            final fsType = volOk != 0 ? fsNameBuf.cast<Utf16>().toDartString() : 'unknown';

            results.add({
              // "C:" — no trailing backslash, matching the exact
              // DeviceID format Win32_LogicalDisk used to return, so
              // every existing caller (UI display, alert matching)
              // keeps working unchanged.
              'device': '$letter:',
              'fsType': fsType.isEmpty ? 'unknown' : fsType,
              'totalBytes': total,
              'freeBytes': free,
            });
          } finally {
            calloc.free(rootPathPtr);
          }
        }
      } finally {
        calloc.free(totalBytesPtr);
        calloc.free(freeBytesPtr);
        calloc.free(freeToCallerPtr);
        calloc.free(fsNameBuf);
      }

      return results;
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }
}
