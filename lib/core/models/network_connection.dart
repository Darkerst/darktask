/// A single network connection/socket, from `ss -tunap`.
class NetworkConnection {
  final String protocol; // tcp / udp
  final String state; // ESTAB / LISTEN / TIME-WAIT / UNCONN / ...
  final String localAddress;
  final String localPort;
  final String peerAddress;
  final String peerPort;
  final String? processName;
  final int? pid;

  const NetworkConnection({
    required this.protocol,
    required this.state,
    required this.localAddress,
    required this.localPort,
    required this.peerAddress,
    required this.peerPort,
    this.processName,
    this.pid,
  });
}
