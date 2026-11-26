import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'PdhFfi';

/// Direct `dart:ffi` bindings to Windows' Performance Data Helper API
/// (`pdh.dll`) — the same native API Task Manager, Process Explorer,
/// and HWiNFO use for live counters, bypassing PowerShell/WMI
/// entirely. No process spawning, no text serialization: this is a
/// same-process function call.
///
/// **This is the highest-risk piece of code in the entire Windows
/// port, and it is scoped down deliberately because of that.** Only
/// the single aggregate CPU load figure (`\Processor(_Total)\% '
/// 'Processor Time` + `% Privileged Time`) is read this way — not
/// per-core values, not any other counter category. Everything else
/// keeps using the already-working PowerShell PerformanceCounter path.
///
/// Why the caution: a mistake in a PowerShell script fails as readable
/// text — a wrong value, an error message, something to fix from a
/// log. A mistake in FFI struct layout, string encoding, or handle
/// lifetime can crash the *entire process* with an access violation
/// that no `try`/`catch` in Dart can intercept, because it isn't a
/// Dart-level exception — it's the operating system terminating the
/// process. This was written and reasoned through as carefully as
/// possible against Microsoft's documented PDH struct layouts, but it
/// has never run on an actual Windows machine, which is exactly the
/// kind of verification this specific category of bug most needs.
///
/// If anything about this misbehaves — including anything that merely
/// *seems* off, not just an outright crash — the fix is to stop using
/// it (see [PdhCpuReader.disable]) and fall back to the
/// PowerShell-based CPU reading that was already working before this
/// was added, not to debug FFI blind.
class PdhCpuReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  int? _hCounterTotal;
  int? _hCounterPrivileged;
  bool _initialized = false;

  // --- Native function signatures -----------------------------------
  //
  // All PDH_STATUS-returning functions use Int32/int — PDH_STATUS is a
  // 32-bit value (ERROR_SUCCESS = 0 on success). Handles (PDH_HQUERY,
  // PDH_HCOUNTER) are pointer-sized — represented as IntPtr/int
  // throughout, the standard Dart FFI approach for opaque Windows
  // HANDLEs (the same convention package:win32 uses for HWND, HANDLE,
  // etc.).

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;

  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;

  late final int Function(int query) _pdhCollectQueryData;

  late final int Function(int counter, int format, Pointer<Uint32> type, Pointer<_PdhFmtCounterValueDouble> value)
      _pdhGetFormattedCounterValue;

  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      // PdhAddEnglishCounterW (not PdhAddCounterW) deliberately —
      // this app already hit one locale-dependent bug on Windows
      // (lscpu's Linux equivalent); PdhAddCounterW resolves counter
      // *object* names through the current display language, while
      // the English variant always accepts the fixed English names
      // ("Processor", "% Processor Time") regardless of system locale.
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterValue = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>),
          int Function(int, int, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>)>('PdhGetFormattedCounterValue');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions: $e\n$st');
      return false;
    }
  }

  /// Opens the query and adds both counters once. Returns false (and
  /// permanently disables this reader for the rest of the session) on
  /// *any* failure — this is deliberately all-or-nothing rather than
  /// partially working, since a half-initialized native query is a
  /// worse state to poll from than simply not using this path at all.
  bool _ensureInitialized() {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      final totalCounter = _addCounter(r'\Processor(_Total)\% Processor Time');
      final privCounter = _addCounter(r'\Processor(_Total)\% Privileged Time');
      if (totalCounter == null || privCounter == null) {
        disable('Kon een of beide CPU-tellers niet toevoegen');
        return false;
      }
      _hCounterTotal = totalCounter;
      _hCounterPrivileged = privCounter;

      // PDH counters measuring a rate need one "priming" collection
      // before the first real value is meaningful — the same warm-up
      // requirement .NET's PerformanceCounter.NextValue() has, and the
      // same reason readCpu() already discards its very first Linux
      // reading.
      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(_logSource, 'Directe PDH-uitlezing (dart:ffi, zonder PowerShell) actief voor CPU-belasting.');
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  int? _addCounter(String path) {
    final pathPtr = path.toNativeUtf16();
    final counterHandle = calloc<IntPtr>();
    try {
      final status = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
      if (status != 0) {
        AppLogger.instance.debug(_logSource, 'PdhAddEnglishCounterW("$path") returned status 0x${status.toRadixString(16)}');
        return null;
      }
      return counterHandle.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(counterHandle);
    }
  }

  /// Permanently stops using this reader for the rest of the app
  /// session — never retried, matching the "don't debug FFI blind"
  /// principle in the class doc. Every future call falls back to
  /// whatever the caller's non-FFI path is.
  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de PowerShell-methode voor CPU-belasting. Dit bericht komt niet terug.',
    );
    _closeQuietly();
  }

  void _closeQuietly() {
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {
      // Already in a failure path — nothing more this can safely do.
    }
    _hQuery = null;
    _hCounterTotal = null;
    _hCounterPrivileged = null;
  }

  /// Returns `{'overall': ..., 'privileged': ...}` as 0-100 doubles, or
  /// null if this path isn't usable (falls back to the existing
  /// PowerShell-based reading — see [WindowsSensorService.readCpu]).
  int _consecutiveTransientFailures = 0;
  static const _maxConsecutiveTransientFailures = 3;

  /// Returns `{'overall': ..., 'privileged': ...}` (0-100), or null if
  /// this path isn't usable right now — either permanently (see
  /// [disable]) or for this one call (a transient PDH hiccup, retried
  /// on the next call rather than disabling the whole reader).
  ///
  /// Two different failure categories are treated differently here.
  /// `PdhCollectQueryData` returning a non-zero status, or
  /// `PdhGetFormattedCounterValue` yielding no usable value, are
  /// PDH's own documented behavior when a query is collected again too
  /// soon after the last collection (PDH_CSTATUS_INVALID_DATA) — a
  /// real, observed symptom of this app's "alles tegelijk" stress test
  /// calling `readCpu()` (and so this reader) several times a second
  /// from multiple concurrent sub-benchmarks, not a sign this reader is
  /// broken. A handful of consecutive misses is tolerated before
  /// falling back to the PowerShell path, same tolerance principle as
  /// the benchmark safety timers' own consecutive-timeout allowance.
  /// An implausible *value* (outside 0-100, NaN) or an outright
  /// exception are treated differently — those point at a genuine
  /// struct/layout bug rather than transient contention, so they still
  /// disable this reader immediately, same as before.
  Map<String, double>? read() {
    if (!_ensureInitialized()) return null;

    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhCollectQueryData bleef een foutstatus geven (0x${collectStatus.toRadixString(16)}, '
              '$_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      final overall = _formatValue(_hCounterTotal!);
      final privileged = _formatValue(_hCounterPrivileged!);
      if (overall == null || privileged == null) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhGetFormattedCounterValue bleef geen bruikbare waarde geven '
              '($_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      // A raw sanity check, not just a happy-path read: percentages
      // outside this range mean something is misinterpreting memory,
      // not that the CPU is actually at -40% or 900% load. Trusting an
      // implausible number here would be worse than falling back. This
      // stays an immediate, permanent disable (not the transient-retry
      // path above) — an implausible value is far more likely to mean
      // this reader is misreading memory than that it hit a one-off
      // timing hiccup.
      if (overall.isNaN || overall < 0 || overall > 100 || privileged.isNaN || privileged < 0 || privileged > 100) {
        disable('Plausibiliteitscontrole mislukte (overall=$overall, privileged=$privileged)');
        return null;
      }

      _consecutiveTransientFailures = 0;
      return {'overall': overall, 'privileged': privileged};
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }

  double? _formatValue(int counter) {
    final typePtr = calloc<Uint32>();
    final valuePtr = calloc<_PdhFmtCounterValueDouble>();
    try {
      final status = _pdhGetFormattedCounterValue(counter, _pdhFmtDouble, typePtr, valuePtr);
      if (status != 0) return null;
      // CStatus inside the value struct itself also needs checking —
      // PdhGetFormattedCounterValue can return overall success while
      // still flagging e.g. PDH_CSTATUS_INVALID_DATA for this specific
      // sample (most commonly right after the priming collection).
      if (valuePtr.ref.cStatus != 0) return null;
      return valuePtr.ref.doubleValue;
    } finally {
      calloc.free(typePtr);
      calloc.free(valuePtr);
    }
  }
}

