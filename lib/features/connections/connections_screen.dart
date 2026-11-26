import 'package:flutter/material.dart';

import '../../core/models/network_connection.dart';
import '../../services/connections_service.dart';

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  final ConnectionsService _service = ConnectionsService();
  List<NetworkConnection> _connections = [];
  bool _loading = true;
  bool _ssAvailable = true;
  String _filter = '';
  String _protocolFilter = 'all'; // all / tcp / udp
  bool _onlyEstablished = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final ssOk = await _service.isSsAvailable();
    final connections = ssOk ? await _service.listConnections() : <NetworkConnection>[];
    if (mounted) {
      setState(() {
        _ssAvailable = ssOk;
        _connections = connections;
        _loading = false;
      });
    }
  }

  Color _stateColor(String state) {
    switch (state) {
      case 'ESTAB':
        return Colors.greenAccent;
      case 'LISTEN':
        return Colors.lightBlueAccent;
      case 'TIME-WAIT':
      case 'CLOSE-WAIT':
        return Colors.orangeAccent;
      case 'UNCONN':
        return Colors.grey;
      default:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_ssAvailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lan_outlined, size: 48, color: Colors.grey.shade600),
              const SizedBox(height: 12),
              Text('ss niet gevonden op dit systeem', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 15)),
              const SizedBox(height: 4),
              Text(
                'Installeer het iproute2-pakket (bevat ss) om verbindingen te zien.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _connections.where((c) {
      if (_protocolFilter != 'all' && c.protocol != _protocolFilter) return false;
      if (_onlyEstablished && c.state != 'ESTAB') return false;
      if (_filter.isEmpty) return true;
      final q = _filter.toLowerCase();
      return (c.processName?.toLowerCase().contains(q) ?? false) ||
          c.localAddress.toLowerCase().contains(q) ||
          c.peerAddress.toLowerCase().contains(q) ||
          c.localPort.contains(q) ||
          c.peerPort.contains(q);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Connections', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Filter op proces, adres of poort...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              const SizedBox(width: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('Alle')),
                  ButtonSegment(value: 'tcp', label: Text('TCP')),
                  ButtonSegment(value: 'udp', label: Text('UDP')),
                ],
                selected: {_protocolFilter},
                onSelectionChanged: (s) => setState(() => _protocolFilter = s.first),
              ),
              const SizedBox(width: 10),
              FilterChip(
                label: const Text('Alleen actief'),
                selected: _onlyEstablished,
                onSelected: (v) => setState(() => _onlyEstablished = v),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${filtered.length} van ${_connections.length} verbindingen',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: const [
                SizedBox(width: 50, child: Text('Proto', style: _headerStyle)),
                SizedBox(width: 90, child: Text('Status', style: _headerStyle)),
                Expanded(flex: 3, child: Text('Lokaal', style: _headerStyle)),
                Expanded(flex: 3, child: Text('Extern', style: _headerStyle)),
                Expanded(flex: 2, child: Text('Proces', style: _headerStyle)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) => _buildRow(filtered[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(NetworkConnection c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(c.protocol.toUpperCase(), style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 90,
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: _stateColor(c.state), shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(c.state, style: const TextStyle(fontSize: 11.5), overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text('${c.localAddress}:${c.localPort}',
                style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 3,
            child: Text('${c.peerAddress}:${c.peerPort}',
                style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text(
              c.processName != null ? '${c.processName} (${c.pid})' : '—',
              style: TextStyle(fontSize: 12, color: c.processName != null ? null : Colors.grey.shade600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

const _headerStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey);
