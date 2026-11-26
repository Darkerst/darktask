/// SMART/reliability data for one physical disk — distinct from
/// [DiskSample], which is about filesystem *space usage* on a mounted
/// volume. A single physical disk can hold multiple filesystems (or
/// none, if unpartitioned), so these two models deliberately don't
/// share an identity key the app can rely on to join them precisely;
/// this is presented as its own, separate view rather than merged
/// into the disk-space list.
class DiskHealthInfo {
  final String deviceId; // e.g. "\\\\.\\PhysicalDrive0" (Windows) or "/dev/sda" (Linux)
  final String? model;
  final bool? isSsd;

  /// Total hours the drive has been powered on since manufacture — the
  /// closest available concept to "usage duration" for a drive, since
  /// neither platform tracks wall-clock "time in the machine" the way
  /// a warranty period does.
  final int? powerOnHours;

  /// How much of the drive's rated write endurance has been consumed,
  /// 0-100 — the standard SSD wear/health figure (0 = brand new, 100 =
  /// rated endurance fully used, though most SSDs remain functional
  /// somewhat past that point). Not meaningful for a spinning hard
  /// disk, which wears mechanically rather than by write count; null
  /// there rather than a fabricated number.
  final double? wearPercentUsed;

  final double? temperatureC;

  const DiskHealthInfo({
    required this.deviceId,
    this.model,
    this.isSsd,
    this.powerOnHours,
    this.wearPercentUsed,
    this.temperatureC,
  });

  double? get powerOnDays => powerOnHours != null ? powerOnHours! / 24 : null;

  /// Remaining life, 0-100 — the inverse framing of [wearPercentUsed]
  /// that most people actually want to see ("how much is left," not
  /// "how much is gone"). Null under the exact same conditions
  /// [wearPercentUsed] is.
  double? get lifeRemainingPercent => wearPercentUsed != null ? (100 - wearPercentUsed!).clamp(0, 100) : null;

  /// Whether this entry actually carries any real health figure —
  /// distinct from merely existing in the result list. A disk behind a
  /// RAID/storage controller that doesn't pass SMART data through
  /// still produces an entry (device ID, model, a temperature that may
  /// itself be a placeholder) with every genuinely useful field left
  /// null — checking list *presence* alone would treat that as "health
  /// data is available" when there's nothing to actually show.
  bool get hasMeaningfulData => powerOnHours != null || wearPercentUsed != null;
}

extension DiskHealthInfoListX on List<DiskHealthInfo> {
  /// True only if at least one entry has a real figure to show — see
  /// [DiskHealthInfo.hasMeaningfulData]. Use this instead of `isEmpty`/
  /// `isNotEmpty` wherever "is there anything worth displaying" is the
  /// actual question, since a non-empty list of placeholder-only
  /// entries answers that question incorrectly.
  bool get hasAnyMeaningfulData => any((d) => d.hasMeaningfulData);
}