/// Same approach and same safety rules as [PdhCpuReader] (see its class
/// doc — everything there about crash risk, the transient-vs-permanent
/// failure split, and plausibility-checking applies identically here),
/// for a single counter instead of two: `\PhysicalDisk(_Total)\% Disk
/// Time`.
///
/// **Fixed 2026-09-07**: this reader used to disable itself permanently
/// on the very first non-zero `PdhCollectQueryData` status, with none of
/// [PdhCpuReader]'s tolerance for a few consecutive misses. In practice
/// that meant it disabled itself on essentially every session — observed
/// live via the Log screen: `PdhCollectQueryData returned status
/// 0x-7ffff82b` (PDH_NO_DATA, 0x800007D5) on the very next poll after a
/// clean init, a well-documented transient PhysicalDisk-counter hiccup,
/// not a sign of a struct/memory bug. Now retried the same number of
/// times as CPU before giving up for the session.
///
/// Deliberately NOT extended to per-adapter network throughput yet —
/// disk activity only ever needs the safe, fixed `_Total` instance
/// name, while network adapter instance names can contain characters
/// (parentheses, brackets) that collide with PDH's own counter-path
/// syntax (`\Category(Instance)\Counter`) and would need careful,
/// separately-verified escaping this class doesn't attempt.
class PdhDiskReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  int? _hCounter;
  bool _initialized = false;

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;
  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;
  late final int Function(int query) _pdhCollectQueryData;
  late final int Function(int counter, int format, Pointer<Uint32> type, Pointer<_PdhFmtCounterValueDouble> value)
      _pdhGetFormattedCounterValue;
  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterValue = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>),
          int Function(int, int, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>)>('PdhGetFormattedCounterValue');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions (disk): $e\n$st');
      return false;
    }
  }

  bool _ensureInitialized() {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      final pathPtr = r'\PhysicalDisk(_Total)\% Disk Time'.toNativeUtf16();
      final counterHandle = calloc<IntPtr>();
      try {
        final addStatus = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
        if (addStatus != 0) {
          disable('PdhAddEnglishCounterW returned status 0x${addStatus.toRadixString(16)}');
          return false;
        }
        _hCounter = counterHandle.value;
      } finally {
        calloc.free(pathPtr);
        calloc.free(counterHandle);
      }

      // Same warm-up requirement as PdhCpuReader — a rate counter's
      // first collection primes it, it isn't yet a meaningful value.
      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(_logSource, 'Directe PDH-uitlezing (dart:ffi, zonder PowerShell) actief voor schijfactiviteit.');
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing (schijf) uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de PowerShell-methode. Dit bericht komt niet terug.',
    );
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {}
    _hQuery = null;
    _hCounter = null;
  }

  // Same tolerance principle as PdhCpuReader.read() (see that method's
  // doc for the full reasoning): PdhCollectQueryData returning a
  // non-zero status, or PdhGetFormattedCounterValue yielding no usable
  // value, are PDH's own documented behavior for a query that's been
  // collected again too soon, or hit a one-off provider hiccup
  // (PDH_NO_DATA and friends) — not a sign this reader is broken. A
  // handful of consecutive misses is tolerated before falling back to
  // the PowerShell path. An implausible *value* (negative, NaN) or an
  // outright exception still disable this reader immediately, same as
  // before — those point at a genuine struct/layout bug, not transient
  // contention.
  int _consecutiveTransientFailures = 0;
  static const _maxConsecutiveTransientFailures = 3;

  /// Returns a 0-100 percentage, or null if this path isn't usable
  /// right now — either permanently (see [disable]) or for this one
  /// call (a transient PDH hiccup, retried on the next call rather
  /// than disabling the whole reader). Falls back to the existing
  /// PerformanceCounter-via-PowerShell reading either way — see
  /// [WindowsSensorService.readDiskActivity].
  double? read() {
    if (!_ensureInitialized()) return null;

    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhCollectQueryData bleef een foutstatus geven (0x${collectStatus.toRadixString(16)}, '
              '$_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      final typePtr = calloc<Uint32>();
      final valuePtr = calloc<_PdhFmtCounterValueDouble>();
      double? value;
      try {
        final status = _pdhGetFormattedCounterValue(_hCounter!, _pdhFmtDouble, typePtr, valuePtr);
        if (status == 0 && valuePtr.ref.cStatus == 0) {
          value = valuePtr.ref.doubleValue;
        }
      } finally {
        calloc.free(typePtr);
        calloc.free(valuePtr);
      }

      if (value == null) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhGetFormattedCounterValue bleef geen bruikbare waarde geven '
              '($_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      // Disk time is a percentage, but PDH's "% Disk Time" can
      // legitimately read slightly above 100 on disks with queued
      // I/O across multiple channels — clamped rather than treated as
      // implausible the way CPU's stricter 0-100 check works, since
      // this is documented PDH behavior, not a sign of a memory bug.
      // This stays an immediate, permanent disable (not the
      // transient-retry path above) — an implausible value is far more
      // likely to mean this reader is misreading memory than that it
      // hit a one-off timing hiccup.
      if (value.isNaN || value < 0) {
        disable('Plausibiliteitscontrole mislukte (value=$value)');
        return null;
      }

      _consecutiveTransientFailures = 0;
      return value.clamp(0, 100);
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }
}

