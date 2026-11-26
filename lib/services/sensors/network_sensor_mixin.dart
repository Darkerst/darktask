import 'dart:collection';
import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/models/network_sample.dart';

const _logSource = 'LinuxSensorService';

/// Cumulative rx/tx byte counters for one network interface at a point
/// in time — used internally by [NetworkSensorMixin.readNetwork] to
/// diff two snapshots into a rate.
class _NetCounters {
  final int rxBytes;
  final int txBytes;
  const _NetCounters({required this.rxBytes, required this.txBytes});
}

/// Network-related reads: per-interface throughput via /proc/net/dev
/// diffing, with Ethernet/WiFi/other classification via sysfs.
///
/// Split out of the former single `LinuxSensorService` god-file — see
/// `linux_sensor_service.dart` for how the domain mixins are composed.
mixin NetworkSensorMixin {
  Map<String, _NetCounters>? _prevNetCounters;
  DateTime? _prevNetSampleTime;
  // Short rolling history of recent rate samples per interface, used to
  // smooth out single-second jitter (bursty traffic can make one raw
  // sample look misleadingly high or low) into a steadier, more
  // representative number.
  final Map<String, Queue<double>> _recentRxRates = {};
  final Map<String, Queue<double>> _recentTxRates = {};
  static const _netSmoothingWindow = 3;

  /// Network interfaces to skip — loopback and common virtual interfaces
  /// (Docker bridges, veth pairs) that aren't useful on a dashboard
  /// meant to show real network activity.
  static const _networkInterfaceBlacklist = {'lo'};
  static final _virtualInterfacePrefixes = ['docker', 'veth', 'br-', 'virbr'];

  /// Classifies an interface as Ethernet, WiFi, or other/virtual using
  /// sysfs: a `wireless` or `phy80211` subdirectory under
  /// /sys/class/net/<iface>/ means WiFi; a `device` symlink (pointing to
  /// a real PCI/USB bus entry) without those means a physical Ethernet
  /// adapter; anything else (virtual interfaces have no `device` link
  /// at all) is "other".
  Future<NetworkInterfaceType> _classifyInterface(String name) async {
    final base = '/sys/class/net/$name';
    try {
      if (await Directory('$base/wireless').exists()) return NetworkInterfaceType.wifi;
      if (await Directory('$base/phy80211').exists()) return NetworkInterfaceType.wifi;
      if (await FileSystemEntity.isLink('$base/device') ||
          await File('$base/device').exists() ||
          await Directory('$base/device').exists()) {
        return NetworkInterfaceType.ethernet;
      }
    } catch (_) {
      // fall through to "other" below
    }
    return NetworkInterfaceType.other;
  }

  /// Reads per-interface network throughput by diffing two /proc/net/dev
  /// snapshots — same diffing approach as the CPU load reader. The first
  /// call has no prior snapshot, so every interface reports 0 bytes/sec
  /// until the next poll. Rates are smoothed over the last few samples
  /// per interface to reduce single-second jitter.
  Future<List<NetworkSample>> readNetwork() async {
    try {
      final lines = await File('/proc/net/dev').readAsLines();
      final now = DateTime.now();
      final current = <String, _NetCounters>{};

      // First two lines are headers ("Inter-|   Receive ..." and
      // " face |bytes    packets ...").
      for (final line in lines.skip(2)) {
        final colonIndex = line.indexOf(':');
        if (colonIndex == -1) continue;
        final name = line.substring(0, colonIndex).trim();
        if (_networkInterfaceBlacklist.contains(name)) continue;
        if (_virtualInterfacePrefixes.any((p) => name.startsWith(p))) continue;

        final fields = line.substring(colonIndex + 1).trim().split(RegExp(r'\s+'));
        if (fields.length < 9) continue;

        final rxBytes = int.tryParse(fields[0]);
        final txBytes = int.tryParse(fields[8]);
        if (rxBytes == null || txBytes == null) continue;

        current[name] = _NetCounters(rxBytes: rxBytes, txBytes: txBytes);
      }

      final prev = _prevNetCounters;
      final prevTime = _prevNetSampleTime;
      _prevNetCounters = current;
      _prevNetSampleTime = now;

      final samples = <NetworkSample>[];
      for (final entry in current.entries) {
        final prevCounters = prev?[entry.key];
        double rxRate = 0;
        double txRate = 0;

        if (prevCounters != null && prevTime != null) {
          final elapsedSec = now.difference(prevTime).inMicroseconds / 1e6;
          if (elapsedSec > 0) {
            final rxDelta = entry.value.rxBytes - prevCounters.rxBytes;
            final txDelta = entry.value.txBytes - prevCounters.txBytes;
            // A negative delta means the counter reset (interface went
            // down/up) — treat as 0 for this interval rather than
            // showing a nonsensical negative rate.
            rxRate = rxDelta >= 0 ? rxDelta / elapsedSec : 0;
            txRate = txDelta >= 0 ? txDelta / elapsedSec : 0;
          }
        }

        final rxHistory = _recentRxRates.putIfAbsent(entry.key, () => Queue<double>());
        final txHistory = _recentTxRates.putIfAbsent(entry.key, () => Queue<double>());
        rxHistory.addLast(rxRate);
        txHistory.addLast(txRate);
        if (rxHistory.length > _netSmoothingWindow) rxHistory.removeFirst();
        if (txHistory.length > _netSmoothingWindow) txHistory.removeFirst();
        final smoothedRx = rxHistory.reduce((a, b) => a + b) / rxHistory.length;
        final smoothedTx = txHistory.reduce((a, b) => a + b) / txHistory.length;

        final type = await _classifyInterface(entry.key);

        samples.add(NetworkSample(
          interfaceName: entry.key,
          type: type,
          rxBytesPerSec: smoothedRx,
          txBytesPerSec: smoothedTx,
          totalRxBytes: entry.value.rxBytes,
          totalTxBytes: entry.value.txBytes,
        ));
      }

      // Physical connections (Ethernet, then WiFi) come before "other"
      // (virtual interfaces that slipped past the blacklist). Within
      // "physical", an interface that's actually carrying traffic right
      // now sorts first — not a fixed Ethernet-before-WiFi rule
      // regardless of activity, which would permanently hide an active
      // WiFi connection behind an idle/unplugged Ethernet port (a very
      // common laptop setup). Ethernet-before-WiFi is still used, but
      // only as the tie-breaker when both are currently idle, so the
      // "primary" interface doesn't flicker between polls when nothing
      // is happening on either.
      samples.sort((a, b) {
        final aPhysical = a.type != NetworkInterfaceType.other;
        final bPhysical = b.type != NetworkInterfaceType.other;
        if (aPhysical != bPhysical) return aPhysical ? -1 : 1;

        final aTotal = a.rxBytesPerSec + a.txBytesPerSec;
        final bTotal = b.rxBytesPerSec + b.txBytesPerSec;
        if (aTotal > 0 || bTotal > 0) {
          return bTotal.compareTo(aTotal);
        }
        if (a.type != b.type) {
          return a.type == NetworkInterfaceType.ethernet ? -1 : 1;
        }
        return 0;
      });
      return samples;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'Failed to read network stats: $e\n$st');
      return [];
    }
  }
}
