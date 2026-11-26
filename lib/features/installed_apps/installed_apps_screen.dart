import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/installed_app.dart';
import '../../core/models/uninstall_plan.dart';
import '../../services/installed_apps_service.dart';

class InstalledAppsScreen extends StatefulWidget {
  const InstalledAppsScreen({super.key});

  @override
  State<InstalledAppsScreen> createState() => _InstalledAppsScreenState();
}

class _InstalledAppsScreenState extends State<InstalledAppsScreen> {
  final InstalledAppsService _service = InstalledAppsService();
  List<InstalledApp> _apps = [];
  bool _loading = true;
  String _filter = '';
  final Set<String> _resolvingUninstall = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final apps = await _service.listApps();
    if (mounted) {
      setState(() {
        _apps = apps;
        _loading = false;
      });
    }

    // Icons are resolved as a genuinely separate, later step on
    // Windows — see InstalledAppsService.extractIconsWindows's own
    // doc for why. The list itself is already visible and usable by
    // the time this runs; icons simply appear once each is ready,
    // rather than the whole screen waiting on all of them first.
    if (Platform.isWindows && apps.isNotEmpty) {
      final iconPaths = await _service.extractIconsWindows(apps);
      if (mounted && iconPaths.isNotEmpty) {
        setState(() {
          _apps = _apps
              .map((app) => iconPaths.containsKey(app.filePath) ? app.withResolvedIconPath(iconPaths[app.filePath]) : app)
              .toList();
        });
      }
    }
  }

  String _sourceLabel(AppSource source) {
    switch (source) {
      case AppSource.system:
        return 'Systeem';
      case AppSource.user:
        return 'Gebruiker';
      case AppSource.flatpak:
        return 'Flatpak';
      case AppSource.snap:
        return 'Snap';
    }
  }

  Color _sourceColor(AppSource source) {
    switch (source) {
      case AppSource.system:
        return Colors.grey;
      case AppSource.user:
        return Colors.cyanAccent;
      case AppSource.flatpak:
        return Colors.blueAccent;
      case AppSource.snap:
        return Colors.orangeAccent;
    }
  }

  Future<void> _startUninstall(InstalledApp app) async {
    setState(() => _resolvingUninstall.add(app.filePath));
    final plan = await _service.resolveUninstallPlan(app);
    if (!mounted) return;
    setState(() => _resolvingUninstall.remove(app.filePath));

    if (plan.method == UninstallMethod.unknown) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kon geen pakket vinden dat bij "${app.name}" hoort — niet verwijderd.')),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('"${app.name}" verwijderen?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (plan.method == UninstallMethod.systemPackage) ...[
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Dit is een systeempakket. Verwijderen kan ook afhankelijke pakketten meenemen.',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (plan.method == UninstallMethod.windowsUninstaller) ...[
              Row(
                children: [
                  Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Dit start het eigen uninstall-programma van deze app — dat kan mogelijk nog een '
                      'eigen venster of vraag tonen.',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            const Text('Dit commando wordt uitgevoerd:'),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                // Was Colors.black.withOpacity(0.3) — reads as a muddy
                // grey box in light mode instead of a code block. This
                // reads as "recessed surface" correctly in either mode.
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                plan.displayCommand ?? '(onbekend)',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuleren')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verwijderen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _resolvingUninstall.add(app.filePath));
    final result = await _service.executeUninstall(app, plan);
    if (!mounted) return;
    setState(() => _resolvingUninstall.remove(app.filePath));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? '"${app.name}" verwijderd'
              : 'Verwijderen mislukt: ${result.message.isNotEmpty ? result.message : 'zie het Log-tabblad'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    if (result.success) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final filtered = _apps.where((a) {
      if (_filter.isEmpty) return true;
      final q = _filter.toLowerCase();
      return a.name.toLowerCase().contains(q) || (a.comment?.toLowerCase().contains(q) ?? false);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Installed Apps', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
          const SizedBox(height: 4),
          Text('${_apps.length} toepassingen gevonden', style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5)),
          const SizedBox(height: 10),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Zoek op naam of omschrijving...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text('Geen toepassingen gevonden', style: TextStyle(color: Colors.grey.shade600)),
                  )
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 3.0,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) => _buildAppTile(filtered[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppIcon(InstalledApp app, Color sourceColor) {
    if (app.resolvedIconPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(app.resolvedIconPath!),
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          // If the file turns out unreadable/corrupt despite existing,
          // fall back to the generic icon rather than showing a broken
          // image glyph.
          errorBuilder: (context, error, stackTrace) => Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: sourceColor.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.apps, size: 18, color: sourceColor),
          ),
        ),
      );
    }
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(color: sourceColor.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
      child: Icon(Icons.apps, size: 18, color: sourceColor),
    );
  }

  Widget _buildAppTile(InstalledApp app) {
    final sourceColor = _sourceColor(app.source);
    final busy = _resolvingUninstall.contains(app.filePath);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.withOpacity(0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAppIcon(app, sourceColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (app.comment != null)
                  Text(
                    app.comment!,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 3),
                Text(
                  _sourceLabel(app.source),
                  style: TextStyle(fontSize: 10, color: sourceColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Verwijderen',
                  onPressed: () => _startUninstall(app),
                ),
        ],
      ),
    );
  }
}