/// Same approach and safety rules as [PdhCpuReader]/[PdhDiskReader]
/// (see [PdhCpuReader]'s class doc for the full reasoning on crash
/// risk and disable-on-any-failure), extended to a *list* of network
/// adapters instead of one fixed counter.
///
/// **All-or-nothing, deliberately**: if even one adapter's counters
/// fail to add, the whole reader disables itself rather than serving
/// a partial adapter list — a half-working state (some adapters via
/// PDH, others silently missing) is worse than cleanly falling back to
/// the existing PowerShell-based reading for all of them.
///
/// Takes the adapter instance name list as a parameter rather than
/// enumerating them itself via PDH's own object/instance APIs
/// (`PdhEnumObjectItemsW`) — that API's double-null-terminated wide
/// string list marshaling is a meaningfully larger, less-tested
/// surface than reusing a list [WindowsSensorService] already safely
/// obtained via .NET's `PerformanceCounterCategory.GetInstanceNames()`.
/// Those names are exactly what a raw PDH counter path needs too:
/// Windows itself replaces literal `(`/`)` in adapter names with
/// `[`/`]` before registering them as performance-counter instances,
/// specifically to avoid colliding with PDH's own
/// `\Category(Instance)\Counter` path syntax — so the names .NET hands
/// back are already safe to embed verbatim.
class PdhNetworkReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  final Map<String, (int, int)> _counters = {}; // name -> (rxHandle, txHandle)
  bool _initialized = false;

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;
  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;
  late final int Function(int query) _pdhCollectQueryData;
  late final int Function(int counter, int format, Pointer<Uint32> type, Pointer<_PdhFmtCounterValueDouble> value)
      _pdhGetFormattedCounterValue;
  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterValue = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>),
          int Function(int, int, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>)>('PdhGetFormattedCounterValue');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions (network): $e\n$st');
      return false;
    }
  }

  int? _addCounter(String path) {
    final pathPtr = path.toNativeUtf16();
    final counterHandle = calloc<IntPtr>();
    try {
      final status = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
      if (status != 0) {
        AppLogger.instance.debug(_logSource, 'PdhAddEnglishCounterW("$path") returned status 0x${status.toRadixString(16)}');
        return null;
      }
      return counterHandle.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(counterHandle);
    }
  }

  bool _ensureInitialized(List<String> adapterNames) {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;
    if (adapterNames.isEmpty) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      for (final name in adapterNames) {
        final rxHandle = _addCounter('\\Network Interface($name)\\Bytes Received/sec');
        final txHandle = _addCounter('\\Network Interface($name)\\Bytes Sent/sec');
        if (rxHandle == null || txHandle == null) {
          // All-or-nothing: one bad adapter name means the whole
          // reader steps aside rather than silently missing an
          // adapter every future poll.
          disable('Kon tellers voor adapter "$name" niet toevoegen');
          return false;
        }
        _counters[name] = (rxHandle, txHandle);
      }

      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(
        _logSource,
        'Directe PDH-uitlezing (dart:ffi, zonder PowerShell) actief voor netwerk (${adapterNames.length} adapter(s)).',
      );
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing (netwerk) uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de PowerShell-methode. Dit bericht komt niet terug.',
    );
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {}
    _hQuery = null;
    _counters.clear();
  }

  /// Returns `{adapterName: (rxBytesPerSec, txBytesPerSec)}` for every
  /// adapter in [adapterNames], or null if this path isn't usable
  /// (falls back to the existing PerformanceCounter-via-PowerShell
  /// reading — see [WindowsSensorService.readNetwork]).
  Map<String, (double, double)>? read(List<String> adapterNames) {
    if (!_ensureInitialized(adapterNames)) return null;

    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        disable('PdhCollectQueryData returned status 0x${collectStatus.toRadixString(16)}');
        return null;
      }

      final result = <String, (double, double)>{};
      for (final entry in _counters.entries) {
        final rx = _formatValue(entry.value.$1);
        final tx = _formatValue(entry.value.$2);
        if (rx == null || tx == null) {
          disable('Kon geen waarde lezen voor adapter "${entry.key}"');
          return null;
        }
        if (rx.isNaN || rx < 0 || tx.isNaN || tx < 0) {
          disable('Plausibiliteitscontrole mislukte voor adapter "${entry.key}" (rx=$rx, tx=$tx)');
          return null;
        }
        result[entry.key] = (rx, tx);
      }
      return result;
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }

  double? _formatValue(int counter) {
    final typePtr = calloc<Uint32>();
    final valuePtr = calloc<_PdhFmtCounterValueDouble>();
    try {
      final status = _pdhGetFormattedCounterValue(counter, _pdhFmtDouble, typePtr, valuePtr);
      if (status != 0) return null;
      if (valuePtr.ref.cStatus != 0) return null;
      return valuePtr.ref.doubleValue;
    } finally {
      calloc.free(typePtr);
      calloc.free(valuePtr);
    }
  }
}

