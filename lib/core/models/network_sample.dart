/// Broad category of a network interface, used to prioritize showing
/// real physical connections (Ethernet, WiFi) over virtual ones
/// (Docker bridges, VPN tunnels, etc.) on the dashboard.
enum NetworkInterfaceType { ethernet, wifi, other }

/// A single point-in-time throughput reading for one network interface.
/// Rates are bytes/sec, computed by diffing two /proc/net/dev snapshots —
/// the first reading for an interface has no prior snapshot to diff
/// against, so its rates are 0 until the next poll.
class NetworkSample {
  final String interfaceName;
  final NetworkInterfaceType type;
  final double rxBytesPerSec;
  final double txBytesPerSec;
  final int totalRxBytes;
  final int totalTxBytes;

  const NetworkSample({
    required this.interfaceName,
    required this.type,
    required this.rxBytesPerSec,
    required this.txBytesPerSec,
    required this.totalRxBytes,
    required this.totalTxBytes,
  });
}
