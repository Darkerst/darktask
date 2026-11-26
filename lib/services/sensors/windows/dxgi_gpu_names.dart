import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'DxgiGpuNames';

/// Resolves a GPU's LUID (the same per-adapter identifier embedded in
/// PDH's `\GPU Engine(*)` counter instance names — see `PdhGpuReader`'s
/// class doc in `pdh_ffi.dart`) to that adapter's friendly name, via
/// DXGI (`IDXGIFactory1::EnumAdapters1` + `IDXGIAdapter1::GetDesc1`).
/// This is what turns `PdhGpuReader.readByAdapter()`'s per-LUID load
/// numbers into "AMD: 40%, Intel: 3%" in the dashboard instead of one
/// ambiguous combined figure.
///
/// **This is the highest-risk code in the entire Windows port, by a
/// clear margin over even `PdhCpuReader`/`PdhGpuReader` and friends.**
/// Those readers make flat pdh.dll function calls with a documented
/// parameter list — a mistake there fails as a wrong status code, a
/// value this app already knows how to react to safely. This class
/// instead walks raw COM vtables (`IDXGIFactory1`'s and
/// `IDXGIAdapter1`'s method tables, by hand-verified index — 12 and 10
/// respectively) and parses `DXGI_ADAPTER_DESC1`'s fixed-size layout by
/// hand. A wrong vtable index doesn't fail with a status code — it
/// calls an arbitrary wrong method with the wrong arguments, which is
/// undefined behavior (most likely an outright process crash), not a
/// catchable Dart exception.
///
/// Why doing this by hand is defensible at all without a Windows
/// machine or compiler to test against: COM interfaces are
/// contractually frozen forever once published (that's the whole point
/// of COM's versioning model — a new method is only ever added via a
/// *new*, separately-numbered interface, never inserted into an
/// existing vtable) — `IDXGIFactory1` and `IDXGIAdapter1` have been
/// part of the public Windows SDK unchanged since DXGI 1.1 shipped in
/// Windows 7. The indices below were derived directly from that frozen
/// interface inheritance chain, not guessed:
///   - `IDXGIFactory1 : IDXGIFactory : IDXGIObject : IUnknown` — slots
///     0-2 are `IUnknown` (QueryInterface/AddRef/Release), 3-6 are
///     `IDXGIObject`, 7-11 are `IDXGIFactory`'s own five methods, so
///     `IDXGIFactory1::EnumAdapters1` (the first method it adds) is
///     slot **12**.
///   - `IDXGIAdapter1 : IDXGIAdapter : IDXGIObject : IUnknown` — same
///     0-2 and 3-6, then `IDXGIAdapter`'s three methods at 7-9, so
///     `IDXGIAdapter1::GetDesc1` (the first method it adds) is slot
///     **10**.
///
/// Exactly like `PdhCpuReader`'s own class doc says about its own,
/// lower-risk FFI: if anything about this misbehaves — very much
/// including a startup crash or hang that wasn't happening before this
/// was added — this is the first thing to suspect and revert, not
/// something to debug blind.
///
/// Runs its actual COM work at most once per app session (cached
/// after the first call — adapters don't change at runtime on any
/// system this app targets) and is deliberately structured to touch
/// COM as little as possible: one factory, one enumeration pass,
/// every COM pointer released immediately, nothing kept alive between
/// calls.
class DxgiAdapterNames {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  // Record type `(name, vramBytes)` rather than two parallel maps — one
  // enumeration pass fills in both fields for each adapter at once (see
  // _enumerateAdapters), and a record keeps that pairing explicit
  // instead of relying on two maps always having exactly the same keys.
  Map<String, (String name, int vramBytes)>? _cache;
  bool _attempted = false;

