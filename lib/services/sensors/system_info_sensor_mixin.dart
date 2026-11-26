import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/system_info_sample.dart';
import 'gpu_sensor_mixin.dart';

const _logSource = 'LinuxSensorService';

/// Reads static/slow-changing system info: hostname, OS name, kernel
/// version, architecture, uptime, CPU model, core count, DMI hardware
/// identity, and desktop-session details. Meant to be called once when
/// the System Info screen opens (or on manual refresh), not polled
/// every second like the rest of the sensor domains.
///
/// Depends on [GpuSensorMixin] for the GPU-name list, so it's declared
/// `on GpuSensorMixin` — the composing class (`LinuxSensorService`) must
/// mix in `GpuSensorMixin` before this one. Split out of the former
/// single `LinuxSensorService` god-file — see `linux_sensor_service.dart`
/// for how the domain mixins are composed.
mixin SystemInfoSensorMixin on GpuSensorMixin {
  Future<SystemInfoSample> readSystemInfo() async {
    try {
      final hostname = Platform.localHostname;

      String osName = 'Linux';
      try {
        final osRelease = await File('/etc/os-release').readAsString();
        final match = RegExp(r'PRETTY_NAME="?([^"\n]+)"?').firstMatch(osRelease);
        if (match != null) osName = match.group(1)!.trim();
      } catch (_) {
        // fall back to the "Linux" default above
      }

      String kernelVersion = 'onbekend';
      try {
        kernelVersion = (await File('/proc/sys/kernel/osrelease').readAsString()).trim();
      } catch (_) {}

      final architecture = await _readUname('-m') ?? 'onbekend';

      Duration uptime = Duration.zero;
      try {
        final uptimeContent = await File('/proc/uptime').readAsString();
        final seconds = double.tryParse(uptimeContent.trim().split(' ').first);
        if (seconds != null) uptime = Duration(seconds: seconds.round());
      } catch (_) {}

      String cpuModel = 'onbekend';
      var cpuCores = 0;
      try {
        final cpuinfo = await File('/proc/cpuinfo').readAsString();
        final modelMatch = RegExp(r'model name\s*:\s*(.+)').firstMatch(cpuinfo);
        if (modelMatch != null) cpuModel = modelMatch.group(1)!.trim();
        cpuCores = RegExp(r'^processor\s*:', multiLine: true).allMatches(cpuinfo).length;
      } catch (_) {}

      var totalMemoryGiB = 0.0;
      try {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemTotal:\s*(\d+)').firstMatch(meminfo);
        if (match != null) {
          totalMemoryGiB = (int.parse(match.group(1)!)) / 1048576; // KiB -> GiB
        }
      } catch (_) {}

      final gpuNames = <String>[];
      try {
        final gpus = await readGpus();
        gpuNames.addAll(gpus.map((g) => g.name));
      } catch (_) {}

      // DMI hardware identity — commonly world-readable, but some
      // distros restrict even these to root, so each read is
      // independently best-effort.
      final systemVendor = await _readDmiField('sys_vendor');
      final systemModel = await _readDmiField('product_name');
      final biosVersion = await _readDmiField('bios_version');
      final biosDate = await _readDmiField('bios_date');

      // Desktop environment / display server / shell / locale all come
      // from the environment this process inherited from the desktop
      // session that launched it.
      final env = Platform.environment;
      final desktopEnvironment = env['XDG_CURRENT_DESKTOP'] ?? env['DESKTOP_SESSION'];
      String? displayServer;
      final sessionType = env['XDG_SESSION_TYPE']?.toLowerCase();
      if (sessionType == 'wayland') {
        displayServer = 'Wayland';
      } else if (sessionType == 'x11') {
        displayServer = 'X11';
      }
      final shell = env['SHELL'];
      final locale = env['LANG'];

      return SystemInfoSample(
        hostname: hostname,
        osName: osName,
        kernelVersion: kernelVersion,
        architecture: architecture,
        uptime: uptime,
        cpuModel: cpuModel,
        cpuCores: cpuCores,
        totalMemoryGiB: totalMemoryGiB,
        gpuNames: gpuNames,
        systemVendor: systemVendor,
        systemModel: systemModel,
        biosVersion: biosVersion,
        biosDate: biosDate,
        desktopEnvironment: desktopEnvironment,
        displayServer: displayServer,
        shell: shell,
        locale: locale,
      );
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read system info: $e\n$st');
      return SystemInfoSample.unknown();
    }
  }

  Future<String?> _readDmiField(String fieldName) async {
    try {
      final content = (await File('/sys/class/dmi/id/$fieldName').readAsString()).trim();
      return content.isEmpty ? null : content;
    } catch (_) {
      return null; // often permission-denied or absent on VMs/some hardware — expected
    }
  }

  Future<String?> _readUname(String flag) async {
    try {
      final result = await Process.run('uname', [flag]);
      if (result.exitCode != 0) return null;
      return (result.stdout as String).trim();
    } catch (_) {
      return null;
    }
  }
}