/// Reads live GPU engine utilization directly via PDH's dynamic
/// `\GPU Engine(*)\Utilization Percentage` counter set — the exact
/// same counter Windows' own Task Manager reads for its GPU usage
/// graphs. This exists to remove LibreHardwareMonitor's slow
/// `Computer.Open()` hardware scan (~2.5s) from the GPU *load* number
/// specifically, the same way [PdhCpuReader] already removed
/// PowerShell from CPU load: this is a same-process pdh.dll call, no
/// process spawning, no .NET, no admin rights, no background service
/// dependency — it works even before the achtergronddienst has ever
/// been set up.
///
/// **Per-adapter, not system-wide.** Unlike `\Processor(_Total)` or
/// `\PhysicalDisk(_Total)`, GPU Engine counter *instances* are created
/// and destroyed continuously — one per (process, adapter, engine-type)
/// combination, named like
/// `pid_1234_luid_0x00000000_0x0000ABCD_ntype_dxgi_adapter_0_engtype_3D`.
/// A single wildcard counter (instance `*`) is added once; every
/// [readByAdapter] enumerates however many instances exist *right now*
/// via `PdhGetFormattedCounterArrayW`, groups them by the LUID embedded
/// in each instance name (plain substring/regex parsing — no COM here),
/// and takes the busiest single engine per LUID (engines run in
/// parallel on a modern GPU, so summing them would double-count) —
/// returning `{normalizedLuidKey: percentage}` for every adapter with
/// active engine instances right now.
///
/// Turning a LUID into a specific adapter's *name* (so a system with
/// both a discrete and an integrated GPU shows "AMD: 40%, Intel: 2%"
/// instead of one ambiguous combined number) is [DxgiAdapterNames]'s
/// job — see that class's doc for the COM/DXGI side of this and, in
/// particular, why it's held to a materially higher verification bar
/// than this file: a wrong vtable slot there calls an arbitrary wrong
/// method with the wrong signature, a much harder-to-diagnose failure
/// mode than anything in this file, where every failure is just a PDH
/// status code. [WindowsSensorService._readGenericGpusWindows] is what
/// joins this class's output with [DxgiAdapterNames]'s — both keyed by
/// the same [_extractLuidKey] normalization so the join needs no
/// knowledge of which of LUID's two 32-bit halves either source
/// happens to put first.
///
/// Same safety rules as every other reader in this file (see
/// [PdhCpuReader]'s class doc for the full reasoning): flat pdh.dll
/// calls and flat struct/array parsing only, self-disabling on any
/// failure or implausible value, falling back to the existing
/// LibreHardwareMonitor/achtergronddienst-based reading either way.
class PdhGpuReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  int? _hCounter;
  bool _initialized = false;

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;
  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;
  late final int Function(int query) _pdhCollectQueryData;
  late final int Function(
          int counter, int format, Pointer<Uint32> bufferSize, Pointer<Uint32> itemCount, Pointer<Uint8> itemBuffer)
      _pdhGetFormattedCounterArray;
  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;

  // PDH_STATUS values, as the signed 32-bit ints Dart FFI's Int32
  // return type produces (matching this file's established convention
  // of logging raw status codes via toRadixString(16), e.g.
  // PdhDiskReader's doc citing "0x-7ffff82b" for PDH_NO_DATA). Both
  // are documented, ordinary PDH outcomes — not failures:
  // PDH_MORE_DATA (0x800007D2) is the *expected* result of the
  // size-query call below, and PDH_CSTATUS_NO_INSTANCE (0x800007D1)
  // means the wildcard currently matches zero instances, i.e. no
  // process is using the GPU at all right now — genuinely 0% load,
  // not an error.
  static const _pdhMoreData = -2147481646;
  static const _pdhCstatusNoInstance = -2147481647;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterArray = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>),
          int Function(int, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>)>('PdhGetFormattedCounterArrayW');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions (gpu): $e\n$st');
      return false;
    }
  }

  bool _ensureInitialized() {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      // The "*" instance wildcard is the documented, standard way to
      // subscribe to every current and future instance of a dynamic
      // counter object at once — consumed below via
      // PdhGetFormattedCounterArrayW rather than
      // PdhGetFormattedCounterValue, which only ever returns a single
      // instance's value.
      final pathPtr = r'\GPU Engine(*)\Utilization Percentage'.toNativeUtf16();
      final counterHandle = calloc<IntPtr>();
      try {
        final addStatus = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
        if (addStatus != 0) {
          disable('PdhAddEnglishCounterW returned status 0x${addStatus.toRadixString(16)}');
          return false;
        }
        _hCounter = counterHandle.value;
      } finally {
        calloc.free(pathPtr);
        calloc.free(counterHandle);
      }

      // Same warm-up requirement as every other reader here — a rate
      // counter's first collection primes it. Succeeds regardless of
      // how many GPU Engine instances happen to exist at this exact
      // moment (that only matters once we ask for values via
      // PdhGetFormattedCounterArrayW in read()).
      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(_logSource, 'Directe PDH-uitlezing (dart:ffi, zonder LibreHardwareMonitor) actief voor GPU-belasting.');
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing (GPU) uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de LibreHardwareMonitor/achtergronddienst-methode. Dit bericht komt niet terug.',
    );
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {}
    _hQuery = null;
    _hCounter = null;
  }

  // Same tolerance principle as the other readers in this file (see
  // PdhCpuReader.read()'s doc for the full reasoning): a transient
  // collection/array hiccup is retried a few times before this reader
  // gives up for the session; an implausible value or an outright
  // exception disables it immediately.
  int _consecutiveTransientFailures = 0;
  static const _maxConsecutiveTransientFailures = 3;

  /// Returns `{normalizedLuidKey: percentage}` — the busiest engine's
  /// utilization (0-100) for every physical adapter that currently has
  /// active GPU Engine instances. An adapter with none simply doesn't
  /// appear in the map (an idle GPU is a real, valid reading, not a
  /// failure — the returned map can legitimately be empty). Returns
  /// `null` only if this path isn't usable at all right now (falls
  /// back to the existing LibreHardwareMonitor/achtergronddienst-based
  /// reading — see [WindowsSensorService._readGenericGpusWindows]).
  /// `normalizedLuidKey` matches [DxgiAdapterNames]'s own
  /// normalization exactly (see [_extractLuidKey] and that class's
  /// doc) — that's what lets the two be joined without either side
  /// needing to know the other's raw LUID format.
  Map<String, double>? readByAdapter() {
    if (!_ensureInitialized()) return null;

    final bufferSizePtr = calloc<Uint32>();
    final itemCountPtr = calloc<Uint32>();
    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhCollectQueryData bleef een foutstatus geven (0x${collectStatus.toRadixString(16)}, '
              '$_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      // Two-call pattern (standard for every PDH "array" API): first
      // ask how large the buffer needs to be. PDH_MORE_DATA here is
      // success, not an error — it's PDH's documented way of reporting
      // the required size. PDH_CSTATUS_NO_INSTANCE means the GPU is
      // genuinely idle (zero engine instances exist right now).
      bufferSizePtr.value = 0;
      itemCountPtr.value = 0;
      final sizeStatus = _pdhGetFormattedCounterArray(_hCounter!, _pdhFmtDouble, bufferSizePtr, itemCountPtr, nullptr);
      if (sizeStatus == _pdhCstatusNoInstance) {
        _consecutiveTransientFailures = 0;
        return const {};
      }
      if (sizeStatus != _pdhMoreData && sizeStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhGetFormattedCounterArrayW (grootte-opvraag) gaf status 0x${sizeStatus.toRadixString(16)} '
              '($_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }
      if (bufferSizePtr.value == 0 || itemCountPtr.value == 0) {
        _consecutiveTransientFailures = 0;
        return const {};
      }

      final buffer = calloc<Uint8>(bufferSizePtr.value);
      try {
        final arrayStatus =
            _pdhGetFormattedCounterArray(_hCounter!, _pdhFmtDouble, bufferSizePtr, itemCountPtr, buffer);
        if (arrayStatus != 0) {
          _consecutiveTransientFailures++;
          if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
            disable('PdhGetFormattedCounterArrayW gaf status 0x${arrayStatus.toRadixString(16)} '
                '($_consecutiveTransientFailures keer op rij)');
          }
          return null;
        }

        final items = buffer.cast<_PdhCounterArrayItem>();
        // Sum per (LUID, engine-type) — multiple processes can each
        // have their own instance of the *same* engine, and their
        // individual percentages are additive (that's the whole point
        // of Utilization Percentage being per-process). Different
        // engine types on the *same* LUID are not summed here — see
        // the busiest-per-LUID step below.
        final perLuidEngineSum = <String, double>{};
        for (var i = 0; i < itemCountPtr.value; i++) {
          final item = items[i];
          if (item.cStatus != 0) continue; // this one instance had no valid sample yet
          if (item.szName == nullptr) continue;
          final value = item.doubleValue;
          if (value.isNaN || value < 0) continue;
          final name = item.szName.toDartString();
          final luidKey = _extractLuidKey(name);
          final engineType = _extractEngineType(name);
          if (luidKey == null || engineType == null) continue;
          final key = '$luidKey|$engineType';
          perLuidEngineSum[key] = (perLuidEngineSum[key] ?? 0) + value;
        }

        // Per physical adapter (LUID), a GPU's engines run in
        // parallel, so the adapter's overall utilization is its
        // *busiest* single engine, not the sum of all of them —
        // summing would double- or triple-count a GPU that's, say,
        // simultaneously doing 3D rendering and video decode.
        final perLuidBusiest = <String, double>{};
        for (final entry in perLuidEngineSum.entries) {
          final luidKey = entry.key.split('|').first;
          final clamped = entry.value.clamp(0, 100).toDouble();
          if (clamped > (perLuidBusiest[luidKey] ?? 0)) {
            perLuidBusiest[luidKey] = clamped;
          }
        }

        for (final v in perLuidBusiest.values) {
          if (v.isNaN || v < 0 || v > 100) {
            disable('Plausibiliteitscontrole mislukte (waarde=$v)');
            return null;
          }
        }

        _consecutiveTransientFailures = 0;
        return perLuidBusiest;
      } finally {
        calloc.free(buffer);
      }
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      calloc.free(bufferSizePtr);
      calloc.free(itemCountPtr);
    }
  }

  /// Parses the two `0x...` hex groups out of a PDH GPU Engine
  /// instance name (e.g. `..._luid_0x00000000_0x0000ABCD_...`) and
  /// normalizes them the same order-independent way
  /// [DxgiAdapterNames]'s own LUID reading does: both values sorted
  /// ascending and joined as decimal. This is deliberately NOT a raw
  /// string match against Microsoft's own hex formatting — sorting
  /// numerically means this side and DXGI's side agree regardless of
  /// which of LUID's two 32-bit halves (`LowPart`/`HighPart`) the PDH
  /// instance-name string happens to put first, and regardless of hex
  /// case or leading-zero differences between the two sources.
  static String? _extractLuidKey(String instanceName) {
    final match = RegExp(r'luid_(0x[0-9A-Fa-f]+)_(0x[0-9A-Fa-f]+)').firstMatch(instanceName);
    if (match == null) return null;
    try {
      final a = int.parse(match.group(1)!.substring(2), radix: 16);
      final b = int.parse(match.group(2)!.substring(2), radix: 16);
      final values = [a, b]..sort();
      return '${values[0]}_${values[1]}';
    } catch (_) {
      return null;
    }
  }

  static String? _extractEngineType(String instanceName) {
    final match = RegExp(r'engtype_(\w+)').firstMatch(instanceName);
    return match?.group(1);
  }
}

