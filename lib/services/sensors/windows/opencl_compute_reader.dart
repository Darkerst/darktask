import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../../core/logging/app_logger.dart';

const _logSource = 'OpenClComputeReader';

/// One GPU device as reported by OpenCL, identified by the
/// (platformIndex, deviceIndex) pair needed to select it again via
/// [OpenClComputeReader.runDispatchBatch]. These indices are only
/// stable for the lifetime of one enumeration — if a device is
/// unplugged/re-plugged the indices could shift, which is why
/// [OpenClComputeReader._ensureInitialized] clamps and falls back
/// rather than trusting a stale index blindly.
class OpenClGpuDevice {
  const OpenClGpuDevice({
    required this.platformIndex,
    required this.deviceIndex,
    required this.name,
  });

  final int platformIndex;
  final int deviceIndex;
  final String name;

  // Value equality by (platformIndex, deviceIndex) — a fresh
  // enumeration builds new instances every call, but a UI picker
  // (e.g. a Flutter DropdownButton, which matches its selected value
  // by `==`) needs the *previously selected* device to still compare
  // equal to its corresponding entry in a newly-fetched list.
  @override
  bool operator ==(Object other) =>
      other is OpenClGpuDevice && other.platformIndex == platformIndex && other.deviceIndex == deviceIndex;

  @override
  int get hashCode => Object.hash(platformIndex, deviceIndex);

  @override
  String toString() => name;
}

/// Direct `dart:ffi` bindings to OpenCL (`OpenCL.dll`) — a genuine
/// GPU compute-kernel stress test, the Windows equivalent of what
/// glmark2 provides on Linux.
///
/// **Why OpenCL and not Direct3D:** every OpenCL function used here is
/// a plain, named C export with a fixed, simple signature — the same
/// category of API as the PDH/kernel32 readers elsewhere in this
/// directory, all of which have run correctly across extensive
/// testing. Direct3D's compute path requires calling through COM
/// vtables (ID3D11Device, ID3D11DeviceContext), which this app
/// deliberately does not attempt: a vtable requires declaring every
/// preceding method in an interface correctly just to reach the
/// right byte offset for the one method actually needed, and the
/// complete, authoritative method ordering could not be verified with
/// real confidence against the actual Windows SDK headers (see the
/// design discussion this class came out of). A wrong offset there
/// calls an arbitrary wrong function through a graphics driver —
/// a categorically worse failure mode (driver crash / TDR reset)
/// than anything else in this codebase, and not a risk worth taking
/// on unverified information. OpenCL carries no such risk: every
/// function this class calls is verifiable against the stable,
/// unchanged-since-2009 Khronos OpenCL 1.x specification.
///
/// **Availability, not guaranteed:** unlike Direct3D (part of Windows
/// itself), OpenCL requires a vendor-supplied ICD (Installable Client
/// Driver) — Intel, AMD, and NVIDIA all normally ship one with their
/// graphics drivers, but it isn't universally present the way D3D is.
/// [isAvailable] checks this cleanly; the benchmark UI falls back to
/// the built-in render test when it returns false.
///
/// **Kernel design, deliberately simple:** a fixed, small work size
/// (4096 items) doing a bounded amount of transcendental math per
/// item, dispatched repeatedly from Dart in a loop rather than as one
/// giant dispatch. Windows' Timeout Detection and Recovery (TDR) will
/// forcibly reset a graphics driver if a single GPU command runs too
/// long (a default ~2 second budget) — many small, quick, measured
/// dispatches keep every individual command comfortably under that
/// budget and keep the test interruptible between dispatches, rather
/// than betting the whole test on one large dispatch stayng under an
/// OS-enforced timeout on hardware this was never tested against.
class OpenClComputeReader {
  static bool _permanentlyDisabled = false;
  static bool get isDisabled => _permanentlyDisabled;

