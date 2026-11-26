/// A point-in-time battery reading. Absent (not just "unknown") on
/// desktops and most servers, which is the common case this app runs
/// on — [present] lets callers distinguish "no battery in this
/// machine" from "battery present but a read failed".
class BatterySample {
  final bool present;
  final int? capacityPercent;
  final String? status; // "Charging", "Discharging", "Full", "Not charging", etc.

  /// Design capacity (the battery's rated capacity when new) and
  /// current full-charge capacity (what it can actually hold now),
  /// both in mWh — the standard way battery wear/health is measured on
  /// both platforms. Null when unavailable rather than guessed at;
  /// [healthPercent] is null whenever either of these is, since a
  /// health percentage computed from a missing value would be
  /// meaningless.
  final double? designCapacityMWh;
  final double? fullChargeCapacityMWh;

  /// Number of full charge/discharge cycles the battery has been
  /// through — the standard, vendor-independent "how much has this
  /// battery been used" figure every OS's own battery report uses
  /// (there's no reliable "hours in use" that either platform tracks
  /// directly; cycle count is the metric both actually expose).
  final int? cycleCount;

  const BatterySample({
    required this.present,
    this.capacityPercent,
    this.status,
    this.designCapacityMWh,
    this.fullChargeCapacityMWh,
    this.cycleCount,
  });

  factory BatterySample.absent() => const BatterySample(present: false);

  bool get isDischarging => status?.toLowerCase() == 'discharging';

  /// How much of the battery's original capacity it can still hold,
  /// 0-100 — the standard "battery health" figure every OS/vendor
  /// battery-health tool reports, not something this app invented.
  /// Naturally settles below 100 over a battery's life as it wears;
  /// null (not a fabricated number) when either capacity reading
  /// isn't available.
  double? get healthPercent {
    final design = designCapacityMWh;
    final full = fullChargeCapacityMWh;
    if (design == null || full == null || design <= 0) return null;
    return (full / design * 100).clamp(0, 100);
  }
}