/// Reads CPU/system temperature as an absolute last-resort fallback,
/// via the same universal, driver-free, admin-free mechanism TMOG —
/// the task manager DarkTask is inspired by — uses to still show *a*
/// temperature on laptops where [LibreHardwareMonitorBridge]'s MSR/EC-
/// based reading comes up empty (unsupported CPU generation,
/// undocumented embedded controller, VBS/Memory-Integrity blocking a
/// specific process's MSR access, ...). Confirmed by reading TMOG's own
/// disassembly: it names this exact path `windows.thermal.acpi-perflib`
/// internally.
///
/// `\Thermal Zone Information(*)\Temperature` is a performance counter
/// Windows' own ACPI driver (`acpi.sys`) exposes for every ACPI thermal
/// zone the firmware reports. Reporting at least one thermal zone is a
/// mandatory part of the ACPI spec, so virtually every laptop has one
/// — regardless of CPU generation, EC vendor, or whether
/// LibreHardwareMonitor has ever heard of that specific hardware. No
/// admin rights, no extra kernel driver, no .NET/PowerShell — just
/// pdh.dll, same as every other reader in this file.
///
/// **Deliberately coarse, and treated as such.** An ACPI thermal zone
/// is not guaranteed to be the CPU package specifically — it's
/// whatever the firmware wired up for thermal throttling, which on a
/// laptop tends to sit near the CPU but isn't a precise per-core
/// reading the way an MSR read is. Multiple zones can exist at once
/// (CPU-adjacent, chassis/skin, battery, ...); this reads all of them
/// and returns the *highest*, on the reasoning that the hottest
/// available zone on a laptop is both the most useful number for a
/// warning banner and the one most likely tracking whatever's closest
/// to the CPU. This is a last-resort "is there a number at all" source
/// — see [WindowsSensorService._lastKnownCpuTempC]/`readCpu()` for how
/// it's tried only after [BackgroundSensorFeed] and
/// [LibreHardwareMonitorBridge] have both already come up empty, never
/// above either.
///
/// Same overall safety rules as every other reader in this file (see
/// [PdhCpuReader]'s class doc for the full reasoning on crash risk and
/// the transient-vs-permanent failure split) — but with one deliberate
/// difference: a single implausible *zone* (garbage firmware data on
/// one of several reported zones) is skipped rather than disabling the
/// whole reader, since thermal zones are far more heterogeneous across
/// vendors than the single well-defined CPU/disk/network counters the
/// other readers here consume — one bad zone shouldn't cost every
/// other, genuinely-usable zone this reader could still report.
class PdhThermalZoneReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  int? _hCounter;
  bool _initialized = false;

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;
  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;
  late final int Function(int query) _pdhCollectQueryData;
  late final int Function(
          int counter, int format, Pointer<Uint32> bufferSize, Pointer<Uint32> itemCount, Pointer<Uint8> itemBuffer)
      _pdhGetFormattedCounterArray;
  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;
  // Same documented PDH_STATUS values as [PdhGpuReader] (see its own
  // doc for why these two specifically aren't failures).
  static const _pdhMoreData = -2147481646;
  static const _pdhCstatusNoInstance = -2147481647;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterArray = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>),
          int Function(int, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>)>('PdhGetFormattedCounterArrayW');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions (thermal zone): $e\n$st');
      return false;
    }
  }

  bool _ensureInitialized() {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      // The "*" instance wildcard picks up every ACPI thermal zone the
      // firmware reports, whatever they're named (zone names are
      // vendor/firmware-specific, e.g. "_TZ.TZ00") — same wildcard
      // approach as [PdhGpuReader]'s GPU Engine counter.
      final pathPtr = r'\Thermal Zone Information(*)\Temperature'.toNativeUtf16();
      final counterHandle = calloc<IntPtr>();
      try {
        final addStatus = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
        if (addStatus != 0) {
          disable('PdhAddEnglishCounterW returned status 0x${addStatus.toRadixString(16)}');
          return false;
        }
        _hCounter = counterHandle.value;
      } finally {
        calloc.free(pathPtr);
        calloc.free(counterHandle);
      }

      // Thermal zone temperature is an instantaneous value, not a rate
      // counter — this priming collection isn't strictly required the
      // way it is for the rate-based readers above, but costs nothing
      // and keeps this reader's init shape consistent with the rest of
      // this file.
      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(
        _logSource,
        'Directe PDH-uitlezing (dart:ffi) actief voor ACPI thermal zones — laatste redmiddel voor '
        'CPU-temperatuur wanneer de achtergronddienst en LibreHardwareMonitor allebei geen waarde kunnen leveren.',
      );
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing (thermal zone) uitgeschakeld voor de rest van deze sessie ($reason). '
      'Dit bericht komt niet terug.',
    );
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {}
    _hQuery = null;
    _hCounter = null;
  }

  int _consecutiveTransientFailures = 0;
  static const _maxConsecutiveTransientFailures = 3;

  // One-shot diagnostic logging (same "log the *why*, once" convention
  // LibreHardwareMonitorBridge's own sensor dump uses) — without these,
  // a report of "still no temperature" gives no way to tell whether
  // this reader found zero ACPI thermal zones at all on that machine
  // (the counter category exists but nothing subscribes to it — a real
  // possibility on some firmware/VMs) versus finding zones whose raw
  // values all failed the plausibility check (firmware reporting
  // garbage) versus something else entirely.
  bool _loggedNoInstanceDiagnostic = false;
  bool _loggedAllFilteredDiagnostic = false;

  /// Returns the highest current ACPI thermal zone reading in Celsius,
  /// or null if this path isn't usable right now — no zones reported
  /// on this machine at all, a transient PDH hiccup (retried on the
  /// next call), or this reader has permanently disabled itself. Never
  /// a partial or guessed value.
  double? read() {
    if (!_ensureInitialized()) return null;

    final bufferSizePtr = calloc<Uint32>();
    final itemCountPtr = calloc<Uint32>();
    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhCollectQueryData bleef een foutstatus geven (0x${collectStatus.toRadixString(16)}, '
              '$_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      bufferSizePtr.value = 0;
      itemCountPtr.value = 0;
      final sizeStatus = _pdhGetFormattedCounterArray(_hCounter!, _pdhFmtDouble, bufferSizePtr, itemCountPtr, nullptr);
      if (sizeStatus == _pdhCstatusNoInstance) {
        // No ACPI thermal zones reported on this machine at all —
        // genuinely nothing for this reader to fall back to, not a
        // transient hiccup, so this doesn't count against the
        // transient-failure tolerance below.
        _consecutiveTransientFailures = 0;
        if (!_loggedNoInstanceDiagnostic) {
          _loggedNoInstanceDiagnostic = true;
          AppLogger.instance.info(
            _logSource,
            'ACPI thermal zone-teller bestaat op dit systeem, maar rapporteert momenteel nul zones '
            '(PDH_CSTATUS_NO_INSTANCE) — dit laatste redmiddel heeft hier dus niets om op terug te vallen. '
            'Komt voor op sommige firmware/VM\'s die geen ACPI-thermal-zone-object registreren. Dit bericht komt niet terug.',
          );
        }
        return null;
      }
      if (sizeStatus != _pdhMoreData && sizeStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhGetFormattedCounterArrayW (grootte-opvraag) gaf status 0x${sizeStatus.toRadixString(16)} '
              '($_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }
      if (bufferSizePtr.value == 0 || itemCountPtr.value == 0) {
        _consecutiveTransientFailures = 0;
        return null;
      }

      final buffer = calloc<Uint8>(bufferSizePtr.value);
      try {
        final arrayStatus =
            _pdhGetFormattedCounterArray(_hCounter!, _pdhFmtDouble, bufferSizePtr, itemCountPtr, buffer);
        if (arrayStatus != 0) {
          _consecutiveTransientFailures++;
          if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
            disable('PdhGetFormattedCounterArrayW gaf status 0x${arrayStatus.toRadixString(16)} '
                '($_consecutiveTransientFailures keer op rij)');
          }
          return null;
        }

        final items = buffer.cast<_PdhCounterArrayItem>();
        double? highestCelsius;
        final rawDumpForDiagnostic = <String>[];
        for (var i = 0; i < itemCountPtr.value; i++) {
          final item = items[i];
          if (item.cStatus != 0) {
            rawDumpForDiagnostic.add('#$i: cStatus=0x${item.cStatus.toRadixString(16)} (geen geldig sample)');
            continue; // this one zone had no valid sample yet
          }
          // **Fixed 2026-09-10, confirmed against a real machine's
          // logged raw values.** This used to divide by 10 first,
          // copying the tenths-of-Kelvin convention the raw WMI
          // MSAcpi_ThermalZoneTemperature field uses — but that's the
          // *unformatted* perfcounter convention, not what
          // PdhGetFormattedCounterArrayW(..., PDH_FMT_DOUBLE, ...)
          // actually hands back for this counter. PDH applies this
          // counter's own defined scale when "cooking" the raw value,
          // and for `\Thermal Zone Information\Temperature` that
          // already yields plain Kelvin. Real evidence: a reported raw
          // value of 319.0 produced -241.2°C under the old (wrong)
          // /10 formula — implausible, correctly rejected by the
          // filter below, but silently throwing away a perfectly good
          // reading (319.0 K = 45.85°C, matching that machine's
          // actual CPU load at the time). Dividing by 10 a *second*
          // time was the bug; PDH had already done it once.
          final celsius = item.doubleValue - 273.15;
          // A single garbage zone (firmware quirk, decorative sensor
          // reporting nonsense) is skipped rather than disabling the
          // whole reader — see this class's doc for why that differs
          // from the other readers in this file.
          if (celsius.isNaN || celsius < -40 || celsius > 150) {
            rawDumpForDiagnostic.add('#$i: raw=${item.doubleValue} -> ${celsius.toStringAsFixed(1)}°C (buiten plausibel bereik)');
            continue;
          }
          if (highestCelsius == null || celsius > highestCelsius) {
            highestCelsius = celsius;
          }
        }

        if (highestCelsius == null && !_loggedAllFilteredDiagnostic && rawDumpForDiagnostic.isNotEmpty) {
          _loggedAllFilteredDiagnostic = true;
          AppLogger.instance.info(
            _logSource,
            'ACPI thermal zone-teller vond ${itemCountPtr.value} zone(s), maar geen enkele leverde een bruikbare '
            'waarde: ${rawDumpForDiagnostic.join('; ')}. Dit bericht komt niet terug.',
          );
        }

        _consecutiveTransientFailures = 0;
        return highestCelsius;
      } finally {
        calloc.free(buffer);
      }
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      calloc.free(bufferSizePtr);
      calloc.free(itemCountPtr);
    }
  }
}

