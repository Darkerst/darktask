import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NvmeHealthReader';

/// Direct NVMe SMART/health log queries via `IOCTL_STORAGE_QUERY_PROPERTY`
/// — the same underlying mechanism CrystalDiskInfo and similar tools use,
/// bypassing `Get-StorageReliabilityCounter`'s well-documented unreliability
/// on many drives (see WindowsSensorService.readDiskHealth's own doc for
/// the specific, confirmed real-world evidence that motivated this class:
/// `Wear` there frequently reports a literal `0` as a placeholder default
/// rather than a genuine measurement, on hardware where the storage driver
/// simply doesn't track it through that abstraction layer).
///
/// **Why this is a fundamentally different risk category than the D3D11
/// GPU-compute route this app deliberately avoided elsewhere:** D3D11's
/// COM interfaces require calling through a vtable — every method ahead of
/// the one actually wanted has to be correctly declared just to land on
/// the right byte offset, and a wrong offset calls an arbitrary, wrong
/// function through a graphics driver (a genuinely dangerous, unpredictable
/// failure mode). Everything here is different: `DeviceIoControl` is one
/// plain, stable Win32 function with a fixed, well-known signature (not a
/// vtable), and the request/response formats
/// (`STORAGE_PROPERTY_QUERY`, `STORAGE_PROTOCOL_SPECIFIC_DATA`,
/// `STORAGE_PROTOCOL_DATA_DESCRIPTOR`, `NVME_HEALTH_INFO_LOG`) are all
/// plain, fixed-layout structs with field-by-field documentation from
/// Microsoft's own current API reference (learn.microsoft.com/.../
/// ns-winioctl-storage_protocol_specific_data and .../ns-nvme-
/// nvme_health_info_log) — not something reverse-engineered. A wrong
/// field here fails the IOCTL cleanly (an error return this class checks
/// for) rather than crashing a driver, since the Windows storage stack
/// validates the request before it ever reaches a miniport driver.
///
/// **Scope: NVMe only, deliberately.** NVMe standardizes `PercentageUsed`
/// (SMART/Health Information Log, Log Identifier 02h) as a single 0-100
/// figure with one clear meaning across every vendor — this class trusts
/// it. SATA/ATA SSDs have no equivalent standard: the relevant SMART
/// attribute ID and what its raw value means both vary by manufacturer
/// enough that even with raw access, interpreting it would mean guessing —
/// the same reasoning `DiskSensorMixin`'s Linux smartctl path already
/// applies. This class is not extended to ATA for that reason, not because
/// the IOCTL mechanism itself couldn't reach it.
class NvmeHealthReader {
  static const int _fileShareRead = 0x00000001;
  static const int _fileShareWrite = 0x00000002;
  static const int _genericRead = 0x80000000;
  static const int _genericWrite = 0x40000000;
  static const int _openExisting = 3;
  static const int _invalidHandleValue = -1;

  // CTL_CODE(FILE_DEVICE_MASS_STORAGE=0x2d, 0x500, METHOD_BUFFERED=0,
  // FILE_ANY_ACCESS=0) = (0x2d << 16) | (0x500 << 2) — the standard,
  // widely-referenced constant for this IOCTL across Windows storage
  // tooling.
  static const int _ioctlStorageQueryProperty = 0x2D1400;

  static const int _storageDeviceProtocolSpecificProperty = 50;
  static const int _propertyStandardQuery = 0;
  static const int _protocolTypeNvme = 3;
  static const int _nvmeDataTypeLogPage = 2;
  static const int _nvmeSmartHealthLogPageId = 0x02;

