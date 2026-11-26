import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'BatteryIoctlReader';

/// Direct battery hardware queries via `IOCTL_BATTERY_QUERY_INFORMATION`,
/// following Microsoft's own official example code for enumerating and
/// querying battery devices (learn.microsoft.com/.../power/enumerating-
/// battery-devices — the full C++ reference this class mirrors field for
/// field). This talks directly to the battery's miniclass driver via its
/// SetupAPI device interface path, bypassing the `root\wmi`
/// `BatteryStaticData`/`BatteryFullChargedCapacity` classes entirely — the
/// classes with a confirmed, documented firmware bug on some laptop models
/// (multiple HP ProBook variants reported and confirmed in HP's own support
/// forum) where both return the *same* value, making the health ratio
/// always compute to exactly 100% regardless of the battery's real
/// condition. This is a different code path end to end, not a different
/// interpretation of the same buggy data.
///
/// **Risk profile:** every struct here (`SP_DEVICE_INTERFACE_DATA`,
/// `BATTERY_QUERY_INFORMATION`, `BATTERY_INFORMATION`) is a plain, documented
/// fixed-layout struct — no vtables — matching this app's established bar
/// for what's safe to hand-roll via FFI (see NvmeHealthReader's doc for the
/// full reasoning on why that bar excludes D3D11-style COM interfaces but
/// includes this).
class BatteryIoctlReader {
  static const int _fileShareRead = 0x00000001;
  static const int _fileShareWrite = 0x00000002;
  static const int _genericRead = 0x80000000;
  static const int _genericWrite = 0x40000000;
  static const int _openExisting = 3;
  static const int _invalidHandleValue = -1;

  static const int _digcfPresent = 0x00000002;
  static const int _digcfDeviceInterface = 0x00000010;
  static const int _errorInsufficientBuffer = 122;
  static const int _errorNoMoreItems = 259;

  // CTL_CODE(FILE_DEVICE_BATTERY=0x29, function, METHOD_BUFFERED=0,
  // FILE_ANY_ACCESS=0) = (0x29 << 16) | (function << 2). Functions 0x10
  // (QUERY_TAG) and 0x11 (QUERY_INFORMATION) per Poclass.h/BatClass.h —
  // these two specific values are what Microsoft's own example code and
  // the Windows Driver Kit headers define them as.
  static const int _ioctlBatteryQueryTag = 0x00294040;
  static const int _ioctlBatteryQueryInformation = 0x00294044;
  // IOCTL_BATTERY_QUERY_STATUS = function 0x13, zelfde device type/access/
  // method als de twee hierboven: 0x00294000 | (0x13 << 2) = 0x0029404C.
  static const int _ioctlBatteryQueryStatus = 0x0029404C;

  static const int _batteryInformationLevel = 0; // BATTERY_QUERY_INFORMATION_LEVEL.BatteryInformation

  // GUID_DEVCLASS_BATTERY = {72631E54-78A4-11D0-BCF7-00AA00B7B32A} — a
  // stable Windows Driver Kit constant, unchanged since NT battery class
  // support was introduced and not something that varies by Windows
  // version.
  static final Uint8List _batteryClassGuidBytes = Uint8List.fromList([
    0x54, 0x1E, 0x63, 0x72, // Data1 (little-endian)
    0xA4, 0x78, // Data2 (little-endian)
    0xD0, 0x11, // Data3 (little-endian)
    0xBC, 0xF7, 0x00, 0xAA, 0x00, 0xB7, 0xB3, 0x2A, // Data4 (raw bytes)
  ]);

  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  late final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFileW;
  late final int Function(int) _closeHandle;
  late final int Function(int, int, Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      _deviceIoControl;
  late final int Function(Pointer<Uint8> classGuid, Pointer<Utf16> enumerator, int hwndParent, int flags)
      _setupDiGetClassDevsW;
  late final int Function(int deviceInfoSet, int memberIndex, Pointer<Uint8> classGuid, int deviceIndex,
      Pointer<Uint8> deviceInterfaceData) _setupDiEnumDeviceInterfaces;
  late final int Function(int deviceInfoSet, Pointer<Uint8> deviceInterfaceData,
      Pointer<Uint8> deviceInterfaceDetailData, int deviceInterfaceDetailDataSize,
      Pointer<Uint32> requiredSize, Pointer<Void> deviceInfoData) _setupDiGetDeviceInterfaceDetailW;
  late final int Function(int) _setupDiDestroyDeviceInfoList;

  bool _bound = false;
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

      final setupapi = DynamicLibrary.open('setupapi.dll');
      _setupDiGetClassDevsW = setupapi.lookupFunction<
          IntPtr Function(Pointer<Uint8>, Pointer<Utf16>, IntPtr, Uint32),
          int Function(Pointer<Uint8>, Pointer<Utf16>, int, int)>('SetupDiGetClassDevsW');
      _setupDiEnumDeviceInterfaces = setupapi.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint8>),
          int Function(int, int, Pointer<Uint8>, int, Pointer<Uint8>)>('SetupDiEnumDeviceInterfaces');
      _setupDiGetDeviceInterfaceDetailW = setupapi.lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
          int Function(int, Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint32>,
              Pointer<Void>)>('SetupDiGetDeviceInterfaceDetailW');
      _setupDiDestroyDeviceInfoList = setupapi
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetupDiDestroyDeviceInfoList');

      _bound = true;
      return true;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to bind kernel32/setupapi functions: $e\n$st');
      _permanentlyDisabled = true;
      return false;
    }
  }

  /// Reads design capacity, full-charge capacity, and cycle count directly
  /// from the first system battery's miniclass driver. Returns null on any
  /// failure — no battery device found, IOCTL unsupported, or a value
  /// this class can't make sense of — in which case
  /// WindowsSensorService's existing `root\wmi`-based path is used
  /// instead, exactly as if this class didn't exist.
  ({int designCapacityMWh, int fullChargeCapacityMWh, int? cycleCount})? readBatteryInformation() =>
      _withBatteryHandle(_queryBatteryInfo);

  /// Leest de actuele batterijstatus (resterende energie in mWh en het
  /// gemelde verbruik in mW) via `IOCTL_BATTERY_QUERY_STATUS`. Zelfde
  /// apparaatpad en veiligheidsprofiel als [readBatteryInformation]; geeft
  /// null bij elke fout, waarna de aanroeper op procenten terugvalt.
  ///
  /// `rateMW` is negatief tijdens ontladen en positief tijdens laden
  /// (Microsoft-documentatie van BATTERY_STATUS.Rate); null als de batterij
  /// BATTERY_UNKNOWN_RATE (0x80000000) meldt. `powerState` bevat de bits
  /// ONLINE=1, DISCHARGING=2, CHARGING=4, CRITICAL=8.
  ({int capacityMWh, int? rateMW, int powerState})? readBatteryStatus() => _withBatteryHandle(_queryBatteryStatus);

  T? _withBatteryHandle<T>(T? Function(int handle) query) {
    if (_permanentlyDisabled) return null;
    if (!Platform.isWindows) return null;
    if (!_bindFunctions()) return null;

    int deviceInfoSet = _invalidHandleValue;
    final classGuidPtr = calloc<Uint8>(16);

    try {
      classGuidPtr.asTypedList(16).setAll(0, _batteryClassGuidBytes);

      deviceInfoSet = _setupDiGetClassDevsW(classGuidPtr, nullptr, 0, _digcfPresent | _digcfDeviceInterface);
      if (deviceInfoSet == _invalidHandleValue) {
        AppLogger.instance.debug(_logSource, 'SetupDiGetClassDevsW failed to find any battery device class.');
        return null;
      }

      // SP_DEVICE_INTERFACE_DATA: DWORD cbSize; GUID InterfaceClassGuid;
      // DWORD Flags; ULONG_PTR Reserved; — 32 bytes on 64-bit (4 + 16 + 4
      // padded to 8-byte alignment + 8).
      final deviceInterfaceData = calloc<Uint8>(32);
      final requiredSize = calloc<Uint32>();

      try {
        // Only the first battery device is queried — laptops with a
        // second, swappable/secondary battery are rare enough, and this
        // app already reports only one battery's data throughout, that
        // handling more than one here would add real complexity for a
        // case this app doesn't otherwise support.
        deviceInterfaceData.asTypedList(32).fillRange(0, 32, 0);
        deviceInterfaceData.cast<Uint32>()[0] = 32; // cbSize

        final found = _setupDiEnumDeviceInterfaces(deviceInfoSet, 0, classGuidPtr, 0, deviceInterfaceData);
        if (found == 0) {
          AppLogger.instance.debug(_logSource, 'SetupDiEnumDeviceInterfaces found no battery device (index 0).');
          return null;
        }

        // First call with a null/zero-size detail buffer to learn the
        // required size — this is the documented, standard two-call
        // pattern for this API, not a workaround.
        _setupDiGetDeviceInterfaceDetailW(deviceInfoSet, deviceInterfaceData, nullptr, 0, requiredSize, nullptr);
        if (requiredSize.value == 0) {
          AppLogger.instance.debug(_logSource, 'SetupDiGetDeviceInterfaceDetailW size probe returned 0.');
          return null;
        }

        final detailBuffer = calloc<Uint8>(requiredSize.value);
        try {
          // SP_DEVICE_INTERFACE_DETAIL_DATA_W.cbSize must be set to
          // sizeof(DWORD) + sizeof(WCHAR) — a well-known, widely
          // documented quirk of this specific struct: the *buffer* can
          // (and here, does) hold far more than one WCHAR of path data,
          // but cbSize itself is always this fixed value regardless of
          // buffer size. 8 is the correct value for 64-bit (this app
          // only targets x64 Windows builds).
          detailBuffer.cast<Uint32>()[0] = 8;

          final gotDetail = _setupDiGetDeviceInterfaceDetailW(
            deviceInfoSet,
            deviceInterfaceData,
            detailBuffer,
            requiredSize.value,
            nullptr,
            nullptr,
          );
          if (gotDetail == 0) {
            AppLogger.instance.debug(_logSource, 'SetupDiGetDeviceInterfaceDetailW failed on the real call.');
            return null;
          }

          // DevicePath is the null-terminated WCHAR string starting
          // right after the 4-byte cbSize field.
          final devicePathPtr = detailBuffer.elementAt(4).cast<Utf16>();

          int handle = _invalidHandleValue;
          try {
            handle = _createFileW(
              devicePathPtr,
              _genericRead | _genericWrite,
              _fileShareRead | _fileShareWrite,
              nullptr,
              _openExisting,
              0,
              0,
            );
            if (handle == _invalidHandleValue) {
              AppLogger.instance.debug(_logSource, 'CreateFileW failed for the battery device path.');
              return null;
            }

            return query(handle);
          } finally {
            if (handle != _invalidHandleValue) _closeHandle(handle);
          }
        } finally {
          calloc.free(detailBuffer);
        }
      } finally {
        calloc.free(deviceInterfaceData);
        calloc.free(requiredSize);
      }
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Unexpected exception: $e\n$st');
      return null;
    } finally {
      if (deviceInfoSet != _invalidHandleValue) _setupDiDestroyDeviceInfoList(deviceInfoSet);
      calloc.free(classGuidPtr);
    }
  }

  ({int capacityMWh, int? rateMW, int powerState})? _queryBatteryStatus(int handle) {
    final waitTimeout = calloc<Uint32>();
    final tag = calloc<Uint32>();
    final bytesReturned = calloc<Uint32>();
    try {
      waitTimeout.value = 0;
      final gotTag = _deviceIoControl(
        handle,
        _ioctlBatteryQueryTag,
        waitTimeout.cast<Void>(),
        4,
        tag.cast<Void>(),
        4,
        bytesReturned,
        nullptr,
      );
      if (gotTag == 0 || tag.value == 0) {
        AppLogger.instance.debug(_logSource, 'IOCTL_BATTERY_QUERY_TAG (status) failed or returned tag 0.');
        return null;
      }

      // Input: BATTERY_WAIT_STATUS { ULONG BatteryTag; ULONG Timeout;
      // ULONG PowerState; ULONG LowCapacity; ULONG HighCapacity; } = 20
      // bytes. Alleen de tag wordt gezet; Timeout 0 betekent "niet wachten,
      // geef de huidige status" (zoals in Microsofts eigen voorbeeldcode).
      // Output: BATTERY_STATUS { ULONG PowerState; ULONG Capacity; ULONG
      // Voltage; LONG Rate; } = 16 bytes.
      final statusInput = calloc<Uint8>(20);
      final statusOutput = calloc<Uint8>(16);
      try {
        final inData = statusInput.asTypedList(20).buffer.asByteData();
        inData.setUint32(0, tag.value, Endian.little);

        final gotStatus = _deviceIoControl(
          handle,
          _ioctlBatteryQueryStatus,
          statusInput.cast<Void>(),
          20,
          statusOutput.cast<Void>(),
          16,
          bytesReturned,
          nullptr,
        );
        if (gotStatus == 0) {
          AppLogger.instance.debug(_logSource, 'IOCTL_BATTERY_QUERY_STATUS failed.');
          return null;
        }

        final outData = statusOutput.asTypedList(16).buffer.asByteData();
        final powerState = outData.getUint32(0, Endian.little);
        final capacity = outData.getUint32(4, Endian.little);
        final rate = outData.getInt32(12, Endian.little);

        // BATTERY_UNKNOWN_CAPACITY = 0xFFFFFFFF, BATTERY_UNKNOWN_RATE =
        // 0x80000000 (als signed: -2147483648): gedocumenteerde
        // "weet ik niet"-waarden, geen echte metingen.
        if (capacity == 0xFFFFFFFF) return null;
        return (
          capacityMWh: capacity,
          rateMW: rate == -2147483648 ? null : rate,
          powerState: powerState,
        );
      } finally {
        calloc.free(statusInput);
        calloc.free(statusOutput);
      }
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Unexpected exception during battery status query: $e\n$st');
      return null;
    } finally {
      calloc.free(waitTimeout);
      calloc.free(tag);
      calloc.free(bytesReturned);
    }
  }

  ({int designCapacityMWh, int fullChargeCapacityMWh, int? cycleCount})? _queryBatteryInfo(int handle) {
    // Step 1: IOCTL_BATTERY_QUERY_TAG — input is a single DWORD (a wait
    // timeout, 0 = don't wait), output is the battery's current tag. This
    // tag must be included in every subsequent query so the driver can
    // detect the battery being swapped mid-request.
    final waitTimeout = calloc<Uint32>();
    final tag = calloc<Uint32>();
    final bytesReturned = calloc<Uint32>();
    try {
      waitTimeout.value = 0;
      final gotTag = _deviceIoControl(
        handle,
        _ioctlBatteryQueryTag,
        waitTimeout.cast<Void>(),
        4,
        tag.cast<Void>(),
        4,
        bytesReturned,
        nullptr,
      );
      if (gotTag == 0 || tag.value == 0) {
        AppLogger.instance.debug(_logSource, 'IOCTL_BATTERY_QUERY_TAG failed or returned tag 0.');
        return null;
      }

      // Step 2: IOCTL_BATTERY_QUERY_INFORMATION with InformationLevel =
      // BatteryInformation. Input: BATTERY_QUERY_INFORMATION { ULONG
      // BatteryTag; ULONG InformationLevel; LONG AtRate; } = 12 bytes.
      // Output: BATTERY_INFORMATION — Capabilities(4) + Technology(1) +
      // Reserved[3](3) + Chemistry[4](4) + DesignedCapacity(4) +
      // FullChargedCapacity(4) + DefaultAlert1(4) + DefaultAlert2(4) +
      // CriticalBias(4) + CycleCount(4) = 36 bytes.
      final queryInput = calloc<Uint8>(12);
      final infoOutput = calloc<Uint8>(36);
      try {
        final queryData = queryInput.asTypedList(12).buffer.asByteData();
        queryData.setUint32(0, tag.value, Endian.little); // BatteryTag
        queryData.setUint32(4, _batteryInformationLevel, Endian.little); // InformationLevel
        queryData.setInt32(8, 0, Endian.little); // AtRate (unused for this level)

        final gotInfo = _deviceIoControl(
          handle,
          _ioctlBatteryQueryInformation,
          queryInput.cast<Void>(),
          12,
          infoOutput.cast<Void>(),
          36,
          bytesReturned,
          nullptr,
        );
        if (gotInfo == 0) {
          AppLogger.instance.debug(_logSource, 'IOCTL_BATTERY_QUERY_INFORMATION failed.');
          return null;
        }

        final infoData = infoOutput.asTypedList(36).buffer.asByteData();
        // BATTERY_INFORMATION layout: Capabilities(0,4) + Technology(4,1)
        // + Reserved[3](5,3) + Chemistry[4](8,4) + DesignedCapacity(12,4)
        // + FullChargedCapacity(16,4) + DefaultAlert1(20,4) +
        // DefaultAlert2(24,4) + CriticalBias(28,4) + CycleCount(32,4).
        final designedCapacity = infoData.getUint32(12, Endian.little);
        final fullChargedCapacity = infoData.getUint32(16, Endian.little);
        final cycleCount = infoData.getUint32(32, Endian.little);

        // BATTERY_UNKNOWN_CAPACITY is 0xFFFFFFFF — a documented sentinel
        // meaning "this battery doesn't report this value," not a real
        // 4-billion-mWh capacity. Treated as null/absent, not shown as a
        // real (nonsensical) number.
        if (designedCapacity == 0xFFFFFFFF || fullChargedCapacity == 0xFFFFFFFF || designedCapacity == 0) {
          AppLogger.instance.debug(_logSource, 'Battery reports unknown/unavailable capacity values.');
          return null;
        }

        return (
          designCapacityMWh: designedCapacity,
          fullChargeCapacityMWh: fullChargedCapacity,
          cycleCount: (cycleCount != 0xFFFFFFFF && cycleCount > 0) ? cycleCount : null,
        );
      } finally {
        calloc.free(queryInput);
        calloc.free(infoOutput);
      }
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Unexpected exception during battery query: $e\n$st');
      return null;
    } finally {
      calloc.free(waitTimeout);
      calloc.free(tag);
      calloc.free(bytesReturned);
    }
  }
}