  // --- ole32.dll (COM apartment lifetime) -----------------------------
  static const _coinitApartmentThreaded = 0x2;
  static const _sOk = 0;
  static const _sFalse = 1;
  // RPC_E_CHANGED_MODE (0x80010106), as the signed 32-bit int Dart
  // FFI's Int32 return type produces. This is NOT a failure — it means
  // COM was already initialized on this thread in a different
  // concurrency mode, almost certainly by Flutter's own Windows
  // embedder for its UI message loop. COM is still perfectly usable in
  // that case; this call just didn't add a reference of its own, so it
  // must NOT be balanced with CoUninitialize (see _resolveUnsafe).
  static const _rpcEChangedMode = -2147417850;

  // --- dxgi.dll ---------------------------------------------------------
  // DXGI_ERROR_NOT_FOUND (0x887A0002) — EnumAdapters1's documented
  // "index is past the last adapter" result. Expected, not a failure:
  // it's how the enumeration loop below knows it's done.
  static const _dxgiErrorNotFound = -2005270526;

  /// Returns `{normalizedLuidKey: adapterDescription}` for every
  /// adapter DXGI reports, or `null` if this path isn't usable (the
  /// caller simply doesn't get per-adapter attribution and falls back
  /// to whatever it was already doing — see
  /// `WindowsSensorService._readGenericGpusWindows`).
  /// `normalizedLuidKey` is [_normalizeLuidKey]'s output — the same
  /// order-independent format `PdhGpuReader` uses, so the two can be
  /// joined without either side needing to know which of LUID's two
  /// 32-bit halves the other puts first.
  Map<String, String>? resolve() {
    final result = _resolveCached();
    if (result == null) return null;
    return {for (final entry in result.entries) entry.key: entry.value.$1};
  }

  /// Returns `{normalizedLuidKey: dedicatedVideoMemoryBytes}` from the
  /// same one-time DXGI enumeration [resolve] uses (see its doc for the
  /// key format).
  ///
  /// **Added 2026-09-15.** Exists specifically to correct
  /// `Win32_VideoController.AdapterRAM` — a WMI field long known to
  /// misreport VRAM on modern cards: it's a signed 32-bit value, so any
  /// GPU with 4GB or more of dedicated memory either wraps to a small
  /// number or reports outright garbage (well-documented Windows
  /// behavior, not specific to this app). DXGI's `DedicatedVideoMemory`
  /// is a full-width `SIZE_T` with no such ceiling, so
  /// `WindowsSensorService._readGenericGpusWindows` prefers this value
  /// over WMI's when a row can be matched to a DXGI adapter, falling
  /// back to the WMI figure otherwise — see that method for the
  /// matching logic. Deliberately does NOT touch `PNPDeviceID`-based
  /// filtering/matching/identity anywhere in that method: DXGI has no
  /// equivalent field, so this stays additive (a better VRAM number
  /// where available) rather than a wholesale replacement of the WMI
  /// call.
  Map<String, int>? resolveVram() {
    final result = _resolveCached();
    if (result == null) return null;
    return {for (final entry in result.entries) entry.key: entry.value.$2};
  }

  Map<String, (String name, int vramBytes)>? _resolveCached() {
    if (_attempted) return _cache;
    _attempted = true;
    if (_permanentlyDisabled) return null;
    if (!Platform.isWindows) return null;

    try {
      final result = _resolveUnsafe();
      _cache = result;
      if (result != null) {
        AppLogger.instance.info(
          _logSource,
          'DXGI-adapternamen opgehaald (${result.length}): geen COM-problemen tijdens deze eenmalige uitvraag. '
          'GPU-belasting per kaart kan nu de snelle PDH-weg gebruiken. Dit bericht komt niet terug.',
        );
      }
      return result;
    } catch (e, st) {
      disable('Unexpected exception during DXGI resolve: $e\n$st');
      return null;
    }
  }