  DynamicLibrary? _cl;
  int? _platform;
  int? _device;
  int? _context;
  int? _queue;
  int? _program;
  int? _kernel;
  int? _buffer;
  bool _initialized = false;

  // Which (platform, device) the currently-live context/queue/kernel
  // are actually bound to — compared against a newly-requested
  // selection in [_ensureInitialized] to decide whether a rebuild is
  // needed. Meaningless while `_initialized` is false.
  int _boundPlatformIndex = 0;
  int _boundDeviceIndex = 0;

  static const int _workItemCount = 4096;
  static const int _clSuccess = 0;
  static const int _clDeviceTypeGpu = 1 << 2;
  static const int _clMemReadWrite = 1;
  static const int _clProgramBuildLog = 0x1183;
  static const int _clDeviceName = 0x102B;

  // A bounded, meaningless-but-genuinely-GPU-intensive kernel: enough
  // transcendental-function iterations per work item to keep the GPU
  // busy for a measurable, sub-TDR-budget slice of time per dispatch,
  // without needing to read the (unused) result back to the CPU —
  // this test cares about sustained dispatch throughput, not the
  // computed values.
  static const String _kernelSource = '''
__kernel void darktask_stress(__global float* buf, const int iterations) {
    int gid = get_global_id(0);
    float x = (float)gid;
    for (int i = 0; i < iterations; i++) {
        x = sin(x) * cos(x) + sqrt(fabs(x)) + 1.0f;
    }
    buf[gid] = x;
}
''';

  late final int Function(int numEntries, Pointer<IntPtr> platforms, Pointer<Uint32> numPlatforms)
      _clGetPlatformIDs;
  late final int Function(
      int platform, int deviceType, int numEntries, Pointer<IntPtr> devices, Pointer<Uint32> numDevices)
      _clGetDeviceIDs;
  late final int Function(Pointer<IntPtr> properties, int numDevices, Pointer<IntPtr> devices,
      Pointer<Void> pfnNotify, Pointer<Void> userData, Pointer<Int32> errcodeRet) _clCreateContext;
  late final int Function(int context, int device, int properties, Pointer<Int32> errcodeRet)
      _clCreateCommandQueue;
  late final int Function(int context, int count, Pointer<Pointer<Utf8>> strings, Pointer<IntPtr> lengths,
      Pointer<Int32> errcodeRet) _clCreateProgramWithSource;
  late final int Function(int program, int numDevices, Pointer<IntPtr> deviceList, Pointer<Utf8> options,
      Pointer<Void> pfnNotify, Pointer<Void> userData) _clBuildProgram;
  late final int Function(int program, int device, int paramName, int paramValueSize,
      Pointer<Utf8> paramValue, Pointer<IntPtr> paramValueSizeRet) _clGetProgramBuildInfo;
  late final int Function(int device, int paramName, int paramValueSize, Pointer<Void> paramValue,
      Pointer<IntPtr> paramValueSizeRet) _clGetDeviceInfo;
  late final int Function(int program, Pointer<Utf8> kernelName, Pointer<Int32> errcodeRet) _clCreateKernel;
  late final int Function(int context, int flags, int size, Pointer<Void> hostPtr, Pointer<Int32> errcodeRet)
      _clCreateBuffer;
  late final int Function(int kernel, int argIndex, int argSize, Pointer<Void> argValue) _clSetKernelArg;
  late final int Function(int queue, int kernel, int workDim, Pointer<IntPtr> globalWorkOffset,
      Pointer<IntPtr> globalWorkSize, Pointer<IntPtr> localWorkSize, int numEventsInWaitList,
      Pointer<IntPtr> eventWaitList, Pointer<IntPtr> event) _clEnqueueNDRangeKernel;
  late final int Function(int queue) _clFinish;
  late final int Function(int memobj) _clReleaseMemObject;
  late final int Function(int kernel) _clReleaseKernel;
  late final int Function(int program) _clReleaseProgram;
  late final int Function(int queue) _clReleaseCommandQueue;
  late final int Function(int context) _clReleaseContext;