/// Same approach and safety rules as [PdhCpuReader] (see its class doc
/// for the full reasoning) — two fixed, non-instanced counters read the
/// same way `\Processor(_Total)\% Processor Time` is, instead of one.
///
/// **Added 2026-09-15.** Replaces the `Win32_PerfFormattedData_PerfOS_
/// System` WMI query `WindowsSensorService._getSystemPerfData()` used
/// for thread/process counts — one of the measurably-slow
/// "*PerfFormattedData*" WMI classes (same category CPU load and disk
/// activity already moved off of), and confirmed visibly slow/timing
/// out live in this app's own log despite its 800ms cache. `\System\
/// Threads` and `\System\Processes` are the exact same underlying
/// counters that WMI class formats — this just reads them directly via
/// pdh.dll instead of paying for a PowerShell + WMI round-trip to get
/// the same two numbers.
///
/// `\System` counters are instantaneous (`PERF_COUNTER_RAWCOUNT`), not
/// rate-based, so the priming collection below isn't strictly required
/// for a meaningful first value the way it is for CPU/disk's percentage
/// counters — kept anyway purely so this reader's init shape stays
/// consistent with every other reader in this file (same reasoning
/// [PdhThermalZoneReader]'s doc gives for its own priming call).
class PdhSystemReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  int? _hCounterThreads;
  int? _hCounterProcesses;
  bool _initialized = false;

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;
  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;
  late final int Function(int query) _pdhCollectQueryData;
  late final int Function(int counter, int format, Pointer<Uint32> type, Pointer<_PdhFmtCounterValueDouble> value)
      _pdhGetFormattedCounterValue;
  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterValue = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>),
          int Function(int, int, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>)>('PdhGetFormattedCounterValue');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions (system/threads): $e\n$st');
      return false;
    }
  }

  int? _addCounter(String path) {
    final pathPtr = path.toNativeUtf16();
    final counterHandle = calloc<IntPtr>();
    try {
      final status = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
      if (status != 0) {
        AppLogger.instance.debug(_logSource, 'PdhAddEnglishCounterW("$path") returned status 0x${status.toRadixString(16)}');
        return null;
      }
      return counterHandle.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(counterHandle);
    }
  }

  bool _ensureInitialized() {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      final threadsCounter = _addCounter(r'\System\Threads');
      final processesCounter = _addCounter(r'\System\Processes');
      if (threadsCounter == null || processesCounter == null) {
        disable('Kon een of beide System-tellers niet toevoegen');
        return false;
      }
      _hCounterThreads = threadsCounter;
      _hCounterProcesses = processesCounter;

      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(
        _logSource,
        'Directe PDH-uitlezing (dart:ffi, zonder WMI) actief voor thread-/procestelling.',
      );
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing (thread-/procestelling) uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode (Win32_PerfFormattedData_PerfOS_System). Dit bericht komt niet terug.',
    );
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {}
    _hQuery = null;
    _hCounterThreads = null;
    _hCounterProcesses = null;
  }

  // Same tolerance principle as every other reader in this file (see
  // PdhCpuReader.read()'s doc for the full reasoning): a transient
  // collection hiccup is retried a few times before this reader gives
  // up for the session; an implausible value or an outright exception
  // disables it immediately.
  int _consecutiveTransientFailures = 0;
  static const _maxConsecutiveTransientFailures = 3;

  /// Returns `{'threads': ..., 'processes': ...}` as ints, or null if
  /// this path isn't usable right now — either permanently (see
  /// [disable]) or for this one call (retried on the next call). Falls
  /// back to the existing WMI-based reading either way — see
  /// [WindowsSensorService._getSystemPerfData].
  Map<String, int>? read() {
    if (!_ensureInitialized()) return null;

    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhCollectQueryData bleef een foutstatus geven (0x${collectStatus.toRadixString(16)}, '
              '$_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      final threads = _formatValue(_hCounterThreads!);
      final processes = _formatValue(_hCounterProcesses!);
      if (threads == null || processes == null) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhGetFormattedCounterValue bleef geen bruikbare waarde geven '
              '($_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      // Sanity bounds, not happy-path trust — same principle as every
      // other reader here. No real Windows system has zero threads/
      // processes (the kernel and its own idle process alone guarantee
      // a handful), and the extremely generous upper bound only exists
      // to catch a struct/memory misread, not to reject a real busy
      // system.
      if (threads.isNaN || threads < 1 || threads > 1000000 || processes.isNaN || processes < 1 || processes > 200000) {
        disable('Plausibiliteitscontrole mislukte (threads=$threads, processes=$processes)');
        return null;
      }

      _consecutiveTransientFailures = 0;
      return {'threads': threads.round(), 'processes': processes.round()};
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }

  double? _formatValue(int counter) {
    final typePtr = calloc<Uint32>();
    final valuePtr = calloc<_PdhFmtCounterValueDouble>();
    try {
      final status = _pdhGetFormattedCounterValue(counter, _pdhFmtDouble, typePtr, valuePtr);
      if (status != 0) return null;
      if (valuePtr.ref.cStatus != 0) return null;
      return valuePtr.ref.doubleValue;
    } finally {
      calloc.free(typePtr);
      calloc.free(valuePtr);
    }
  }
}