  /// Permanently stops using this reader for the rest of the app
  /// session — never retried, same "don't debug FFI blind" principle
  /// as every other reader in this app. Every future call to [resolve]
  /// returns `null`, and callers fall back to whatever they were doing
  /// before this class existed.
  void disable(String reason) {
    _permanentlyDisabled = true;
    AppLogger.instance.info(
      _logSource,
      'DXGI-adapternaam-resolutie uitgeschakeld voor de rest van deze sessie ($reason) — '
      'GPU-belasting per kaart valt terug op de LibreHardwareMonitor/achtergronddienst-methode. '
      'Dit bericht komt niet terug.',
    );
  }

  Map<String, (String name, int vramBytes)>? _resolveUnsafe() {
    final DynamicLibrary ole32;
    final DynamicLibrary dxgi;
    try {
      ole32 = DynamicLibrary.open('ole32.dll');
      dxgi = DynamicLibrary.open('dxgi.dll');
    } catch (e, st) {
      disable('Kon ole32.dll/dxgi.dll niet laden: $e\n$st');
      return null;
    }

    final int Function(Pointer<Void>, int) coInitializeEx;
    final void Function() coUninitialize;
    final int Function(Pointer<Uint8>, Pointer<IntPtr>) createDxgiFactory1;
    try {
      coInitializeEx = ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)>('CoInitializeEx');
      coUninitialize = ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
      createDxgiFactory1 = dxgi.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<IntPtr>),
          int Function(Pointer<Uint8>, Pointer<IntPtr>)>('CreateDXGIFactory1');
    } catch (e, st) {
      disable('Kon ole32.dll/dxgi.dll functies niet binden: $e\n$st');
      return null;
    }

    final initStatus = coInitializeEx(nullptr, _coinitApartmentThreaded);
    final weOwnComInit = initStatus == _sOk || initStatus == _sFalse;
    if (!weOwnComInit && initStatus != _rpcEChangedMode) {
      disable('CoInitializeEx gaf onverwachte status 0x${initStatus.toRadixString(16)}');
      return null;
    }

    try {
      // IID_IDXGIFactory1 = {770aae78-f26f-4dba-a829-253c83d1b387} —
      // written out byte-by-byte (see _guidBytes's doc) rather than as
      // an opaque constant, so it can be hand-checked against the GUID
      // string above at a glance.
      final iidFactory1 = _guidBytes(
        data1: 0x770aae78,
        data2: 0xf26f,
        data3: 0x4dba,
        data4: [0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87],
      );
      final factoryHandle = calloc<IntPtr>();
      try {
        final createStatus = createDxgiFactory1(iidFactory1, factoryHandle);
        if (createStatus != _sOk) {
          disable('CreateDXGIFactory1 gaf status 0x${createStatus.toRadixString(16)}');
          return null;
        }
        final factory = factoryHandle.value;
        try {
          return _enumerateAdapters(factory);
        } finally {
          _release(factory);
        }
      } finally {
        calloc.free(factoryHandle);
        calloc.free(iidFactory1);
      }
    } finally {
      // Only undo the *reference this call itself added* — see
      // _rpcEChangedMode's doc for why that's not always the case.
      if (weOwnComInit) coUninitialize();
    }
  }

  Map<String, (String name, int vramBytes)>? _enumerateAdapters(int factory) {
    final results = <String, (String name, int vramBytes)>{};
    final adapterHandle = calloc<IntPtr>();
    final descPtr = calloc<_DxgiAdapterDesc1>();
    try {
      // Capped well above any real system's GPU count — a safety
      // bound against looping forever if DXGI_ERROR_NOT_FOUND is ever
      // not what actually signals "done" (see the loop body), matching
      // this app's general preference for defensive bounds over trust
      // in a single expected status code.
      for (var index = 0; index < 16; index++) {
        adapterHandle.value = 0;
        final enumStatus = _callEnumAdapters1(factory, index, adapterHandle);
        if (enumStatus == _dxgiErrorNotFound) break;
        if (enumStatus != _sOk) {
          disable('EnumAdapters1(index=$index) gaf status 0x${enumStatus.toRadixString(16)}');
          return null;
        }
        final adapter = adapterHandle.value;
        try {
          final descStatus = _callGetDesc1(adapter, descPtr);
          if (descStatus != _sOk) {
            disable('GetDesc1(index=$index) gaf status 0x${descStatus.toRadixString(16)}');
            return null;
          }
          final desc = descPtr.ref;
          final name = _readDescription(desc);
          final key = _normalizeLuidKey(desc.luidLowPart, desc.luidHighPart);
          // dedicatedVideoMemory is SIZE_T (unsigned in the real ABI);
          // Dart FFI's IntPtr surfaces it as a signed int, so a value
          // whose top bit is set (a genuinely enormous VRAM figure no
          // real GPU has) would otherwise read back negative here —
          // clamped to 0 rather than trusted, same "implausible value
          // is a memory-read bug, not a real reading" principle every
          // PDH reader in this file already applies.
          final vramBytes = desc.dedicatedVideoMemory < 0 ? 0 : desc.dedicatedVideoMemory;
          if (name.isNotEmpty && key != null) {
            results[key] = (name, vramBytes);
          }
        } finally {
          _release(adapter);
        }
      }
      return results;
    } finally {
      calloc.free(adapterHandle);
      calloc.free(descPtr);
    }
  }

  // --- Raw vtable calls --------------------------------------------------
  //
  // See the class doc for why the two indices used here (12 and 10)
  // are the single highest-risk numbers in this entire app. Kept as
  // their own tiny, single-purpose functions rather than a generic
  // "call vtable slot N" helper, so each one's exact native signature
  // is fully visible at its own call site instead of hidden behind a
  // layer of indirection.

  static int _vtableMethodAddress(int comObject, int index) {
    // The first pointer-sized value at a COM object's address is
    // always its vtable pointer — true for every COM interface by
    // definition, not something specific to DXGI.
    final vtable = Pointer<IntPtr>.fromAddress(comObject).value;
    return Pointer<IntPtr>.fromAddress(vtable + index * sizeOf<IntPtr>()).value;
  }

  /// `IDXGIFactory1::EnumAdapters1` — vtable slot 12 (see class doc).
  static int _callEnumAdapters1(int factory, int index, Pointer<IntPtr> ppAdapter) {
    final fn = Pointer<NativeFunction<Int32 Function(IntPtr, Uint32, Pointer<IntPtr>)>>.fromAddress(
      _vtableMethodAddress(factory, 12),
    ).asFunction<int Function(int, int, Pointer<IntPtr>)>();
    return fn(factory, index, ppAdapter);
  }

  /// `IDXGIAdapter1::GetDesc1` — vtable slot 10 (see class doc).
  static int _callGetDesc1(int adapter, Pointer<_DxgiAdapterDesc1> pDesc) {
    final fn = Pointer<NativeFunction<Int32 Function(IntPtr, Pointer<_DxgiAdapterDesc1>)>>.fromAddress(
      _vtableMethodAddress(adapter, 10),
    ).asFunction<int Function(int, Pointer<_DxgiAdapterDesc1>)>();
    return fn(adapter, pDesc);
  }

  /// `IUnknown::Release` — vtable slot 2, identical on every COM
  /// interface. Best-effort only: a failure here doesn't change
  /// whether the data already read out via [_callGetDesc1] above is
  /// trustworthy, it would only mean a leaked reference for the rest
  /// of the process's lifetime.
  static void _release(int comObject) {
    try {
      final fn = Pointer<NativeFunction<Uint32 Function(IntPtr)>>.fromAddress(_vtableMethodAddress(comObject, 2))
          .asFunction<int Function(int)>();
      fn(comObject);
    } catch (_) {
      // Nothing more this can safely do.
    }
  }

  static String _readDescription(_DxgiAdapterDesc1 desc) {
    final codeUnits = <int>[];
    for (var i = 0; i < 128; i++) {
      final c = desc.description[i];
      if (c == 0) break;
      codeUnits.add(c);
    }
    return String.fromCharCodes(codeUnits).trim();
  }

  /// Same order-independent normalization `PdhGpuReader._extractLuidKey`
  /// applies to the two hex numbers it parses out of a
  /// `luid_0x..._0x...` PDH instance name — both values sorted
  /// ascending and joined as decimal, so this side and that side agree
  /// regardless of which of LUID's two 32-bit halves
  /// (`LowPart`/`HighPart`) Microsoft's instance-name string happens to
  /// put first, and regardless of any hex-formatting differences
  /// between the two sources.
  static String? _normalizeLuidKey(int lowPart, int highPart) {
    final values = [lowPart & 0xFFFFFFFF, highPart & 0xFFFFFFFF]..sort();
    return '${values[0]}_${values[1]}';
  }

  /// Writes a COM `GUID`'s 16 bytes in its documented in-memory layout
  /// (`Data1`/`Data2`/`Data3` little-endian, `Data4` verbatim) into a
  /// freshly allocated native buffer — spelled out byte by byte,
  /// deliberately, rather than via any packed/union representation, so
  /// it can be checked against a GUID string like
  /// `{770aae78-f26f-4dba-a829-253c83d1b387}` at a glance: `data1`,
  /// `data2`, `data3` are that string's first three hyphen-separated
  /// groups (as hex integers), `data4` is the last two groups
  /// concatenated back into 8 raw bytes.
  static Pointer<Uint8> _guidBytes({
    required int data1,
    required int data2,
    required int data3,
    required List<int> data4,
  }) {
    assert(data4.length == 8);
    final buf = calloc<Uint8>(16);
    buf[0] = data1 & 0xFF;
    buf[1] = (data1 >> 8) & 0xFF;
    buf[2] = (data1 >> 16) & 0xFF;
    buf[3] = (data1 >> 24) & 0xFF;
    buf[4] = data2 & 0xFF;
    buf[5] = (data2 >> 8) & 0xFF;
    buf[6] = data3 & 0xFF;
    buf[7] = (data3 >> 8) & 0xFF;
    for (var i = 0; i < 8; i++) {
      buf[8 + i] = data4[i] & 0xFF;
    }
    return buf;
  }
}

