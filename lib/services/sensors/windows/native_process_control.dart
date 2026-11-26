import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'NativeProcessControl';

/// Direct `dart:ffi` bindings to `kernel32.dll`'s process-control
/// functions (`OpenProcess`, `GetPriorityClass`/`SetPriorityClass`,
/// `GetProcessAffinityMask`/`SetProcessAffinityMask`, `CloseHandle`) —
/// same style as every other native reader in this directory (see
/// e.g. [NativeMemoryReader]'s class doc for the general approach).
///
/// One important difference from those readers, though: there, ANY
/// failure permanently disables the whole reader for the session,
/// because a failure there means the FFI binding itself is broken.
/// Here, [OpenProcess] can legitimately fail for one specific PID —
/// a protected system process denying the access this process has
/// rights to request, or the target simply having exited between the
/// caller reading the process list and acting on a row — without that
/// meaning the *binding* is broken. So only a failure to load
/// `kernel32.dll` or resolve a function pointer disables this class;
/// a per-PID `OpenProcess` failure just makes that one call return
/// null/false, exactly like a real access-denied error should.
class NativeProcessControl {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  static const int _processQueryInformation = 0x0400;
  static const int _processSetInformation = 0x0200;

  DynamicLibrary? _kernel32;
  late final int Function(int, int, int) _openProcess;
  late final int Function(int) _closeHandle;
  late final int Function(int) _getPriorityClass;
  late final int Function(int, int) _setPriorityClass;
  late final int Function(int, Pointer<Uint64>, Pointer<Uint64>) _getProcessAffinityMask;
  late final int Function(int, int) _setProcessAffinityMask;
  bool _bound = false;

  bool _ensureBound() {
    if (_bound) return true;
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      _openProcess = _kernel32!.lookupFunction<IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)>('OpenProcess');
      _closeHandle =
          _kernel32!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
      _getPriorityClass = _kernel32!
          .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetPriorityClass');
      _setPriorityClass = _kernel32!.lookupFunction<Int32 Function(IntPtr, Uint32),
          int Function(int, int)>('SetPriorityClass');
      // DWORD_PTR is pointer-width, i.e. 8 bytes on x64 — same width
      // as Uint64, which (unlike a bare Pointer<IntPtr>) is
      // unambiguously supported by dart:ffi's Pointer.value accessor
      // on every SDK version. This app already only ships an x64
      // Windows build (see the bundled VC++ runtime DLLs and
      // WinRing0x64.sys), so that width assumption holds.
      _getProcessAffinityMask = _kernel32!.lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>, Pointer<Uint64>)>('GetProcessAffinityMask');
      _setProcessAffinityMask = _kernel32!.lookupFunction<Int32 Function(IntPtr, IntPtr),
          int Function(int, int)>('SetProcessAffinityMask');
      _bound = true;
      AppLogger.instance.info(
        _logSource,
        'Directe procesbesturing (dart:ffi, geen taskkill/wmic) actief voor prioriteit en CPU-affinity.',
      );
      return true;
    } catch (e, st) {
      _permanentlyDisabled = true;
      _bound = false;
      AppLogger.instance.info(
        _logSource,
        'Directe procesbesturing uitgeschakeld voor de rest van deze sessie (kon kernel32.dll-functies '
        'niet binden: $e). Prioriteit/affinity wijzigen is deze sessie niet beschikbaar. Dit bericht komt niet terug.\n$st',
      );
      return false;
    }
  }

  /// Opens a handle with just enough access for the given operation,
  /// runs [action], and always closes the handle afterward — the one
  /// pattern shared by every public method below, so a caller can
  /// never forget the `CloseHandle` and leak a handle.
  T? _withProcessHandle<T>(int pid, int desiredAccess, T? Function(int handle) action) {
    if (!_ensureBound()) return null;
    final handle = _openProcess(desiredAccess, 0, pid);
    if (handle == 0) {
      // Expected/common: protected process, or it exited already —
      // debug-level, not an error, and definitely not a reason to
      // disable this class for every other PID too.
      AppLogger.instance.debug(_logSource, 'OpenProcess mislukte voor PID $pid (mogelijk beschermd proces of al gestopt).');
      return null;
    }
    try {
      return action(handle);
    } finally {
      _closeHandle(handle);
    }
  }

  /// Current priority class, or null if it couldn't be read (see
  /// [_withProcessHandle]'s doc — most commonly a protected process).
  int? getPriorityClass(int pid) {
    return _withProcessHandle(pid, _processQueryInformation, (handle) {
      final value = _getPriorityClass(handle);
      return value == 0 ? null : value;
    });
  }

  /// Attempts to set [pid]'s priority class. Returns false (never
  /// throws) on any failure — access denied is the overwhelmingly
  /// common one, for anything running as a different/more privileged
  /// user, or a handful of processes Windows itself protects
  /// regardless of the caller's own privilege level.
  bool setPriorityClass(int pid, int priorityClass) {
    final result = _withProcessHandle(
      pid,
      _processSetInformation,
      (handle) => _setPriorityClass(handle, priorityClass) != 0,
    );
    return result ?? false;
  }

  /// `(processAffinityMask, systemAffinityMask)` — the second value is
  /// which logical processors exist at all system-wide, needed by the
  /// UI to know how many checkboxes to draw. Null if unavailable.
  ({int process, int system})? getAffinityMasks(int pid) {
    return _withProcessHandle(pid, _processQueryInformation, (handle) {
      final processMask = calloc<Uint64>();
      final systemMask = calloc<Uint64>();
      try {
        final ok = _getProcessAffinityMask(handle, processMask, systemMask);
        if (ok == 0) return null;
        return (process: processMask.value, system: systemMask.value);
      } finally {
        calloc.free(processMask);
        calloc.free(systemMask);
      }
    });
  }

  /// Attempts to set [pid]'s CPU affinity to [mask] (one bit per
  /// logical processor). Returns false (never throws) on failure —
  /// same access-denied reasoning as [setPriorityClass]; also fails
  /// harmlessly if [mask] has no bits in common with the system
  /// affinity mask (Windows itself rejects that rather than leaving a
  /// process with no CPU to run on).
  bool setAffinityMask(int pid, int mask) {
    final result = _withProcessHandle(
      pid,
      _processSetInformation,
      (handle) => _setProcessAffinityMask(handle, mask) != 0,
    );
    return result ?? false;
  }
}
