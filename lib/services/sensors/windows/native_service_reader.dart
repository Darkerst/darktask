import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeServiceReader';

/// Direct `dart:ffi` bindings to the Service Control Manager API
/// (`advapi32.dll`'s `OpenSCManagerW`/`EnumServicesStatusExW`/
/// `OpenServiceW`/`QueryServiceConfigW`/`QueryServiceConfig2W`) —
/// replacing `ServicesService._listServicesWindows()`'s
/// `Get-CimInstance Win32_Service` WMI query.
///
/// **Added 2026-09-17.** The old path was doubly slow: it didn't even
/// reuse this app's shared, already-running PowerShell session the way
/// `WindowsSensorService` does everywhere else — every call to the
/// Services screen spawned a brand-new `powershell.exe` process (the
/// ~200-500ms cost this app's own `PowerShellSession` doc comment
/// specifically calls out avoiding elsewhere) on top of the WMI/CIM
/// round-trip itself. This talks straight to the same Service Control
/// Manager `services.msc`/`sc.exe` use, in-process, no process spawn at
/// all.
///
/// **Risk profile:** every function here is a plain, decades-old
/// Win32 API with a fixed, documented signature — same safe category as
/// this app's other native readers (`NativeMemoryReader`,
/// `ProcessSnapshotReader`, `NativeDiskSpaceReader`), not the
/// vtable-based risk category `DxgiAdapterNames` is held to.
/// `SC_MANAGER_ENUMERATE_SERVICE`/`SERVICE_QUERY_CONFIG` are read-only
/// query rights available to any authenticated user without
/// elevation — matching what `Get-Service`/`sc query`/`sc qc` already
/// do unprivileged today; starting/stopping/reconfiguring a service
/// still goes through `ServicesService._runActionWindows()`'s existing
/// elevation flow, untouched by this class.
///
/// **`dwServiceType` filtered to `SERVICE_WIN32`** (own-process +
/// share-process services), matching `Win32_Service`'s own documented
/// scope exactly — kernel/file-system drivers are a *different* WMI
/// class (`Win32_SystemDriver`, already flagged elsewhere in this app
/// as its own separately-known-slow WMI class, untouched here) and were
/// never part of what this screen showed.
///
/// **Two-tier tolerance, matching this file's own two-tier cost:**
/// `EnumServicesStatusExW` enumerates every service's name/display
/// name/live state in a single call — if that fails, this whole reader
/// disables itself and the caller falls back to WMI entirely, same
/// all-or-nothing principle as this app's other readers. Start
/// type/description need one extra `OpenServiceW` + up to two more
/// calls *per service*, though — considerably more native calls than
/// anything else in this app, but each one is the same flat,
/// well-documented API as the rest, still far cheaper than the process
/// spawn + WMI/CIM round-trip it replaces. A single service's config
/// query failing (permission quirk, a service disappearing mid-
/// enumeration) only leaves *that one row's* start type/description as
/// "unknown"/empty — it does not disable the reader, the same
/// per-item-tolerant principle `NativeDiskSpaceReader` and
/// `PdhThermalZoneReader` already apply.
class NativeServiceReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  static const int _scManagerConnect = 0x0001;
  static const int _scManagerEnumerateService = 0x0004;
  static const int _serviceQueryConfig = 0x0001;
  static const int _scEnumProcessInfo = 0;
  static const int _serviceWin32 = 0x00000030; // OWN_PROCESS | SHARE_PROCESS
  static const int _serviceStateAll = 0x00000003;
  static const int _errorMoreData = 234;
  static const int _serviceConfigDescription = 1;

  DynamicLibrary? _advapi32;
  DynamicLibrary? _kernel32;
  late final int Function(Pointer<Utf16>, Pointer<Utf16>, int) _openScManagerW;
  late final int Function(int) _closeServiceHandle;
  late final int Function(int, int, int, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>,
      Pointer<Utf16>) _enumServicesStatusExW;
  late final int Function(int, Pointer<Utf16>, int) _openServiceW;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>) _queryServiceConfigW;
  late final int Function(int, int, Pointer<Uint8>, int, Pointer<Uint32>) _queryServiceConfig2W;
  late final int Function() _getLastError;

  bool _bound = false;

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _advapi32 = DynamicLibrary.open('advapi32.dll');
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      _openScManagerW = _advapi32!.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)>('OpenSCManagerW');
      _closeServiceHandle =
          _advapi32!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseServiceHandle');
      _enumServicesStatusExW = _advapi32!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Uint32>, Pointer<Utf16>),
          int Function(int, int, int, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Utf16>)>('EnumServicesStatusExW');
      _openServiceW = _advapi32!.lookupFunction<IntPtr Function(IntPtr, Pointer<Utf16>, Uint32),
          int Function(int, Pointer<Utf16>, int)>('OpenServiceW');
      _queryServiceConfigW = _advapi32!.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)>('QueryServiceConfigW');
      _queryServiceConfig2W = _advapi32!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Uint8>, int, Pointer<Uint32>)>('QueryServiceConfig2W');
      _getLastError = _kernel32!.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe services-uitlezing (dart:ffi Service Control Manager, zonder WMI/PowerShell) actief.',
      );
      return true;
    } catch (e, st) {
      disable('Failed to bind advapi32.dll service-management functions: $e\n$st');
      return false;
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _bound = false;
    AppLogger.instance.info(
      _logSource,
      'Directe services-uitlezing uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de WMI-methode (Win32_Service). Dit bericht komt niet terug.',
    );
  }

  /// Returns one entry per Win32 service: `{'name': ..., 'displayName':
  /// ..., 'state': 'Running', 'isRunning': true, 'startType':
  /// 'enabled'|'disabled'|'static'|'unknown', 'description': ...}`, or
  /// null if this path isn't usable at all (falls back to the existing
  /// WMI-based reading — see [ServicesService._listServicesWindows]).
  List<Map<String, Object>>? read() {
    if (!_ensureBound()) return null;

    var scManager = 0;
    try {
      scManager = _openScManagerW(nullptr, nullptr, _scManagerConnect | _scManagerEnumerateService);
      if (scManager == 0) {
        disable('OpenSCManagerW returned NULL');
        return null;
      }

      final entries = _enumerateServices(scManager);
      if (entries == null) return null;

      final results = <Map<String, Object>>[];
      for (final entry in entries) {
        final config = _queryServiceConfig(scManager, entry.name);
        results.add({
          'name': entry.name,
          'displayName': entry.displayName,
          'state': entry.stateText,
          'isRunning': entry.isRunning,
          'startType': config?.startType ?? 'unknown',
          'description': config?.description ?? '',
        });
      }
      return results;
    } catch (e, st) {
      disable('Unexpected exception during read: $e\n$st');
      return null;
    } finally {
      if (scManager != 0) {
        try {
          _closeServiceHandle(scManager);
        } catch (_) {
          // Best-effort only — the data already read out above is
          // unaffected by a failure to close this handle.
        }
      }
    }
  }

  List<({String name, String displayName, String stateText, bool isRunning})>? _enumerateServices(int scManager) {
    final bytesNeededPtr = calloc<Uint32>();
    final servicesReturnedPtr = calloc<Uint32>();
    final resumeHandlePtr = calloc<Uint32>();
    try {
      // Standard two-call Win32 enumeration pattern (same shape as
      // PdhGpuReader's PdhGetFormattedCounterArrayW usage): probe with
      // a zero-size buffer to learn how many bytes are needed, then
      // allocate exactly that and call again. Looped a handful of times
      // in case the service list grows between the probe and the real
      // call (a service being installed at that exact moment) — the
      // same defensive-bound spirit as DxgiAdapterNames' 16-adapter cap,
      // not trust in a single call being enough.
      for (var attempt = 0; attempt < 5; attempt++) {
        bytesNeededPtr.value = 0;
        servicesReturnedPtr.value = 0;
        resumeHandlePtr.value = 0;
        final probeStatus = _enumServicesStatusExW(scManager, _scEnumProcessInfo, _serviceWin32, _serviceStateAll,
            nullptr, 0, bytesNeededPtr, servicesReturnedPtr, resumeHandlePtr, nullptr);
        // A zero-size probe call always "fails" by design — either
        // ERROR_MORE_DATA or ERROR_INSUFFICIENT_BUFFER, both meaning
        // "here's how big the real buffer needs to be", not a genuine
        // error. Anything else (probeStatus != 0, i.e. it somehow
        // *succeeded* with zero services, or some other error) is
        // treated as a real failure below.
        final neededBytes = bytesNeededPtr.value;
        if (probeStatus != 0 && neededBytes == 0) {
          // Genuinely zero services (or an unexpected success) —
          // not an error, just nothing to enumerate.
          return const [];
        }
        if (neededBytes == 0) {
          disable('EnumServicesStatusExW (probe) reported 0 bytes needed but did not succeed');
          return null;
        }

        final buffer = calloc<Uint8>(neededBytes);
        try {
          bytesNeededPtr.value = 0;
          servicesReturnedPtr.value = 0;
          final callStatus = _enumServicesStatusExW(scManager, _scEnumProcessInfo, _serviceWin32, _serviceStateAll,
              buffer, neededBytes, bytesNeededPtr, servicesReturnedPtr, resumeHandlePtr, nullptr);
          if (callStatus == 0) {
            // Real call still short — only ERROR_MORE_DATA is worth
            // retrying (the list grew since the probe); anything else
            // is a genuine failure.
            final lastError = _getLastError();
            if (lastError == _errorMoreData && attempt < 4) continue;
            disable('EnumServicesStatusExW failed (GetLastError=$lastError)');
            return null;
          }

          final count = servicesReturnedPtr.value;
          final entries = buffer.cast<_EnumServiceStatusProcessW>();
          final results = <({String name, String displayName, String stateText, bool isRunning})>[];
          for (var i = 0; i < count; i++) {
            final entry = entries[i];
            final name = entry.lpServiceName == nullptr ? '' : entry.lpServiceName.toDartString();
            if (name.isEmpty) continue;
            final displayName = entry.lpDisplayName == nullptr ? name : entry.lpDisplayName.toDartString();
            final currentState = entry.dwCurrentState;
            results.add((
              name: name,
              displayName: displayName,
              stateText: _stateText(currentState),
              isRunning: currentState == 4, // SERVICE_RUNNING
            ));
          }
          return results;
        } finally {
          calloc.free(buffer);
        }
      }

      disable('EnumServicesStatusExW kept reporting ERROR_MORE_DATA across every retry');
      return null;
    } finally {
      calloc.free(bytesNeededPtr);
      calloc.free(servicesReturnedPtr);
      calloc.free(resumeHandlePtr);
    }
  }

  /// Windows Service Control Manager state strings, matching exactly
  /// what `Win32_Service.State` (and this file's WMI fallback) already
  /// produce — so `ServicesService`'s downstream mapping onto the
  /// systemd-style active/inactive vocabulary keeps working unchanged
  /// regardless of which path produced the row.
  static String _stateText(int dwCurrentState) => switch (dwCurrentState) {
        1 => 'Stopped',
        2 => 'Start Pending',
        3 => 'Stop Pending',
        4 => 'Running',
        5 => 'Continue Pending',
        6 => 'Pause Pending',
        7 => 'Paused',
        _ => 'Unknown',
      };

  ({String startType, String description})? _queryServiceConfig(int scManager, String serviceName) {
    var service = 0;
    final namePtr = serviceName.toNativeUtf16();
    try {
      service = _openServiceW(scManager, namePtr, _serviceQueryConfig);
      if (service == 0) return null;

      final startType = _queryStartType(service);
      final description = _queryDescription(service);
      if (startType == null && description == null) return null;
      return (startType: startType ?? 'unknown', description: description ?? '');
    } catch (e) {
      // Deliberately not calling disable() here — see this class's doc
      // on why a single service's config query failing only affects
      // that one row, not the whole reader.
      AppLogger.instance.debug(_logSource, 'Config query failed for service "$serviceName": $e');
      return null;
    } finally {
      calloc.free(namePtr);
      if (service != 0) {
        try {
          _closeServiceHandle(service);
        } catch (_) {}
      }
    }
  }

  String? _queryStartType(int service) {
    final bytesNeededPtr = calloc<Uint32>();
    try {
      bytesNeededPtr.value = 0;
      _queryServiceConfigW(service, nullptr, 0, bytesNeededPtr);
      final neededBytes = bytesNeededPtr.value;
      if (neededBytes == 0) return null;

      final buffer = calloc<Uint8>(neededBytes);
      try {
        bytesNeededPtr.value = 0;
        final ok = _queryServiceConfigW(service, buffer, neededBytes, bytesNeededPtr);
        if (ok == 0) return null;
        final config = buffer.cast<_QueryServiceConfigW>().ref;
        return switch (config.dwStartType) {
          0 || 1 || 2 => 'enabled', // BOOT_START / SYSTEM_START / AUTO_START
          3 => 'static', // DEMAND_START (Manual)
          4 => 'disabled',
          _ => 'unknown',
        };
      } finally {
        calloc.free(buffer);
      }
    } catch (_) {
      return null;
    } finally {
      calloc.free(bytesNeededPtr);
    }
  }

  String? _queryDescription(int service) {
    final bytesNeededPtr = calloc<Uint32>();
    try {
      bytesNeededPtr.value = 0;
      _queryServiceConfig2W(service, _serviceConfigDescription, nullptr, 0, bytesNeededPtr);
      final neededBytes = bytesNeededPtr.value;
      if (neededBytes == 0) return null;

      final buffer = calloc<Uint8>(neededBytes);
      try {
        bytesNeededPtr.value = 0;
        final ok = _queryServiceConfig2W(service, _serviceConfigDescription, buffer, neededBytes, bytesNeededPtr);
        if (ok == 0) return null;
        final descPtr = buffer.cast<_ServiceDescriptionW>().ref.lpDescription;
        // A service with no description at all is normal (not every
        // service sets one) — an empty string, not a failure.
        return descPtr == nullptr ? '' : descPtr.toDartString();
      } finally {
        calloc.free(buffer);
      }
    } catch (_) {
      return null;
    } finally {
      calloc.free(bytesNeededPtr);
    }
  }

}

