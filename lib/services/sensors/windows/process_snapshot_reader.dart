import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'ProcessSnapshotReader';

/// Direct Win32 process enumeration and CPU%/memory sampling via
/// `CreateToolhelp32Snapshot` + `GetProcessTimes`/`GetSystemTimes` +
/// `GetProcessMemoryInfo` — the same, specific set of APIs Dave
/// Plummer's own open-source `tm` (a small console task manager,
/// github.com/PlummersSoftwareLLC/tm) uses for exactly this purpose,
/// confirmed from that project's own README rather than guessed at.
/// Replaces this app's previous `Get-CimInstance
/// Win32_PerfFormattedData_PerfProc_Process`-based approach — a
/// PowerShell/WMI round-trip is measurably slower than these plain,
/// direct Win32 calls, which is the whole reason this class exists.
///
/// **Risk profile:** every function here is a plain, stable, decades-old
/// Win32 API with a fixed, well-known signature — no vtables, no COM.
/// `PROCESSENTRY32W` and `PROCESS_MEMORY_COUNTERS` are plain structs
/// with documented, unchanging layouts. This is the same safe category
/// as this app's other native readers (PDH, kernel32 memory/battery/
/// uptime), not the vtable-based risk this app has deliberately stayed
/// away from elsewhere (D3D11).
///
/// **CPU% methodology, matching `tm`'s own described approach:** each
/// process' (kernel + user) time is compared, as a delta between two
/// samples, against the system-wide (idle + kernel + user) time delta
/// over the same interval — normalized so that a process fully
/// occupying one core reads as 100%, matching every other CPU%
/// convention already used throughout this app. The very first time a
/// PID is seen, no prior sample exists to diff against, so it reads as
/// 0% for that one poll rather than a guess — exactly the same "no
/// previous sample yet" handling this app already uses for RAPL power
/// and disk I/O rate deltas elsewhere.
class ProcessSnapshotReader {
  static const int _th32csSnapProcess = 0x00000002;
  static const int _invalidHandleValue = -1;
  static const int _processQueryLimitedInformation = 0x1000;
  static const int _processVmRead = 0x0010;

  // sizeof(PROCESSENTRY32W) on 64-bit — see this class's accompanying
  // design notes for the field-by-field byte offsets this was computed
  // from (dwSize@0, th32ProcessID@8, th32ParentProcessID@32,
  // szExeFile@44, 520 bytes of WCHAR[260], padded to a multiple of 8).
  static const int _processEntrySize = 568;
  static const int _exeFileOffset = 44;
  static const int _exeFileMaxChars = 260;

