import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';

/// Shows the full, live app log (everything every service writes via
/// [AppLogger]) with a one-tap copy button so the whole thing can be
/// pasted elsewhere — e.g. shared for debugging.
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final ScrollController _scrollController = ScrollController();
  LogLevel? _minLevel;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    AppLogger.instance.addListener(_onNewEntry);
  }

  @override
  void dispose() {
    AppLogger.instance.removeListener(_onNewEntry);
    _scrollController.dispose();
    super.dispose();
  }

  void _onNewEntry(LogEntry entry) {
    if (!mounted) return;
    setState(() {});
    // Auto-scroll to the newest entry once the frame is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _copyAll() async {
    final text = AppLogger.instance.exportAsText();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Log gekopieerd (${AppLogger.instance.entries.length} regels)'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _saveToFile() async {
    setState(() => _saving = true);
    try {
      final text = AppLogger.instance.exportAsText();
      final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final fileName = 'darktask_log_$timestamp.txt';

      // Prefer Downloads (most discoverable for a manually-saved log);
      // fall back to the app's documents directory if the platform
      // doesn't expose a Downloads folder.
      Directory? targetDir;
      try {
        targetDir = await getDownloadsDirectory();
      } catch (_) {
        targetDir = null;
      }
      targetDir ??= await getApplicationDocumentsDirectory();

      final file = File('${targetDir.path}/$fileName');
      await file.writeAsString(text);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Log opgeslagen: ${file.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      AppLogger.instance.error('LogViewerScreen', 'Kon log niet opslaan: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Opslaan mislukt: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _clearLog() {
    AppLogger.instance.clear();
    setState(() {});
  }

  Color _colorForLevel(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey.shade500;
      case LogLevel.info:
        return Colors.lightBlueAccent;
      case LogLevel.warning:
        return Colors.orangeAccent;
      case LogLevel.error:
        return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = AppLogger.instance.entries
        .where((e) => _minLevel == null || e.level.index >= _minLevel!.index)
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Text(
                '${entries.length} regels',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              ),
              const Spacer(),
              DropdownButton<LogLevel?>(
                value: _minLevel,
                hint: const Text('Alle niveaus'),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Alle niveaus')),
                  DropdownMenuItem(value: LogLevel.debug, child: Text('Debug en hoger')),
                  DropdownMenuItem(value: LogLevel.info, child: Text('Info en hoger')),
                  DropdownMenuItem(value: LogLevel.warning, child: Text('Warning en hoger')),
                  DropdownMenuItem(value: LogLevel.error, child: Text('Alleen errors')),
                ],
                onChanged: (v) => setState(() => _minLevel = v),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Log wissen',
                onPressed: _clearLog,
              ),
              OutlinedButton.icon(
                onPressed: _saving ? null : _saveToFile,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_alt, size: 18),
                label: Text(_saving ? 'Bezig...' : 'Opslaan'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _copyAll,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Kopieer alles'),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'Nog geen log-regels',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                          children: [
                            TextSpan(
                              text: '[${entry.levelLabel}] ',
                              style: TextStyle(
                                color: _colorForLevel(entry.level),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(
                              text: '[${entry.source}] ',
                              style: TextStyle(color: Colors.grey.shade500),
                            ),
                            TextSpan(
                              text: entry.message,
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