/// `SERVICE_STATUS_PROCESS`, embedded inline (not as a nested struct
/// field) inside [_EnumServiceStatusProcessW] below, matching the real
/// C layout exactly — see that struct's doc.
///
/// Two leading pointers (`lpServiceName`/`lpDisplayName`, 16 bytes) then
/// nine `DWORD`s (36 bytes) = 52 bytes unaligned, padded to 56 bytes for
/// the struct's own 8-byte alignment (driven by the two leading
/// pointers) — Dart FFI's [Struct] layout engine computes this
/// automatically from the field types/order below, the same trust this
/// app already places in it for `_MemoryStatusEx` and
/// `_DxgiAdapterDesc1`.
final class _EnumServiceStatusProcessW extends Struct {
  external Pointer<Utf16> lpServiceName;
  external Pointer<Utf16> lpDisplayName;

  @Uint32()
  external int dwServiceType;
  @Uint32()
  external int dwCurrentState;
  @Uint32()
  external int dwControlsAccepted;
  @Uint32()
  external int dwWin32ExitCode;
  @Uint32()
  external int dwServiceSpecificExitCode;
  @Uint32()
  external int dwCheckPoint;
  @Uint32()
  external int dwWaitHint;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwServiceFlags;
}

/// `QUERY_SERVICE_CONFIGW` — only `dwStartType` is read by this file,
/// but every field is declared in its documented order so Dart FFI's
/// layout engine places `dwStartType` (and the padding before the first
/// pointer field) exactly where the real API writes it.
final class _QueryServiceConfigW extends Struct {
  @Uint32()
  external int dwServiceType;
  @Uint32()
  external int dwStartType;
  @Uint32()
  external int dwErrorControl;
  external Pointer<Utf16> lpBinaryPathName;
  external Pointer<Utf16> lpLoadOrderGroup;
  @Uint32()
  external int dwTagId;
  external Pointer<Utf16> lpDependencies;
  external Pointer<Utf16> lpServiceStartName;
  external Pointer<Utf16> lpDisplayName;
}

/// `SERVICE_DESCRIPTIONW` — a single pointer field, used with
/// `QueryServiceConfig2W(..., SERVICE_CONFIG_DESCRIPTION, ...)`.
final class _ServiceDescriptionW extends Struct {
  external Pointer<Utf16> lpDescription;
}
