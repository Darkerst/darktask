import 'package:flutter/material.dart';

/// One row inside an [InfoListCard].
class InfoListRow {
  final String label;
  final String value;
  final String? subValue;
  final double? progress; // 0.0–1.0, shown as a thin bar if provided

  const InfoListRow({
    required this.label,
    required this.value,
    this.subValue,
    this.progress,
  });
}

/// A compact card listing several rows of stats under one title — used
/// for disks and network interfaces, where there can be more than one
/// and a single big-number StatCard doesn't fit the shape of the data.
class InfoListCard extends StatelessWidget {
  final String title;
  final List<InfoListRow> rows;
  final Color accentColor;
  final String emptyMessage;

  const InfoListCard({
    super.key,
    required this.title,
    required this.rows,
    required this.accentColor,
    this.emptyMessage = 'Geen gegevens beschikbaar',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyMessage,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
            )
          else
            for (final row in rows) _buildRow(row),
        ],
      ),
    );
  }

  Widget _buildRow(InfoListRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                row.value,
                style: TextStyle(fontSize: 13, color: accentColor, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (row.subValue != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                row.subValue!,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
              ),
            ),
          if (row.progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: row.progress!.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: accentColor.withOpacity(0.12),
                  valueColor: AlwaysStoppedAnimation(accentColor),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