/// Same approach and safety rules as [PdhDiskReader] (see its class doc
/// for the full reasoning) — one fixed, non-instanced counter,
/// `\Paging File(_Total)\% Usage`, instead of `\PhysicalDisk(_Total)\%
/// Disk Time`.
///
/// **Added 2026-09-17.** Replaces the per-poll WMI half of
/// `WindowsSensorService._readSwapUsage()`: every single `readMemory()`
/// call — the main dashboard's ~1s poll — was still paying for a full
/// PowerShell + `Get-CimInstance Win32_PageFileUsage` round-trip just
/// for the swap figures, even though the physical-memory numbers next
/// to it had already gone native via [NativeMemoryReader]. `\Paging
/// File(_Total)\% Usage` is the exact counter Windows itself keeps for
/// this — reading it directly needs no WMI at all. The page file's
/// *total* size (needed to turn this percentage back into a KiB figure)
/// changes only when someone resizes the page file, essentially never
/// during a running session, so `WindowsSensorService` caches that part
/// from WMI far less often instead of dropping it entirely — see that
/// class's own comment on this reader for the exact caching approach.
class PdhPageFileReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _pdh;
  int? _hQuery;
  int? _hCounter;
  bool _initialized = false;

  late final int Function(Pointer<Utf16> dataSource, int userData, Pointer<IntPtr> query) _pdhOpenQuery;
  late final int Function(int query, Pointer<Utf16> counterPath, int userData, Pointer<IntPtr> counter)
      _pdhAddEnglishCounter;
  late final int Function(int query) _pdhCollectQueryData;
  late final int Function(int counter, int format, Pointer<Uint32> type, Pointer<_PdhFmtCounterValueDouble> value)
      _pdhGetFormattedCounterValue;
  late final int Function(int query) _pdhCloseQuery;

  static const _pdhFmtDouble = 0x00000200;

  bool _bindFunctions() {
    try {
      _pdh = DynamicLibrary.open('pdh.dll');
      _pdhOpenQuery = _pdh!
          .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
      _pdhAddEnglishCounter = _pdh!
          .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>),
              int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhAddEnglishCounterW');
      _pdhCollectQueryData =
          _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCollectQueryData');
      _pdhGetFormattedCounterValue = _pdh!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>),
          int Function(int, int, Pointer<Uint32>, Pointer<_PdhFmtCounterValueDouble>)>('PdhGetFormattedCounterValue');
      _pdhCloseQuery = _pdh!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
      return true;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to bind pdh.dll functions (pagefile): $e\n$st');
      return false;
    }
  }

  bool _ensureInitialized() {
    if (_initialized) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      if (!_bindFunctions()) {
        disable('pdh.dll functions could not be bound');
        return false;
      }

      final queryHandle = calloc<IntPtr>();
      try {
        final openStatus = _pdhOpenQuery(nullptr, 0, queryHandle);
        if (openStatus != 0) {
          disable('PdhOpenQuery returned status 0x${openStatus.toRadixString(16)}');
          return false;
        }
        _hQuery = queryHandle.value;
      } finally {
        calloc.free(queryHandle);
      }

      final pathPtr = r'\Paging File(_Total)\% Usage'.toNativeUtf16();
      final counterHandle = calloc<IntPtr>();
      try {
        final addStatus = _pdhAddEnglishCounter(_hQuery!, pathPtr, 0, counterHandle);
        if (addStatus != 0) {
          disable('PdhAddEnglishCounterW returned status 0x${addStatus.toRadixString(16)}');
          return false;
        }
        _hCounter = counterHandle.value;
      } finally {
        calloc.free(pathPtr);
        calloc.free(counterHandle);
      }

      // "% Usage" is an instantaneous gauge (like thermal zone
      // temperature), not a rate — priming isn't strictly required for
      // a meaningful first value, kept anyway purely for the same
      // init-shape consistency reasoning as every other reader here.
      final primeStatus = _pdhCollectQueryData(_hQuery!);
      if (primeStatus != 0) {
        disable('PdhCollectQueryData (priming) returned status 0x${primeStatus.toRadixString(16)}');
        return false;
      }

      _initialized = true;
      AppLogger.instance.info(_logSource, 'Directe PDH-uitlezing (dart:ffi, zonder WMI) actief voor swap/pagefile-gebruik.');
      return true;
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'Directe PDH-uitlezing (swap/pagefile) uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode (Win32_PageFileUsage). Dit bericht komt niet terug.',
    );
    try {
      if (_hQuery != null) _pdhCloseQuery(_hQuery!);
    } catch (_) {}
    _hQuery = null;
    _hCounter = null;
  }

  // Same tolerance principle as every other reader in this file (see
  // PdhCpuReader.read()'s doc for the full reasoning): a transient
  // collection hiccup is retried a few times before this reader gives
  // up for the session; an implausible value or an outright exception
  // disables it immediately.
  int _consecutiveTransientFailures = 0;
  static const _maxConsecutiveTransientFailures = 3;

  /// Returns the page file's current usage as a 0-100 percentage, or
  /// null if this path isn't usable right now — either permanently (see
  /// [disable]) or for this one call (retried on the next call). Falls
  /// back to the existing WMI-based reading either way — see
  /// [WindowsSensorService._readSwapUsage].
  double? read() {
    if (!_ensureInitialized()) return null;

    try {
      final collectStatus = _pdhCollectQueryData(_hQuery!);
      if (collectStatus != 0) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhCollectQueryData bleef een foutstatus geven (0x${collectStatus.toRadixString(16)}, '
              '$_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      final typePtr = calloc<Uint32>();
      final valuePtr = calloc<_PdhFmtCounterValueDouble>();
      double? value;
      try {
        final status = _pdhGetFormattedCounterValue(_hCounter!, _pdhFmtDouble, typePtr, valuePtr);
        if (status == 0 && valuePtr.ref.cStatus == 0) {
          value = valuePtr.ref.doubleValue;
        }
      } finally {
        calloc.free(typePtr);
        calloc.free(valuePtr);
      }

      if (value == null) {
        _consecutiveTransientFailures++;
        if (_consecutiveTransientFailures >= _maxConsecutiveTransientFailures) {
          disable('PdhGetFormattedCounterValue bleef geen bruikbare waarde geven '
              '($_consecutiveTransientFailures keer op rij)');
        }
        return null;
      }

      // No page file configured at all (common when the system runs
      // entirely without one) is a legitimate 0%, not an error —
      // clamped rather than treated as implausible, same reasoning
      // PdhDiskReader's own doc gives for its slightly-above-100
      // clamping.
      if (value.isNaN || value < 0) {
        disable('Plausibiliteitscontrole mislukte (value=$value)');
        return null;
      }

      _consecutiveTransientFailures = 0;
      return value.clamp(0, 100);
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    }
  }
}

