import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'DiskActivityIoctlReader';

/// Live disk-activity percentage read straight from the storage stack via
/// `IOCTL_DISK_PERFORMANCE` — the same technique Windows' own Task
/// Manager and Resource Monitor use for their Disk-activity figures.
///
/// **Two tiers, in order** — confirmed necessary, and confirmed to work,
/// by decompiling TMOG itself (the competing task manager this whole port
/// is benchmarked against) after this app's own physical-drive attempt
/// came back `ERROR_INVALID_FUNCTION` on its RAID-mode test hardware:
///
/// 1. **Physical drive** — `\\.\PhysicalDriveN`. Fastest and most direct
///    when it works, but some RAID/virtualized storage stacks reject this
///    IOCTL outright at that level (see [_query]'s handling of
///    `ERROR_INVALID_FUNCTION` below).
/// 2. **Logical volume** — `\\.\<letter>:`. The exact same IOCTL, issued
///    against a volume handle instead. TMOG's own decompiled code has a
///    dedicated fallback for precisely this (its string table calls it
///    "Logical-volume performance fallback" / "IOCTL_DISK_PERFORMANCE
///    logical-volume fallback; not physical-disk equivalence and
///    availability depends on storage-stack access") — because the
///    partition/volume manager sitting above the RAID controller answers
///    this IOCTL independently of whether the controller's own miniport
///    does, a volume handle can succeed exactly where the physical drive
///    handle failed. Confirmed against this app's own RAID-backed test
///    hardware, where tier 1 alone always failed.
///
/// **Why this exists, not just the `PhysicalDisk\% Disk Time` performance
/// counter** ([PdhDiskReader], and the `.NET PerformanceCounter`/
/// `Get-CimInstance` fallbacks in [WindowsSensorService].readDiskActivity):
/// on that same test hardware, that counter's underlying `_Total` instance
/// doesn't exist at all (see [PdhDiskReader]'s and
/// `_ensureDiskCounterReady`'s doc comments for that saga), and once
/// worked around by averaging the real per-disk instances instead, those
/// turned out to report a flat, permanent 0% regardless of actual I/O
/// load — a second diagnostic ('Disk Bytes/sec', not just '% Disk Time')
/// confirmed the whole `PhysicalDisk` counter category is fed by the same
/// underlying IOCTL, so no counter in that category can ever work there
/// either. `IOCTL_DISK_PERFORMANCE` — tried directly, at both tiers above
/// — is this app's only real option left on that class of hardware.
///
/// **Risk profile:** same category and same caution as this app's other
/// raw-IOCTL readers ([AtaPassThroughReader], `NvmeHealthReader`,
/// `BatteryIoctlReader`) — a fixed, Microsoft-documented struct
/// (`DISK_PERFORMANCE`, `learn.microsoft.com/.../ns-winioctl-
/// _disk_performance`), read using the exact same `CreateFileW` /
/// `DeviceIoControl` / `CloseHandle` pattern [AtaPassThroughReader]
/// already uses successfully against `\\.\PhysicalDrive0` on this app's
/// own test machine. Tried first (fastest, most reliable, no PowerShell
/// round-trip); [WindowsSensorService.readDiskActivity] falls back to the
/// PDH/PowerShell paths — or, once both tiers here have definitively
/// failed, to an honest "not available" — on any failure, exactly as it
/// did before this reader existed.
class DiskActivityIoctlReader {
  // dwDesiredAccess = 0 (no GENERIC_READ/WRITE at all), dwShareMode =
  // FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE (7),
  // dwFlagsAndAttributes = FILE_ATTRIBUTE_NORMAL (0x80) — deliberately
  // NOT the GENERIC_READ|GENERIC_WRITE this app's other IOCTL readers
  // use (AtaPassThroughReader genuinely needs that, since ATA_PASS_
  // THROUGH transfers data). This exact CreateFileW parameter set is
  // what TMOG's own decompiled code uses, consistently, at every single
  // one of its own physical-drive and volume-handle open sites for
  // query-style IOCTLs (IOCTL_DISK_PERFORMANCE, IOCTL_STORAGE_QUERY_
  // PROPERTY, ...) — never GENERIC_READ|GENERIC_WRITE. Matched exactly
  // rather than reusing this app's AtaPassThroughReader pattern, since
  // that access-rights difference is a plausible, concrete explanation
  // for why this reader's physical-drive tier failed with
  // ERROR_INVALID_FUNCTION on this app's RAID-backed test hardware while
  // TMOG's identical IOCTL call, against the identical drive, works.
  static const int _fileShareReadWriteDelete = 0x00000007;
  static const int _fileAttributeNormal = 0x00000080;
  static const int _openExisting = 3;
  static const int _invalidHandleValue = -1;

