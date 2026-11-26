import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'AtaPassThroughReader';

/// Last-resort SMART access via `IOCTL_ATA_PASS_THROUGH` — sends a raw
/// ATA "SMART READ DATA" command straight to the device, bypassing every
/// higher-level SMART abstraction Windows offers (Get-StorageReliability
/// Counter, the `MSStorageDriver_FailurePredictData` WMI class this app
/// already tries first). This is specifically the mechanism Hard Disk
/// Sentinel's own documentation and forum point to for reaching drives
/// behind some RAID controllers — and, per that same documentation, its
/// success is honestly **driver-version-dependent and undocumented by
/// the RAID vendor itself**, not something even that mature, dedicated
/// commercial tool can guarantee. This class is tried only after the WMI
/// route has already returned nothing, not as a replacement for it.
///
/// **Risk profile:** the same category as this app's other IOCTL-based
/// readers (NvmeHealthReader, BatteryIoctlReader) — `ATA_PASS_THROUGH_EX`
/// is a plain, fixed-layout struct with field-by-field documentation
/// from Microsoft's own current API reference
/// (learn.microsoft.com/.../ns-ntddscsi-_ata_pass_through_ex), not a
/// vtable. A wrong field fails the IOCTL cleanly rather than crashing a
/// driver. The SMART data byte layout parsed out of the response is the
/// exact same attribute-table format already verified against the
/// open-source Krugertech.IO.Smart library for this app's WMI-based
/// reader — reused here, not re-derived.
class AtaPassThroughReader {
  static const int _genericRead = 0x80000000;
  static const int _genericWrite = 0x40000000;
  static const int _fileShareRead = 0x00000001;
  static const int _fileShareWrite = 0x00000002;
  static const int _openExisting = 3;
  static const int _invalidHandleValue = -1;

  // CTL_CODE(FILE_DEVICE_CONTROLLER=0x4, 0x040b, METHOD_BUFFERED=0,
  // FILE_READ_ACCESS|FILE_WRITE_ACCESS=0x3) — the standard,
  // widely-referenced constant for this IOCTL.
  static const int _ioctlAtaPassThrough = 0x0004D02C;

  static const int _ataFlagsDrdyRequired = 0x01;
  static const int _ataFlagsDataIn = 0x02;