  // Tracks whether every field below was actually assigned, not just
  // whether DynamicLibrary.open succeeded — _cl alone becoming
  // non-null partway through a failed attempt (opened the DLL, then
  // one specific lookupFunction call threw because that export wasn't
  // found) would otherwise let a later call see "_cl != null" and
  // skip re-binding while several `late final` fields below were never
  // actually assigned, trading today's crash for a different, equally
  // broken "field not yet initialized" one instead.
  bool _bindingSucceeded = false;

  bool _bindFunctions() {
    // Idempotency guard belongs here too, not just at each call site:
    // every field this method assigns is `late final` (settable only
    // once, ever), so re-running it after a successful earlier call
    // throws LateInitializationError rather than harmlessly
    // re-binding — a mistake easy enough to reintroduce at a future
    // call site that this method should refuse to redo the work
    // itself, not rely on every caller remembering to check first.
    if (_bindingSucceeded) return true;
    try {
      _cl = DynamicLibrary.open('OpenCL.dll');
      _clGetPlatformIDs = _cl!.lookupFunction<Int32 Function(Uint32, Pointer<IntPtr>, Pointer<Uint32>),
          int Function(int, Pointer<IntPtr>, Pointer<Uint32>)>('clGetPlatformIDs');
      _clGetDeviceIDs = _cl!.lookupFunction<
          Int32 Function(IntPtr, Uint64, Uint32, Pointer<IntPtr>, Pointer<Uint32>),
          int Function(int, int, int, Pointer<IntPtr>, Pointer<Uint32>)>('clGetDeviceIDs');
      _clCreateContext = _cl!.lookupFunction<
          IntPtr Function(
              Pointer<IntPtr>, Uint32, Pointer<IntPtr>, Pointer<Void>, Pointer<Void>, Pointer<Int32>),
          int Function(Pointer<IntPtr>, int, Pointer<IntPtr>, Pointer<Void>, Pointer<Void>,
              Pointer<Int32>)>('clCreateContext');
      _clCreateCommandQueue = _cl!.lookupFunction<
          IntPtr Function(IntPtr, IntPtr, Uint64, Pointer<Int32>),
          int Function(int, int, int, Pointer<Int32>)>('clCreateCommandQueue');
      _clCreateProgramWithSource = _cl!.lookupFunction<
          IntPtr Function(IntPtr, Uint32, Pointer<Pointer<Utf8>>, Pointer<IntPtr>, Pointer<Int32>),
          int Function(int, int, Pointer<Pointer<Utf8>>, Pointer<IntPtr>,
              Pointer<Int32>)>('clCreateProgramWithSource');
      _clBuildProgram = _cl!.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<IntPtr>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>),
          int Function(int, int, Pointer<IntPtr>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>)>(
        'clBuildProgram',
      );
      _clGetProgramBuildInfo = _cl!.lookupFunction<
          Int32 Function(IntPtr, IntPtr, Uint32, IntPtr, Pointer<Utf8>, Pointer<IntPtr>),
          int Function(int, int, int, int, Pointer<Utf8>, Pointer<IntPtr>)>('clGetProgramBuildInfo');
      _clGetDeviceInfo = _cl!.lookupFunction<
          Int32 Function(IntPtr, Uint32, IntPtr, Pointer<Void>, Pointer<IntPtr>),
          int Function(int, int, int, Pointer<Void>, Pointer<IntPtr>)>('clGetDeviceInfo');
      _clCreateKernel = _cl!.lookupFunction<IntPtr Function(IntPtr, Pointer<Utf8>, Pointer<Int32>),
          int Function(int, Pointer<Utf8>, Pointer<Int32>)>('clCreateKernel');
      _clCreateBuffer = _cl!.lookupFunction<
          IntPtr Function(IntPtr, Uint64, IntPtr, Pointer<Void>, Pointer<Int32>),
          int Function(int, int, int, Pointer<Void>, Pointer<Int32>)>('clCreateBuffer');
      _clSetKernelArg = _cl!.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, Pointer<Void>),
          int Function(int, int, int, Pointer<Void>)>('clSetKernelArg');
      _clEnqueueNDRangeKernel = _cl!.lookupFunction<
          Int32 Function(IntPtr, IntPtr, Uint32, Pointer<IntPtr>, Pointer<IntPtr>, Pointer<IntPtr>, Uint32,
              Pointer<IntPtr>, Pointer<IntPtr>),
          int Function(int, int, int, Pointer<IntPtr>, Pointer<IntPtr>, Pointer<IntPtr>, int,
              Pointer<IntPtr>, Pointer<IntPtr>)>('clEnqueueNDRangeKernel');
      _clFinish = _cl!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('clFinish');
      _clReleaseMemObject =
          _cl!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('clReleaseMemObject');
      _clReleaseKernel = _cl!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('clReleaseKernel');
      _clReleaseProgram = _cl!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('clReleaseProgram');
      _clReleaseCommandQueue =
          _cl!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('clReleaseCommandQueue');
      _clReleaseContext = _cl!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('clReleaseContext');
      _bindingSucceeded = true;
      return true;
    } catch (e, st) {
      // A failure here may have already assigned some (but not all)
      // of the `late final` fields above before the exception hit —
      // e.g. the DLL opened fine but one specific export wasn't
      // found. Retrying _bindFunctions() later would attempt to
      // reassign whichever fields DID succeed the first time, which
      // throws LateInitializationError just as reliably as the bug
      // this whole method exists to prevent. Disabling permanently
      // right here — the same "never retry after any anomaly"
      // philosophy this class already applies everywhere else —
      // sidesteps that risk entirely rather than trying to recover
      // from a partially-bound state.
      disable('Failed to bind OpenCL.dll functions: $e\n$st');
      return false;
    }
  }

  /// Cheap, side-effect-light check: is there an OpenCL runtime with
  /// at least one GPU device on this machine at all. Doesn't create a
  /// context — that happens lazily in [_ensureInitialized] only when a
  /// dispatch is actually requested.
  bool isAvailable() {
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;
    // Same guard _ensureInitialized already uses below — _bindFunctions
    // assigns to `late final` fields, which can only be set once ever.
    // Calling isAvailable() a second time (e.g. the person opens the
    // Benchmarks screen, tries the compute test, then tries it again)
    // without this check re-runs those assignments and throws
    // LateInitializationError, which is exactly what was observed and
    // reproduced in testing.
    if (_cl == null && !_bindFunctions()) return false;

    final platformCount = calloc<Uint32>();
    final deviceCount = calloc<Uint32>();
    try {
      if (_clGetPlatformIDs(0, nullptr, platformCount) != _clSuccess || platformCount.value == 0) {
        return false;
      }
      final platforms = calloc<IntPtr>(platformCount.value);
      try {
        if (_clGetPlatformIDs(platformCount.value, platforms, nullptr) != _clSuccess) return false;
        // Any platform with at least one GPU device is good enough —
        // the actual platform/device selection happens again in
        // _ensureInitialized, this is purely a yes/no probe for the UI.
        for (var i = 0; i < platformCount.value; i++) {
          final status = _clGetDeviceIDs(platforms[i], _clDeviceTypeGpu, 0, nullptr, deviceCount);
          if (status == _clSuccess && deviceCount.value > 0) return true;
        }
        return false;
      } finally {
        calloc.free(platforms);
      }
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'isAvailable probe failed: $e');
      return false;
    } finally {
      calloc.free(platformCount);
      calloc.free(deviceCount);
    }
  }

  /// Enumerates every GPU device across every OpenCL platform on this
  /// machine, with human-readable names — used to populate an in-app
  /// device picker so a multi-GPU system (e.g. a discrete AMD card
  /// plus an Intel iGPU) can choose which physical GPU the compute
  /// test actually stresses. Unlike the built-in "render" test mode
  /// (which is permanently bound to whichever single GPU Flutter's
  /// own D3D/ANGLE surface happens to use for the app's entire
  /// lifetime — an architectural limitation, not something fixable
  /// from Dart), OpenCL device selection is fully independent of
  /// that: this is genuinely the GPU that will be exercised.
  ///
  /// Never throws; returns an empty list if OpenCL is unavailable or
  /// no GPU devices are found, which callers should treat the same as
  /// "compute test unavailable, offer render mode instead."
  List<OpenClGpuDevice> listGpuDevices() {
    if (_permanentlyDisabled) return const [];
    if (!Platform.isWindows) return const [];
    if (_cl == null && !_bindFunctions()) return const [];

    final result = <OpenClGpuDevice>[];
    final platformCountPtr = calloc<Uint32>();
    Pointer<IntPtr> platforms = nullptr;
    final deviceCountPtr = calloc<Uint32>();
    Pointer<IntPtr> devices = nullptr;
    final nameSizePtr = calloc<IntPtr>();
    try {
      if (_clGetPlatformIDs(0, nullptr, platformCountPtr) != _clSuccess || platformCountPtr.value == 0) {
        return const [];
      }
      platforms = calloc<IntPtr>(platformCountPtr.value);
      if (_clGetPlatformIDs(platformCountPtr.value, platforms, nullptr) != _clSuccess) {
        return const [];
      }
      for (var p = 0; p < platformCountPtr.value; p++) {
        final platform = platforms[p];
        if (_clGetDeviceIDs(platform, _clDeviceTypeGpu, 0, nullptr, deviceCountPtr) != _clSuccess ||
            deviceCountPtr.value == 0) {
          continue;
        }
        if (devices != nullptr) {
          calloc.free(devices);
          devices = nullptr;
        }
        devices = calloc<IntPtr>(deviceCountPtr.value);
        if (_clGetDeviceIDs(platform, _clDeviceTypeGpu, deviceCountPtr.value, devices, nullptr) !=
            _clSuccess) {
          continue;
        }
        for (var d = 0; d < deviceCountPtr.value; d++) {
          final device = devices[d];
          var name = 'GPU $p:$d';
          if (_clGetDeviceInfo(device, _clDeviceName, 0, nullptr, nameSizePtr) == _clSuccess &&
              nameSizePtr.value > 0) {
            final nameBuf = calloc<Uint8>(nameSizePtr.value);
            try {
              if (_clGetDeviceInfo(device, _clDeviceName, nameSizePtr.value, nameBuf.cast<Void>(),
                      nullptr) ==
                  _clSuccess) {
                final decoded = nameBuf.cast<Utf8>().toDartString();
                if (decoded.trim().isNotEmpty) name = decoded.trim();
              }
            } finally {
              calloc.free(nameBuf);
            }
          }
          result.add(OpenClGpuDevice(platformIndex: p, deviceIndex: d, name: name));
        }
      }
      return result;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'listGpuDevices mislukt: $e');
      return const [];
    } finally {
      calloc.free(platformCountPtr);
      if (platforms != nullptr) calloc.free(platforms);
      calloc.free(deviceCountPtr);
      if (devices != nullptr) calloc.free(devices);
      calloc.free(nameSizePtr);
    }
  }

  /// Ensures a live OpenCL context/queue/kernel exists, bound to the
  /// requested (platformIndex, deviceIndex). If a context already
  /// exists but for a *different* device, the old one is torn down
  /// and a fresh one built for the newly-requested device — this is
  /// what makes runtime device switching (the GPU picker) actually
  /// take effect instead of silently continuing to test whichever
  /// device happened to be bound first.
  ///
  /// An out-of-range index (e.g. a device was unplugged after the
  /// picker's list was built) is clamped to 0 with a logged warning
  /// rather than treated as a hard failure — a stale UI selection
  /// shouldn't disable the whole compute test for the rest of the
  /// session the way a genuine OpenCL/driver failure does.
  bool _ensureInitialized({int platformIndex = 0, int deviceIndex = 0}) {
    if (_permanentlyDisabled) return false;
    if (!Platform.isWindows) return false;

    if (_initialized) {
      if (_boundPlatformIndex == platformIndex && _boundDeviceIndex == deviceIndex) {
        return true;
      }
      _releaseQuietly();
      _initialized = false;
    }

    try {
      if (_cl == null && !_bindFunctions()) {
        disable('OpenCL.dll functions could not be bound');
        return false;
      }

      final platformCount = calloc<Uint32>();
      Pointer<IntPtr> platforms = nullptr;
      final deviceCount = calloc<Uint32>();
      Pointer<IntPtr> devices = nullptr;
      final errcode = calloc<Int32>();
      try {
        if (_clGetPlatformIDs(0, nullptr, platformCount) != _clSuccess || platformCount.value == 0) {
          disable('No OpenCL platform found');
          return false;
        }
        var resolvedPlatformIndex = platformIndex;
        if (resolvedPlatformIndex < 0 || resolvedPlatformIndex >= platformCount.value) {
          AppLogger.instance.info(
            _logSource,
            'Gevraagde OpenCL-platformindex $platformIndex bestaat niet (er zijn ${platformCount.value}) '
            '— terugvallen op platform 0.',
          );
          resolvedPlatformIndex = 0;
        }
        platforms = calloc<IntPtr>(platformCount.value);
        if (_clGetPlatformIDs(platformCount.value, platforms, nullptr) != _clSuccess) {
          disable('clGetPlatformIDs (fetch) failed');
          return false;
        }
        _platform = platforms[resolvedPlatformIndex];

        if (_clGetDeviceIDs(_platform!, _clDeviceTypeGpu, 0, nullptr, deviceCount) != _clSuccess ||
            deviceCount.value == 0) {
          disable('No OpenCL GPU device found on platform $resolvedPlatformIndex');
          return false;
        }
        var resolvedDeviceIndex = deviceIndex;
        if (resolvedDeviceIndex < 0 || resolvedDeviceIndex >= deviceCount.value) {
          AppLogger.instance.info(
            _logSource,
            'Gevraagde OpenCL-apparaatindex $deviceIndex bestaat niet op platform $resolvedPlatformIndex '
            '(er zijn ${deviceCount.value}) — terugvallen op apparaat 0.',
          );
          resolvedDeviceIndex = 0;
        }
        devices = calloc<IntPtr>(deviceCount.value);
        if (_clGetDeviceIDs(_platform!, _clDeviceTypeGpu, deviceCount.value, devices, nullptr) !=
            _clSuccess) {
          disable('clGetDeviceIDs (fetch) failed');
          return false;
        }
        _device = devices[resolvedDeviceIndex];

        final deviceArrayForContext = calloc<IntPtr>(1);
        try {
          deviceArrayForContext[0] = _device!;
          final context =
              _clCreateContext(nullptr, 1, deviceArrayForContext, nullptr, nullptr, errcode);
          if (errcode.value != _clSuccess || context == 0) {
            disable('clCreateContext failed (errcode=${errcode.value})');
            return false;
          }
          _context = context;
        } finally {
          calloc.free(deviceArrayForContext);
        }

        final queue = _clCreateCommandQueue(_context!, _device!, 0, errcode);
        if (errcode.value != _clSuccess || queue == 0) {
          disable('clCreateCommandQueue failed (errcode=${errcode.value})');
          return false;
        }
        _queue = queue;

        final sourcePtr = _kernelSource.toNativeUtf8();
        final sourcePtrArray = calloc<Pointer<Utf8>>(1);
        try {
          sourcePtrArray[0] = sourcePtr;
          final program = _clCreateProgramWithSource(_context!, 1, sourcePtrArray, nullptr, errcode);
          if (errcode.value != _clSuccess || program == 0) {
            disable('clCreateProgramWithSource failed (errcode=${errcode.value})');
            return false;
          }
          _program = program;
        } finally {
          calloc.free(sourcePtrArray);
          calloc.free(sourcePtr);
        }

        final deviceArrayForBuild = calloc<IntPtr>(1);
        try {
          deviceArrayForBuild[0] = _device!;
          final buildStatus =
              _clBuildProgram(_program!, 1, deviceArrayForBuild, nullptr, nullptr, nullptr);
          if (buildStatus != _clSuccess) {
            final logSizePtr = calloc<IntPtr>();
            try {
              _clGetProgramBuildInfo(
                  _program!, _device!, _clProgramBuildLog, 0, nullptr, logSizePtr);
              final logSize = logSizePtr.value;
              String buildLog = '(geen build-log beschikbaar)';
              if (logSize > 0) {
                // Utf8 itself has no fixed per-element size (it's a
                // variable-length string type), so it can't be the
                // type argument to calloc<T>() directly — allocate the
                // raw byte buffer as Uint8, then cast the pointer to
                // Utf8 only where a char* is actually needed.
                final logBuf = calloc<Uint8>(logSize);
                try {
                  _clGetProgramBuildInfo(
                      _program!, _device!, _clProgramBuildLog, logSize, logBuf.cast<Utf8>(), nullptr);
                  buildLog = logBuf.cast<Utf8>().toDartString();
                } finally {
                  calloc.free(logBuf);
                }
              }
              disable('clBuildProgram failed (status=$buildStatus): $buildLog');
            } finally {
              calloc.free(logSizePtr);
            }
            return false;
          }
        } finally {
          calloc.free(deviceArrayForBuild);
        }

        final kernelNamePtr = 'darktask_stress'.toNativeUtf8();
        try {
          final kernel = _clCreateKernel(_program!, kernelNamePtr, errcode);
          if (errcode.value != _clSuccess || kernel == 0) {
            disable('clCreateKernel failed (errcode=${errcode.value})');
            return false;
          }
          _kernel = kernel;
        } finally {
          calloc.free(kernelNamePtr);
        }

        final bufferSize = _workItemCount * 4; // sizeof(float) per work item
        final buffer = _clCreateBuffer(_context!, _clMemReadWrite, bufferSize, nullptr, errcode);
        if (errcode.value != _clSuccess || buffer == 0) {
          disable('clCreateBuffer failed (errcode=${errcode.value})');
          return false;
        }
        _buffer = buffer;

        final bufferArgPtr = calloc<IntPtr>();
        try {
          bufferArgPtr.value = _buffer!;
          if (_clSetKernelArg(_kernel!, 0, sizeOf<IntPtr>(), bufferArgPtr.cast<Void>()) != _clSuccess) {
            disable('clSetKernelArg(0) failed');
            return false;
          }
        } finally {
          calloc.free(bufferArgPtr);
        }

        _boundPlatformIndex = resolvedPlatformIndex;
        _boundDeviceIndex = resolvedDeviceIndex;
        _initialized = true;
        AppLogger.instance.info(
          _logSource,
          'Directe OpenCL GPU-computetest (dart:ffi, geen COM/vtables) actief '
          '(platform $resolvedPlatformIndex, apparaat $resolvedDeviceIndex).',
        );
        return true;
      } finally {
        calloc.free(platformCount);
        if (platforms != nullptr) calloc.free(platforms);
        calloc.free(deviceCount);
        if (devices != nullptr) calloc.free(devices);
        calloc.free(errcode);
      }
    } catch (e, st) {
      disable('Unexpected exception during init: $e\n$st');
      return false;
    }
  }

  /// Runs one bounded dispatch (enqueue + clFinish, so this call
  /// blocks until that one dispatch's GPU work is actually done) —
  /// call this repeatedly from a loop/ticker to sustain load for a
  /// test's duration, checking a cancellation flag between calls,
  /// rather than requesting one huge dispatch that isn't
  /// interruptible and risks Windows' TDR budget on hardware this
  /// wasn't tested against.
  ///
  /// [iterationsPerWorkItem] scales the load per dispatch — higher
  /// intensity settings pass a larger value here rather than a bigger
  /// work-item count, to keep each individual dispatch's GPU time
  /// controlled and predictable.
  ///
  /// [platformIndex]/[deviceIndex] select which GPU (from
  /// [listGpuDevices]) this dispatch actually runs on. Passing a
  /// different pair than the currently-bound device transparently
  /// tears down and rebuilds the OpenCL context for the new device on
  /// the next call — the caller doesn't need to manage that itself,
  /// just pass the desired selection every time.
  bool runDispatchBatch(int iterationsPerWorkItem, {int platformIndex = 0, int deviceIndex = 0}) {
    if (!_ensureInitialized(platformIndex: platformIndex, deviceIndex: deviceIndex)) return false;

    final iterationsArgPtr = calloc<Int32>();
    final globalWorkSize = calloc<IntPtr>();
    try {
      iterationsArgPtr.value = iterationsPerWorkItem;
      if (_clSetKernelArg(_kernel!, 1, sizeOf<Int32>(), iterationsArgPtr.cast<Void>()) != _clSuccess) {
        disable('clSetKernelArg(1) failed mid-run');
        return false;
      }

      globalWorkSize.value = _workItemCount;
      final enqueueStatus = _clEnqueueNDRangeKernel(
        _queue!,
        _kernel!,
        1,
        nullptr,
        globalWorkSize,
        nullptr,
        0,
        nullptr,
        nullptr,
      );
      if (enqueueStatus != _clSuccess) {
        disable('clEnqueueNDRangeKernel failed (status=$enqueueStatus)');
        return false;
      }

      // Blocks until this one dispatch's GPU work actually completes —
      // this is what turns "queued a command" into "measured real GPU
      // busy time," and what keeps each call's GPU-side duration
      // bounded and known rather than letting work queue up unbounded.
      final finishStatus = _clFinish(_queue!);
      if (finishStatus != _clSuccess) {
        disable('clFinish failed (status=$finishStatus)');
        return false;
      }

      return true;
    } catch (e, st) {
      disable('Unexpected exception during dispatch: $e\n$st');
      return false;
    } finally {
      calloc.free(iterationsArgPtr);
      calloc.free(globalWorkSize);
    }
  }

  void disable(String reason) {
    _permanentlyDisabled = true;
    _initialized = false;
    AppLogger.instance.info(
      _logSource,
      'OpenCL GPU-computetest uitgeschakeld voor de rest van deze sessie ($reason) — '
      'valt terug op de ingebouwde rendertest. Dit bericht komt niet terug.',
    );
    _releaseQuietly();
  }

  void dispose() {
    _releaseQuietly();
    _initialized = false;
  }

  void _releaseQuietly() {
    try {
      if (_buffer != null) _clReleaseMemObject(_buffer!);
      if (_kernel != null) _clReleaseKernel(_kernel!);
      if (_program != null) _clReleaseProgram(_program!);
      if (_queue != null) _clReleaseCommandQueue(_queue!);
      if (_context != null) _clReleaseContext(_context!);
    } catch (_) {
      // Already in a failure/cleanup path — nothing more this can
      // safely do.
    }
    _buffer = null;
    _kernel = null;
    _program = null;
    _queue = null;
    _context = null;
  }
}