  // sizeof(PROCESS_MEMORY_COUNTERS) on 64-bit.
  static const int _processMemoryCountersSize = 72;
  static const int _workingSetSizeOffset = 16;

  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  late final int Function(int, int) _createToolhelp32Snapshot;
  late final int Function(int, Pointer<Uint8>) _process32FirstW;
  late final int Function(int, Pointer<Uint8>) _process32NextW;
  late final int Function(int) _closeHandle;
  late final int Function(int, int, int) _openProcess;
  late final int Function(int, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _getProcessTimes;
  late final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _getSystemTimes;
  late final int Function(int, Pointer<Uint8>, int) _getProcessMemoryInfo;

  bool _bound = false;
  bool _bindFunctions() {
    if (_bound) return true;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _createToolhelp32Snapshot = kernel32.lookupFunction<IntPtr Function(Uint32, Uint32), int Function(int, int)>(
          'CreateToolhelp32Snapshot');
      _process32FirstW = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)>('Process32FirstW');
      _process32NextW = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)>('Process32NextW');
      _closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
      _openProcess = kernel32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
          'OpenProcess');
      _getProcessTimes = kernel32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('GetProcessTimes');
      _getSystemTimes = kernel32.lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>),
          int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('GetSystemTimes');
      // K32GetProcessMemoryInfo is kernel32's own re-export of the same
      // function psapi.dll traditionally provided — available directly
      // from kernel32 since Windows 7, avoiding a second DLL load for
      // one function.
      _getProcessMemoryInfo = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32),
          int Function(int, Pointer<Uint8>, int)>('K32GetProcessMemoryInfo');
      _bound = true;
      return true;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to bind kernel32 functions: $e\n$st');
      _permanentlyDisabled = true;
      return false;
    }
  }

  // Previous poll's (kernelTime + userTime) per PID, and the previous
  // poll's system-wide (idle + kernel + user) totals — the state a
  // delta-based CPU% calculation needs between two samples. Same
  // "first sample has nothing to diff against, reads as 0%" handling
  // this app's other delta-based readers (RAPL power, disk I/O) use.
  final Map<int, int> _previousProcessTimes = {};
  int? _previousSystemTime;

  /// Returns one entry per process this snapshot could enumerate. A
  /// process this call can't `OpenProcess` (some protected system
  /// processes, even when elevated) still appears with its name and PID
  /// from the snapshot itself — only cpuPercent/workingSetBytes are
  /// left at 0 for that one, rather than dropping the process from the
  /// list entirely.
  List<({int pid, int parentPid, String name, double cpuPercent, int workingSetBytes})>? readAll() {
    if (_permanentlyDisabled) return null;
    if (!Platform.isWindows) return null;
    if (!_bindFunctions()) return null;

    final systemTimesBuf = calloc<Uint8>(24); // 3x FILETIME (8 bytes each): idle, kernel, user
    int snapshot = _invalidHandleValue;
    try {
      if (_getSystemTimes(systemTimesBuf, systemTimesBuf.elementAt(8), systemTimesBuf.elementAt(16)) == 0) {
        AppLogger.instance.debug(_logSource, 'GetSystemTimes failed.');
        return null;
      }
      final sysData = systemTimesBuf.asTypedList(24).buffer.asByteData();
      final idle = _fileTimeToInt(sysData, 0);
      final kernel = _fileTimeToInt(sysData, 8);
      final user = _fileTimeToInt(sysData, 16);
      final currentSystemTime = idle + kernel + user;

      snapshot = _createToolhelp32Snapshot(_th32csSnapProcess, 0);
      if (snapshot == _invalidHandleValue) {
        AppLogger.instance.debug(_logSource, 'CreateToolhelp32Snapshot failed.');
        return null;
      }

      final entry = calloc<Uint8>(_processEntrySize);
      final results = <({int pid, int parentPid, String name, double cpuPercent, int workingSetBytes})>[];
      final currentProcessTimes = <int, int>{};

      try {
        entry.cast<Uint32>()[0] = _processEntrySize; // dwSize, required before the first call
        var more = _process32FirstW(snapshot, entry) != 0;

        while (more) {
          final entryData = entry.asTypedList(_processEntrySize).buffer.asByteData();
          final pid = entryData.getUint32(8, Endian.little);
          final parentPid = entryData.getUint32(32, Endian.little);
          final name = _readWideStringAt(entry, _exeFileOffset, _exeFileMaxChars);

          double cpuPercent = 0;
          int workingSetBytes = 0;

          // PID 0 is the System Idle Process — not a real process to
          // report on (every other tool, including Task Manager
          // itself, excludes it the same way).
          if (pid != 0) {
            final handle = _openProcess(_processQueryLimitedInformation | _processVmRead, 0, pid);
            if (handle != 0) {
              try {
                final timesBuf = calloc<Uint8>(32); // 4x FILETIME: creation, exit, kernel, user
                try {
                  if (_getProcessTimes(
                          handle, timesBuf, timesBuf.elementAt(8), timesBuf.elementAt(16), timesBuf.elementAt(24)) !=
                      0) {
                    final timesData = timesBuf.asTypedList(32).buffer.asByteData();
                    final procKernel = _fileTimeToInt(timesData, 16);
                    final procUser = _fileTimeToInt(timesData, 24);
                    final procTime = procKernel + procUser;
                    currentProcessTimes[pid] = procTime;

                    final previousProcTime = _previousProcessTimes[pid];
                    final previousSysTime = _previousSystemTime;
                    if (previousProcTime != null && previousSysTime != null) {
                      final procDelta = procTime - previousProcTime;
                      final sysDelta = currentSystemTime - previousSysTime;
                      if (sysDelta > 0 && procDelta >= 0) {
                        // Normalized so one fully-occupied core reads as
                        // 100% — see this class's own doc for why
                        // multiplying by core count here is what makes
                        // that true (GetSystemTimes' delta already
                        // aggregates across every core).
                        cpuPercent = (procDelta / sysDelta) * Platform.numberOfProcessors * 100;
                      }
                    }
                  }
                } finally {
                  calloc.free(timesBuf);
                }

                final memBuf = calloc<Uint8>(_processMemoryCountersSize);
                try {
                  memBuf.cast<Uint32>()[0] = _processMemoryCountersSize; // cb
                  if (_getProcessMemoryInfo(handle, memBuf, _processMemoryCountersSize) != 0) {
                    workingSetBytes = memBuf
                        .asTypedList(_processMemoryCountersSize)
                        .buffer
                        .asByteData()
                        .getUint64(_workingSetSizeOffset, Endian.little);
                  }
                } finally {
                  calloc.free(memBuf);
                }
              } finally {
                _closeHandle(handle);
              }
            }
            // OpenProcess failing (protected system process, even when
            // elevated) isn't logged per-process — expected and common
            // enough (per tm's own README: "some system processes may
            // not open") that logging it would just be noise; the
            // process still appears in the results with 0%/0 bytes
            // rather than being silently dropped.
          }

          results.add(
            (pid: pid, parentPid: parentPid, name: name, cpuPercent: cpuPercent, workingSetBytes: workingSetBytes),
          );
          more = _process32NextW(snapshot, entry) != 0;
        }
      } finally {
        calloc.free(entry);
      }

      _previousProcessTimes
        ..clear()
        ..addAll(currentProcessTimes);
      _previousSystemTime = currentSystemTime;

      return results;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Unexpected exception: $e\n$st');
      return null;
    } finally {
      if (snapshot != _invalidHandleValue) _closeHandle(snapshot);
      calloc.free(systemTimesBuf);
    }
  }

  int _fileTimeToInt(ByteData data, int offset) {
    final low = data.getUint32(offset, Endian.little);
    final high = data.getUint32(offset + 4, Endian.little);
    return (high << 32) | low;
  }

  String _readWideStringAt(Pointer<Uint8> buffer, int offset, int maxChars) {
    final units = <int>[];
    final byteData = buffer.asTypedList(offset + maxChars * 2).buffer.asByteData();
    for (var i = 0; i < maxChars; i++) {
      final unit = byteData.getUint16(offset + i * 2, Endian.little);
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }
}