  // sizeof(ATA_PASS_THROUGH_EX) on 64-bit: Length(2)+AtaFlags(2)+
  // PathId(1)+TargetId(1)+Lun(1)+ReservedAsUchar(1)+
  // DataTransferLength(4)+TimeOutValue(4)+ReservedAsUlong(4) = 20,
  // padded to 24 for DataBufferOffset's 8-byte alignment, +8
  // (DataBufferOffset) +8 (PreviousTaskFile) +8 (CurrentTaskFile) = 48.
  static const int _structSize = 48;
  static const int _smartDataSize = 512;
  static const int _totalBufferSize = _structSize + _smartDataSize;

  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  late final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFileW;
  late final int Function(int) _closeHandle;
  late final int Function(int, int, Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      _deviceIoControl;

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

  /// Sends a raw ATA SMART READ DATA command to `\\.\PhysicalDriveN` and
  /// extracts power-on hours (SMART attribute 9) and temperature
  /// (attribute 194) from the response — the same two, cross-vendor-
  /// consistent attributes this app already limits itself to elsewhere,
  /// for the same reasoning (wear-related attributes vary too much by
  /// vendor to interpret safely). Returns null on absolutely any
  /// failure: not accessible, the RAID/storage driver doesn't implement
  /// ATA pass-through, or a malformed response — logged at info level so
  /// a real attempt's outcome is always visible, never surfaced as an
  /// error to the person using the app.
  ({int? powerOnHours, double? temperatureC})? readSmartData(int physicalDriveIndex) {
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
        AppLogger.instance.info(_logSource, 'CreateFileW failed for $path.');
        return null;
      }

      final buffer = calloc<Uint8>(_totalBufferSize);
      final bytesReturned = calloc<Uint32>();
      try {
        final byteData = buffer.asTypedList(_totalBufferSize).buffer.asByteData();

        // --- ATA_PASS_THROUGH_EX header ---
        byteData.setUint16(0, _structSize, Endian.little); // Length
        byteData.setUint16(2, _ataFlagsDataIn | _ataFlagsDrdyRequired, Endian.little); // AtaFlags
        // PathId/TargetId/Lun/ReservedAsUchar (offsets 4-7) left zero —
        // the port driver fills in PathId itself; TargetId/Lun default
        // to 0 for a single-LUN direct-attached disk.
        byteData.setUint32(8, _smartDataSize, Endian.little); // DataTransferLength
        byteData.setUint32(12, 10, Endian.little); // TimeOutValue (seconds)
        // ReservedAsUlong (offset 16-19) and the 4-byte alignment pad
        // (20-23) left zero.
        byteData.setUint64(24, _structSize, Endian.little); // DataBufferOffset — data starts right after the struct

        // --- CurrentTaskFile (offset 40-47): SMART READ DATA command ---
        // [0]=Features(0xD0 SMART READ DATA), [1]=SectorCount(1),
        // [2]=SectorNumber(0), [3]=CylinderLow(0x4F, required SMART
        // magic), [4]=CylinderHigh(0xC2, required SMART magic),
        // [5]=Device/Head(0xA0), [6]=Command(0xB0 SMART), [7]=Reserved.
        const taskFileOffset = 40;
        buffer[taskFileOffset + 0] = 0xD0;
        buffer[taskFileOffset + 1] = 0x01;
        buffer[taskFileOffset + 2] = 0x00;
        buffer[taskFileOffset + 3] = 0x4F;
        buffer[taskFileOffset + 4] = 0xC2;
        buffer[taskFileOffset + 5] = 0xA0;
        buffer[taskFileOffset + 6] = 0xB0;
        buffer[taskFileOffset + 7] = 0x00;

        final ok = _deviceIoControl(
          handle,
          _ioctlAtaPassThrough,
          buffer.cast<Void>(),
          _totalBufferSize,
          buffer.cast<Void>(),
          _totalBufferSize,
          bytesReturned,
          nullptr,
        );
        if (ok == 0) {
          AppLogger.instance.info(
            _logSource,
            'DeviceIoControl (IOCTL_ATA_PASS_THROUGH) mislukte voor $path — driver ondersteunt '
            'waarschijnlijk geen ATA-passthrough voor deze schijf/RAID-configuratie.',
          );
          return null;
        }

        // The SMART data sector starts right after the struct — same
        // 2-byte-header-then-12-bytes-per-attribute layout already
        // verified for this app's WMI-based reader (see that reader's
        // own doc for the source of that verification).
        const dataStart = _structSize;
        int? powerOnHours;
        double? temperatureC;
        for (var i = 0; i < 30; i++) {
          final base = dataStart + i * 12 + 2;
          if (base + 10 >= _totalBufferSize) break;
          final id = byteData.getUint8(base);
          if (id == 9) {
            powerOnHours = byteData.getUint32(base + 5, Endian.little);
          } else if (id == 194) {
            temperatureC = byteData.getUint8(base + 5).toDouble();
          }
        }

        if (powerOnHours == null && temperatureC == null) {
          AppLogger.instance.info(
            _logSource,
            'IOCTL_ATA_PASS_THROUGH voor $path slaagde, maar geen bruikbare SMART-attributen gevonden '
            'in de respons.',
          );
          return null;
        }

        AppLogger.instance.info(
          _logSource,
          'IOCTL_ATA_PASS_THROUGH voor $path gelukt: powerOnHours=$powerOnHours, temperatureC=$temperatureC.',
        );
        return (powerOnHours: powerOnHours, temperatureC: temperatureC);
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