  // sizeof(STORAGE_PROTOCOL_SPECIFIC_DATA): 10 DWORD fields.
  static const int _protocolSpecificDataSize = 40;
  // sizeof(NVME_HEALTH_INFO_LOG) per Microsoft's documented layout.
  static const int _healthLogSize = 512;
  // STORAGE_PROPERTY_QUERY header (PropertyId + QueryType) = 8 bytes,
  // immediately followed by STORAGE_PROTOCOL_SPECIFIC_DATA as its
  // AdditionalParameters — this is the *input* size needed.
  static const int _inputSize = 8 + _protocolSpecificDataSize;
  // STORAGE_PROTOCOL_DATA_DESCRIPTOR header (Version + Size) = 8 bytes,
  // then STORAGE_PROTOCOL_SPECIFIC_DATA (echoed back), then the actual
  // log page payload — this is the *output* size to allocate, reusing
  // the same buffer for both (standard METHOD_BUFFERED pattern).
  static const int _outputSize = 8 + _protocolSpecificDataSize + _healthLogSize;

  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  late final int Function(Pointer<Utf16> lpFileName, int dwDesiredAccess, int dwShareMode,
      Pointer<Void> lpSecurityAttributes, int dwCreationDisposition, int dwFlagsAndAttributes,
      int hTemplateFile) _createFileW;
  late final int Function(int hObject) _closeHandle;
  late final int Function(int hDevice, int dwIoControlCode, Pointer<Void> lpInBuffer, int nInBufferSize,
      Pointer<Void> lpOutBuffer, int nOutBufferSize, Pointer<Uint32> lpBytesReturned,
      Pointer<Void> lpOverlapped) _deviceIoControl;

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
      _bound = true;
      return true;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to bind kernel32 functions: $e\n$st');
      _permanentlyDisabled = true;
      return false;
    }
  }

  /// Reads NVMe SMART/health data for `\\.\PhysicalDriveN`. Returns null
  /// on absolutely any failure (not an NVMe drive, IOCTL not supported,
  /// access denied, malformed response) — every failure here falls
  /// through to the existing Get-StorageReliabilityCounter path in
  /// WindowsSensorService, never surfaced as an error to the person using
  /// the app.
  ({double percentageUsed, int powerOnHours})? readHealth(int physicalDriveIndex) {
    if (_permanentlyDisabled) return null;
    if (!Platform.isWindows) return null;
    if (!_bindFunctions()) return null;

    final path = '\\\\.\\PhysicalDrive$physicalDriveIndex';
    final pathPtr = path.toNativeUtf16();
    int handle = _invalidHandleValue;

    try {
      handle = _createFileW(
        pathPtr,
        _genericRead | _genericWrite,
        _fileShareRead | _fileShareWrite,
        nullptr,
        _openExisting,
        0,
        0,
      );
      if (handle == _invalidHandleValue) {
        AppLogger.instance.info(_logSource, 'CreateFileW failed for $path (foutcode via GetLastError niet beschikbaar in dit logpunt).');
        return null;
      }

      final buffer = calloc<Uint8>(_outputSize);
      final bytesReturned = calloc<Uint32>();
      try {
        final byteData = buffer.asTypedList(_outputSize).buffer.asByteData();
        // --- Build the input: STORAGE_PROPERTY_QUERY header ---
        byteData.setUint32(0, _storageDeviceProtocolSpecificProperty, Endian.little); // PropertyId
        byteData.setUint32(4, _propertyStandardQuery, Endian.little); // QueryType
        // --- STORAGE_PROTOCOL_SPECIFIC_DATA, starting at offset 8 ---
        byteData.setUint32(8, _protocolTypeNvme, Endian.little); // ProtocolType
        byteData.setUint32(12, _nvmeDataTypeLogPage, Endian.little); // DataType
        byteData.setUint32(16, _nvmeSmartHealthLogPageId, Endian.little); // ProtocolDataRequestValue (log page ID)
        byteData.setUint32(20, 0, Endian.little); // ProtocolDataRequestSubValue
        // ProtocolDataOffset: where the returned log page starts,
        // measured from the start of ProtocolSpecificData — right after
        // this 40-byte struct itself.
        byteData.setUint32(24, _protocolSpecificDataSize, Endian.little);
        byteData.setUint32(28, _healthLogSize, Endian.little); // ProtocolDataLength
        // Remaining STORAGE_PROTOCOL_SPECIFIC_DATA fields (offsets 32-47)
        // already zeroed by calloc.

        final ok = _deviceIoControl(
          handle,
          _ioctlStorageQueryProperty,
          buffer.cast<Void>(),
          _inputSize,
          buffer.cast<Void>(),
          _outputSize,
          bytesReturned,
          nullptr,
        );
        if (ok == 0) {
          AppLogger.instance.info(_logSource, 'DeviceIoControl (IOCTL_STORAGE_QUERY_PROPERTY) mislukte voor $path.');
          return null;
        }
        if (bytesReturned.value < _outputSize) {
          AppLogger.instance.debug(
            _logSource,
            'DeviceIoControl for $path returned fewer bytes (${bytesReturned.value}) than expected ($_outputSize)',
          );
          return null;
        }

        // NVME_HEALTH_INFO_LOG starts at offset 48 (8-byte
        // STORAGE_PROTOCOL_DATA_DESCRIPTOR header + 40-byte
        // STORAGE_PROTOCOL_SPECIFIC_DATA). Within it: PercentageUsed is a
        // single byte at log offset 5; PowerOnHours is a 128-bit field at
        // log offset 128 — only the low 8 bytes are read as a plain
        // 64-bit count, since no real drive will ever have enough
        // power-on hours to need the upper 64 bits.
        const logStart = 8 + _protocolSpecificDataSize;
        final percentageUsed = byteData.getUint8(logStart + 5);
        final powerOnHoursLow = byteData.getUint64(logStart + 128, Endian.little);

        // A sanity bound, not a real limit — NVME_HEALTH_INFO_LOG values
        // exceeding what any real drive could report point at a parsing
        // error (wrong offset) rather than genuine data, and this class
        // would rather return nothing than a nonsense number.
        if (powerOnHoursLow > 1000000) {
          AppLogger.instance.debug(
            _logSource,
            'Implausible PowerOnHours ($powerOnHoursLow) for $path — treating as a parse failure, not real data.',
          );
          return null;
        }

        return (percentageUsed: percentageUsed.toDouble(), powerOnHours: powerOnHoursLow);
      } finally {
        calloc.free(buffer);
        calloc.free(bytesReturned);
      }
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Unexpected exception reading $path: $e\n$st');
      return null;
    } finally {
      if (handle != _invalidHandleValue) _closeHandle(handle);
      calloc.free(pathPtr);
    }
  }
}