/// `DXGI_ADAPTER_DESC1`, hand-laid-out field by field (see
/// [DxgiAdapterNames]'s class doc on why this specific file is held to
/// an even higher verification bar than the rest of this app's FFI
/// code). Field order and types match the documented C struct exactly;
/// Dart's FFI struct layout engine inserts the same padding a C
/// compiler would from that alone, so no field here was manually
/// positioned — the total was hand-verified separately to confirm the
/// result matches the documented native size: 256-byte name buffer +
/// 16 bytes of `UINT`s + 24 bytes of `SIZE_T`s (8-byte aligned, no gap
/// after the UINTs since 272 is already a multiple of 8) + 8-byte LUID
/// + 4-byte `Flags`, then 4 bytes of trailing padding up to the
/// struct's own 8-byte alignment — 312 bytes on x64.
final class _DxgiAdapterDesc1 extends Struct {
  @Array(128)
  external Array<Uint16> description;

  @Uint32()
  external int vendorId;

  @Uint32()
  external int deviceId;

  @Uint32()
  external int subSysId;

  @Uint32()
  external int revision;

  @IntPtr()
  external int dedicatedVideoMemory;

  @IntPtr()
  external int dedicatedSystemMemory;

  @IntPtr()
  external int sharedSystemMemory;

  // LUID, flattened into its two 32-bit halves for the same
  // fully-visible-layout reasoning as pdh_ffi.dart's structs — LowPart
  // is documented as unsigned, HighPart as signed, but only the raw
  // bits matter here (see DxgiAdapterNames._normalizeLuidKey).
  @Uint32()
  external int luidLowPart;

  @Int32()
  external int luidHighPart;

  @Uint32()
  external int flags;
}
