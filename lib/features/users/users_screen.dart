import 'package:flutter/material.dart';

import '../../core/models/user_session.dart';
import '../../services/users_service.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final UsersService _service = UsersService();
  List<UserSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final sessions = await _service.listSessions();
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Users', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_sessions.length} actieve sessie(s)',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          if (_sessions.isEmpty)
            Expanded(
              child: Center(
                child: Text('Geen ingelogde gebruikers gevonden', style: TextStyle(color: Colors.grey.shade600)),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => _buildSessionTile(_sessions[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionTile(UserSession s) {
    final memoryMiB = s.memoryKiB / 1024;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.cyanAccent.withOpacity(0.15),
        child: Text(
          s.username.isNotEmpty ? s.username[0].toUpperCase() : '?',
          style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.w700),
        ),
      ),
      title: Text(s.username, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        'Terminal ${s.terminal} · ingelogd sinds ${s.loginTime}'
        '${s.host != null ? ' · ${s.host}' : ''}'
        '${s.idle != null && s.idle != '.' ? ' · inactief ${s.idle}' : ''}',
        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${s.processCount} processen', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          Text(
            '${s.cpuPercent.toStringAsFixed(1)}% CPU · ${memoryMiB.toStringAsFixed(0)} MiB',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}