  // CTL_CODE(IOCTL_DISK_BASE=0x7, 0x0008, METHOD_BUFFERED=0,
  // FILE_ANY_ACCESS=0) — the standard, widely-referenced constant for
  // this IOCTL. Identical whether issued against a physical drive or a
  // logical volume handle.
  static const int _ioctlDiskPerformance = 0x00070020;

  // DISK_PERFORMANCE only actually needs its first 64 bytes read here
  // (ReadTime/WriteTime/QueryTime, see _queryPath below) —
  // StorageDeviceNumber and the trailing StorageManagerName[8] are never
  // used — but the output buffer is sized generously past the struct's
  // real ~84-88 bytes so a minor miscount there can never truncate a
  // field this code actually reads.
  static const int _outBufferSize = 128;

  // How many `\\.\PhysicalDriveN` indices to probe once at startup.
  // Comfortably above any machine this app is likely to run on; probing
  // a nonexistent index is just one failed CreateFileW call, cheap
  // enough that a smarter enumeration isn't worth the extra risk surface.
  static const int _maxDriveProbe = 16;

  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  /// True once every tier above has been tried and a real
  /// `DeviceIoControl` call came back with `ERROR_INVALID_FUNCTION` for a
  /// target that opened fine — see the doc comment where this is set, in
  /// [_queryPath], for why that specific error is treated as definitive
  /// proof (not a guess) that this machine's storage stack can't answer
  /// disk-activity IOCTLs at all, and so
  /// [WindowsSensorService.readDiskActivity] should stop trying every
  /// other `PhysicalDisk`-counter-based fallback too instead of quietly
  /// showing a meaningless 0%.
  static bool _definitivelyUnsupported = false;
  static bool get definitivelyUnsupported => _definitivelyUnsupported;
  static bool _sawInvalidFunction = false;