/// Deliberately declared as a plain [Struct] with an explicit padding
/// field, not as a native [Union] — this app only ever needs the
/// `double` interpretation of PDH_FMT_COUNTERVALUE's union, and an
/// explicit, fully-visible byte layout (4-byte status + 4-byte pad +
/// 8-byte double = 16 bytes, matching PDH_FMT_COUNTERVALUE's
/// documented x64 layout) is easier to verify against Microsoft's
/// documentation than relying on Dart FFI's less-commonly-exercised
/// Union support for a struct this deliberately narrow.
final class _PdhFmtCounterValueDouble extends Struct {
  @Uint32()
  external int cStatus;

  @Uint32()
  external int _padding;

  @Double()
  external double doubleValue;
}

/// `PDH_FMT_COUNTERVALUE_ITEM_W` — one entry of the array
/// `PdhGetFormattedCounterArrayW` fills in: a wide-string instance
/// name pointer immediately followed by the same 16-byte
/// `PDH_FMT_COUNTERVALUE` layout as [_PdhFmtCounterValueDouble] above
/// (kept as separate inline fields here rather than a nested struct,
/// for the same "fully-visible byte layout" reasoning as that type's
/// own doc comment). 8-byte pointer + 16-byte value = 24 bytes per
/// item, which is what [PdhGpuReader.readByAdapter] indexes the raw
/// byte buffer by via `Pointer<_PdhCounterArrayItem>`.
final class _PdhCounterArrayItem extends Struct {
  external Pointer<Utf16> szName;

  @Uint32()
  external int cStatus;

  @Uint32()
  external int _padding;

  @Double()
  external double doubleValue;
}
