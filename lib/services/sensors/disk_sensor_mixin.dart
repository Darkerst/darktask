import 'dart:convert';
import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/disk_health_info.dart';
import '../../core/models/disk_sample.dart';

const _logSource = 'LinuxSensorService';

/// Disk-related reads: mounted filesystem space usage (via `df`) and
/// system-wide disk I/O "busy" activity (via /proc/diskstats).
///
/// Split out of the former single `LinuxSensorService` god-file — see
/// `linux_sensor_service.dart` for how the domain mixins are composed.
mixin DiskSensorMixin {
  /// Filesystem types to skip when listing disks — pseudo/virtual
  /// filesystems that don't represent real storage the user cares about
  /// (RAM-backed, kernel interfaces, container overlay layers, etc.).
  static const _diskFsTypeBlacklist = {
    'tmpfs', 'devtmpfs', 'squashfs', 'overlay', 'proc', 'sysfs', 'cgroup',
    'cgroup2', 'tracefs', 'debugfs', 'configfs', 'fusectl', 'hugetlbfs',
    'mqueue', 'pstore', 'securityfs', 'autofs', 'binfmt_misc', 'nsfs',
    'devpts', 'ramfs', 'efivarfs', 'bpf',
  };

  /// Reads mounted filesystems and their space usage via `df`. Filters
  /// out pseudo-filesystems (tmpfs, proc, overlay, snap squashfs mounts,
  /// etc.) so the list only shows storage the user would recognize.
  Future<List<DiskSample>> readDisks() async {
    try {
      final result = await Process.run(
        'df',
        ['-B1', '--output=source,fstype,size,used,avail,target'],
      );

      if (result.exitCode != 0) {
        AppLogger.instance.error(_logSource, 'df exited with ${result.exitCode}: ${result.stderr}');
        return [];
      }

      final lines = (result.stdout as String)
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .skip(1); // header row

      final disks = <DiskSample>[];
      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 6) continue;

        final device = parts[0];
        final fsType = parts[1];
        if (_diskFsTypeBlacklist.contains(fsType)) continue;
        // Snap packages mount their own squashfs mostly caught above,
        // but also skip loop devices (snap/flatpak backing stores) by
        // device name as a second filter, since some report a
        // non-blacklisted fsType.
        if (device.startsWith('/dev/loop')) continue;

        final total = int.tryParse(parts[2]);
        final used = int.tryParse(parts[3]);
        final avail = int.tryParse(parts[4]);
        if (total == null || used == null || avail == null) continue;
        if (total == 0) continue; // skip zero-size virtual mounts

        // Mount point is everything from field 6 onward, rejoined —
        // in the rare case it contains spaces, `df`'s whitespace-based
        // columns would otherwise truncate it.
        final mountPoint = parts.sublist(5).join(' ');

        disks.add(DiskSample(
          device: device,
          fsType: fsType,
          mountPoint: mountPoint,
          totalBytes: total,
          usedBytes: used,
          availableBytes: avail,
        ));
      }
      return disks;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read disk usage: $e\n$st');
      return [];
    }
  }

  Map<String, int>? _prevDiskIoMs;
  DateTime? _prevDiskIoSampleTime;

  /// Real block devices to sum for system-wide I/O activity — excludes
  /// partitions (we want the whole-disk line, which already aggregates
  /// its partitions' I/O in the kernel's accounting), loop devices, and
  /// device-mapper/ram devices.
  static final _diskActivityDeviceRegex = RegExp(r'^(sd[a-z]+|nvme\d+n\d+|vd[a-z]+|mmcblk\d+)$');

  /// Reads system-wide disk I/O activity as a 0-100% "busy" figure —
  /// the fraction of wall-clock time real block devices spent actively
  /// doing I/O, via /proc/diskstats field 13 (ms spent doing I/Os,
  /// cumulative), diffed the same way as the network byte counters.
  /// This is a genuinely different metric from disk *space* usage (see
  /// [readDisks]) — matches what system monitors like TMOG label
  /// "Disk" in their compact stat cards.
  Future<double?> readDiskActivity() async {
    try {
      final lines = await File('/proc/diskstats').readAsLines();
      final now = DateTime.now();
      final current = <String, int>{};

      for (final line in lines) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 13) continue;
        final name = fields[2];
        if (!_diskActivityDeviceRegex.hasMatch(name)) continue;

        final ioMs = int.tryParse(fields[12]);
        if (ioMs == null) continue;
        current[name] = ioMs;
      }

      final prev = _prevDiskIoMs;
      final prevTime = _prevDiskIoSampleTime;
      _prevDiskIoMs = current;
      _prevDiskIoSampleTime = now;

      if (prev == null || prevTime == null || current.isEmpty) return null;

      final elapsedMs = now.difference(prevTime).inMilliseconds;
      if (elapsedMs <= 0) return null;

      // Average "busy fraction" across all real devices found — each
      // device's own delta can't exceed the elapsed wall-clock time
      // (that's what "100% busy" means for that device), so summing
      // deltas and dividing by (elapsed * deviceCount) gives a fair
      // system-wide average rather than letting a busy secondary disk
      // make an idle primary disk look busier than it is.
      var totalDeltaMs = 0;
      var deviceCount = 0;
      for (final entry in current.entries) {
        final prevMs = prev[entry.key];
        if (prevMs == null) continue;
        final delta = entry.value - prevMs;
        if (delta < 0) continue; // counter reset — skip this device this interval
        totalDeltaMs += delta;
        deviceCount++;
      }
      if (deviceCount == 0) return null;

      final busyPercent = (totalDeltaMs / (elapsedMs * deviceCount)) * 100;
      return busyPercent.clamp(0, 100).toDouble();
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to read /proc/diskstats: $e');
      return null;
    }
  }

  bool? _smartctlAvailable;

  /// `smartctl` (from the smartmontools package) is the standard Linux
  /// SMART-reading tool — not installed by default on most
  /// distributions, so this is checked the same way this app already
  /// checks for optional external tools elsewhere (glmark2, etc.)
  /// rather than assumed present.
  Future<bool> isSmartctlAvailable() async {
    if (_smartctlAvailable != null) return _smartctlAvailable!;
    try {
      final result = await Process.run('smartctl', ['--version']);
      _smartctlAvailable = result.exitCode == 0;
    } catch (_) {
      _smartctlAvailable = false;
    }
    return _smartctlAvailable!;
  }

  /// SMART data via `smartctl -a -j` (JSON output, parsed as
  /// structured data rather than smartctl's human-readable text
  /// format) for every physical disk found under `/sys/block`.
  ///
  /// **Wear/health is only populated for NVMe drives.** NVMe's own
  /// spec standardizes `percentage_used` as a single 0-100 figure
  /// meaning exactly what this app's `wearPercentUsed` represents. SATA
  /// SSDs have no equivalent standard: the relevant SMART attribute ID
  /// (231, 233, or others depending on the manufacturer) and what its
  /// raw value actually means both vary enough across vendors that
  /// picking one interpretation would mean silently guessing wrong for
  /// a real fraction of drives — left null there rather than showing a
  /// number this app can't actually vouch for. Power-on hours, by
  /// contrast, is standardized enough across both NVMe and ATA/SATA
  /// SMART data to report for either.
  @override
  Future<List<DiskHealthInfo>> readDiskHealth() async {
    if (!await isSmartctlAvailable()) return [];

    try {
      final blockDir = Directory('/sys/block');
      if (!await blockDir.exists()) return [];

      final results = <DiskHealthInfo>[];
      await for (final entry in blockDir.list()) {
        final name = entry.path.split('/').last;
        // Only real physical disks — sd*/hd*/vd* (SATA/legacy/virtio)
        // and nvme*n* (NVMe namespaces, excluding the controller nodes
        // themselves like "nvme0" without a namespace suffix). Loop
        // devices, device-mapper (LVM/LUKS), md (software RAID), and
        // zram are all virtual and have no SMART data of their own to
        // report.
        final isSata = RegExp(r'^[sh]d[a-z]+$').hasMatch(name) || RegExp(r'^vd[a-z]+$').hasMatch(name);
        final isNvme = RegExp(r'^nvme\d+n\d+$').hasMatch(name);
        if (!isSata && !isNvme) continue;

        final devicePath = '/dev/$name';
        // /sys/block/<name>/queue/rotational is a reliable, standard
        // kernel-exposed flag (0 = non-rotational/SSD, 1 = spinning
        // disk) — used for SATA disks specifically, since unlike NVMe
        // (inherently solid-state by the interface itself), a SATA
        // device could be either an SSD or a traditional hard disk.
        bool? isSsd = isNvme ? true : null;
        if (isSata) {
          try {
            final rotational = (await File('${entry.path}/queue/rotational').readAsString()).trim();
            if (rotational == '0') {
              isSsd = true;
            } else if (rotational == '1') {
              isSsd = false;
            }
          } catch (_) {
            // Left null below — an honest "couldn't determine," not a guess.
          }
        }

        try {
          final result = await Process.run('smartctl', ['-a', '-j', devicePath]);
          // smartctl's own exit code is a bitmask of warning flags, not
          // a plain success/failure indicator — a non-zero code can
          // still mean "read fine, but here's a SMART warning to know
          // about," so stdout is parsed regardless of exit code rather
          // than discarded whenever it's non-zero.
          final output = (result.stdout as String).trim();
          if (output.isEmpty) continue;

          final decoded = jsonDecode(output) as Map<String, dynamic>;
          final powerOnHours = (decoded['power_on_time'] as Map<String, dynamic>?)?['hours'] as int?;
          final modelName = decoded['model_name'] as String?;
          final temperature =
              ((decoded['temperature'] as Map<String, dynamic>?)?['current'] as num?)?.toDouble();

          double? wearPercentUsed;
          if (isNvme) {
            final nvmeLog = decoded['nvme_smart_health_information_log'] as Map<String, dynamic>?;
            wearPercentUsed = (nvmeLog?['percentage_used'] as num?)?.toDouble();
          }

          results.add(DiskHealthInfo(
            deviceId: devicePath,
            model: modelName,
            isSsd: isSsd,
            powerOnHours: powerOnHours,
            wearPercentUsed: wearPercentUsed,
            temperatureC: temperature,
          ));
        } catch (e) {
          AppLogger.instance.debug(_logSource, 'smartctl failed for $devicePath: $e');
        }
      }
      return results;
    } catch (e, st) {
      AppLogger.instance.debug(_logSource, 'Failed to read disk health: $e\n$st');
      return [];
    }
  }
}