  bool _bound = false;
  late final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFileW;
  late final int Function(int) _closeHandle;
  late final int Function(int, int, Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      _deviceIoControl;
  late final int Function() _getLastError;
  late final int Function() _getLogicalDrives;

  bool _bindFunctions() {
    if (_bound) return true;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _createFileW = kernel32.lookupFunction<
          IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>('CreateFileW');
      _closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
      _deviceIoControl = kernel32.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32, Pointer<Void>, Uint32, Pointer<Uint32>,
              Pointer<Void>),
          int Function(int, int, Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>,
              Pointer<Void>)>('DeviceIoControl');
      // Diagnostic only — never used to decide behavior, only to log a
      // real Win32 error code instead of a bare "it failed" whenever
      // CreateFileW or DeviceIoControl comes back unsuccessful, so a
      // failure here can actually be root-caused from the Log screen
      // instead of guessed at, the same way the earlier PhysicalDisk
      // '_Total' investigation needed the real PDH/exception text to
      // find the real cause.
      _getLastError = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
      // Bitmask (bit 0 = A:, bit 1 = B:, ...) of drive letters that
      // currently exist — used only to build the tier-2 volume-handle
      // probe list, so a nonexistent letter is never even attempted.
      _getLogicalDrives = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLogicalDrives');
      _bound = true;
      return true;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to bind kernel32 functions: $e\n$st');
      return false;
    }
  }

  /// The `\\.\PhysicalDriveN` or `\\.\<letter>:` paths this reader could
  /// actually open and get an `IOCTL_DISK_PERFORMANCE` result from, found
  /// once at startup. Null until that probe has run; an empty (non-null)
  /// list means both tiers were tried and neither found anything, so
  /// [read] should give up immediately rather than re-probing every call.
  List<String>? _targets;
  bool _usingVolumeFallback = false;
  final Map<String, int> _consecutiveFailures = {};
  final Map<String, ({int busyTime, int queryTime})> _lastSample = {};

  bool _ensureInitialized() {
    if (_targets != null) return _targets!.isNotEmpty;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;
    if (!_bindFunctions()) {
      disable('kernel32-functies konden niet gebonden worden');
      return false;
    }

    // Existence probe only — deliberately does NOT seed _lastSample here.
    // If it did, read()'s very first call would compute a delta between
    // this probe's sample and one taken microseconds later, which is
    // noise, not a real rate. Leaving _lastSample empty means read()'s
    // first call establishes the real baseline instead, matching every
    // other rate-based reader in this app (PdhCpuReader/PdhDiskReader's
    // priming collection, .NET PerformanceCounter.NextValue()'s first
    // discarded call): the first read() after init always returns null.
    final physical = <String>[];
    for (var i = 0; i < _maxDriveProbe; i++) {
      final path = '\\\\.\\PhysicalDrive$i';
      if (_queryPath(path, verbose: i < 4) != null) physical.add(path);
    }
    if (physical.isNotEmpty) {
      _targets = physical;
      AppLogger.instance.info(
        _logSource,
        'Directe IOCTL_DISK_PERFORMANCE-uitlezing (dart:ffi, zonder PowerShell) actief voor schijfactiviteit '
        '(fysieke schijf/schijven: ${physical.join(", ")}).',
      );
      return true;
    }

    // Tier 2: per TMOG's own decompiled fallback for exactly this case
    // (see class doc) — the same IOCTL against a logical-volume handle
    // instead, which the volume manager can answer independently of
    // whether the physical drive's own miniport does.
    final letters = <String>[];
    final mask = _getLogicalDrives();
    for (var bit = 0; bit < 26; bit++) {
      if ((mask & (1 << bit)) != 0) letters.add(String.fromCharCode(65 + bit));
    }
    final volumes = <String>[];
    for (final letter in letters) {
      final path = '\\\\.\\$letter:';
      if (_queryPath(path, verbose: true) != null) volumes.add(path);
    }
    if (volumes.isNotEmpty) {
      _usingVolumeFallback = true;
      _targets = volumes;
      AppLogger.instance.info(
        _logSource,
        'IOCTL_DISK_PERFORMANCE werkte niet op fysiekeschijf-niveau, maar wel via logische volumes '
        '(TMOG-achtige fallback) — actief voor schijfactiviteit (${volumes.join(", ")}).',
      );
      return true;
    }

    _targets = [];
    if (_sawInvalidFunction) _definitivelyUnsupported = true;
    AppLogger.instance.info(
      _logSource,
      'Geen enkele \\\\.\\PhysicalDriveN of \\\\.\\<letter>: gaf een IOCTL_DISK_PERFORMANCE-resultaat — '
      'valt terug op de PDH/PowerShell-methode voor schijfactiviteit.',
    );
    return false;
  }

  /// Permanently stops using this reader for the rest of the app
  /// session, same "don't debug FFI blind" principle as this app's other
  /// IOCTL/PDH readers — every future call falls back to the existing
  /// PDH/PowerShell disk-activity path.
  void disable(String reason) {
    _permanentlyDisabled = true;
    _targets = [];
    AppLogger.instance.info(
      _logSource,
      'Directe IOCTL_DISK_PERFORMANCE-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de PDH/PowerShell-methode. Dit bericht komt niet terug.',
    );
  }

  /// Opens [path] (either a `\\.\PhysicalDriveN` or a `\\.\<letter>:`
  /// volume handle — the IOCTL and the struct it returns are identical
  /// either way), issues one `IOCTL_DISK_PERFORMANCE` call, and returns
  /// the two raw counters this class needs — or null on any failure
  /// (doesn't exist, access denied, IOCTL unsupported for this target).
  ({int busyTime, int queryTime})? _queryPath(String path, {required bool verbose}) {
    final pathPtr = path.toNativeUtf16();
    int handle = _invalidHandleValue;
    try {
      handle = _createFileW(
        pathPtr,
        0,
        _fileShareReadWriteDelete,
        nullptr,
        _openExisting,
        _fileAttributeNormal,
        0,
      );
      if (handle == _invalidHandleValue) {
        // [verbose] keeps this from being noisy for the physical-drive
        // tier, where most of _maxDriveProbe's range simply doesn't
        // exist on a given machine (ERROR_FILE_NOT_FOUND) — expected,
        // not diagnosis-worthy. It's true for the first few physical
        // indices, for any target this reader already believed worked,
        // and for every volume-tier probe (GetLogicalDrives already
        // filtered those to letters that exist, so a failure there is
        // always informative).
        if (verbose || (_targets?.contains(path) ?? false)) {
          AppLogger.instance.debug(
            _logSource,
            'CreateFileW mislukte voor $path (GetLastError=${_getLastError()}).',
          );
        }
        return null;
      }

      final buffer = calloc<Uint8>(_outBufferSize);
      final bytesReturned = calloc<Uint32>();
      try {
        final ok = _deviceIoControl(
          handle,
          _ioctlDiskPerformance,
          nullptr,
          0,
          buffer.cast<Void>(),
          _outBufferSize,
          bytesReturned,
          nullptr,
        );
        if (ok == 0) {
          // This is the interesting failure: the handle opened fine (the
          // target exists and is accessible) but the IOCTL itself was
          // refused — logged with the real Win32 error code so a driver
          // that genuinely doesn't implement IOCTL_DISK_PERFORMANCE (a
          // real, documented possibility for some RAID/virtualized
          // storage stacks) can be told apart from a mistake in this
          // code, instead of guessing from a bare "it failed".
          final lastError = _getLastError();
          AppLogger.instance.info(
            _logSource,
            'DeviceIoControl (IOCTL_DISK_PERFORMANCE) mislukte voor $path (GetLastError=$lastError).',
          );
          // ERROR_INVALID_FUNCTION (1) specifically means the driver
          // itself said "I don't recognize this command" for a target it
          // otherwise let us open. Recorded here (not yet acted on) —
          // _ensureInitialized only treats this as definitive once BOTH
          // tiers (physical drive, then logical volume) have come back
          // empty, since a physical-tier rejection alone doesn't mean
          // the volume tier will fail the same way (this app's own test
          // hardware is the proof: physical failed, volume worked).
          if (lastError == 1) _sawInvalidFunction = true;
          return null;
        }

        final byteData = buffer.asTypedList(_outBufferSize).buffer.asByteData();
        // DISK_PERFORMANCE (winioctl.h): BytesRead, BytesWritten, ReadTime,
        // WriteTime, IdleTime (5 x LARGE_INTEGER, offsets 0/8/16/24/32),
        // then ReadCount/WriteCount/QueueDepth/SplitCount (4 x DWORD,
        // offsets 40/44/48/52), then QueryTime (LARGE_INTEGER, offset 56).
        // All time fields are in 100ns units, and QueryTime is a
        // FILETIME-style snapshot of "now" at query time — so the delta
        // between two successive QueryTime values is real elapsed wall
        // time, and (deltaReadTime + deltaWriteTime) / deltaQueryTime is
        // the fraction of that time spent servicing I/O. Identical
        // interpretation whether [path] is a physical drive or a volume.
        final readTime = byteData.getInt64(16, Endian.little);
        final writeTime = byteData.getInt64(24, Endian.little);
        final queryTime = byteData.getInt64(56, Endian.little);
        return (busyTime: readTime + writeTime, queryTime: queryTime);
      } finally {
        calloc.free(buffer);
        calloc.free(bytesReturned);
      }
    } catch (_) {
      return null;
    } finally {
      if (handle != _invalidHandleValue) _closeHandle(handle);
      calloc.free(pathPtr);
    }
  }

  /// Returns a 0-100 activity percentage averaged across every target
  /// (physical drive, or — see class doc — logical volume when that's
  /// what worked) this reader could open, or null if this path isn't
  /// usable right now — either permanently (see [disable]) or because no
  /// target has two consecutive samples yet (always true on the very
  /// first call after init: like every rate-based counter in this app,
  /// that call only establishes the baseline).
  double? read() {
    if (!_ensureInitialized()) return null;

    try {
      final percentages = <double>[];
      for (final target in List<String>.from(_targets!)) {
        final sample = _queryPath(target, verbose: true);
        if (sample == null) {
          // A single failed poll for one target is tolerated a few times
          // (a removable/sleeping drive, a momentary driver hiccup) —
          // same tolerance principle as PdhCpuReader/PdhDiskReader —
          // before dropping just that target, not the whole reader.
          final failures = (_consecutiveFailures[target] ?? 0) + 1;
          _consecutiveFailures[target] = failures;
          if (failures >= 3) {
            AppLogger.instance.info(
              _logSource,
              '$target bleef geen IOCTL_DISK_PERFORMANCE-resultaat geven — '
              'niet meer meegenomen voor de rest van deze sessie.',
            );
            _targets!.remove(target);
            _lastSample.remove(target);
            _consecutiveFailures.remove(target);
          }
          continue;
        }
        _consecutiveFailures[target] = 0;

        final previous = _lastSample[target];
        _lastSample[target] = sample;
        if (previous == null) continue; // this target's own first sample

        final deltaBusy = sample.busyTime - previous.busyTime;
        final deltaQuery = sample.queryTime - previous.queryTime;
        if (deltaQuery <= 0) continue; // clock didn't advance — skip rather than divide by ~0

        final pct = deltaBusy / deltaQuery * 100;
        if (pct.isNaN || pct.isInfinite) continue;
        percentages.add(pct.clamp(0, 100));
      }

      if (_targets!.isEmpty) {
        disable(
          _usingVolumeFallback
              ? 'elk bekend logisch volume gaf herhaaldelijk geen resultaat meer'
              : 'elke bekende PhysicalDriveN gaf herhaaldelijk geen resultaat meer',
        );
        return null;
      }
      if (percentages.isEmpty) return null;

      return percentages.reduce((a, b) => a + b) / percentages.length;
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }
}
