/// CPU frequency scaling + battery/power info for the Power & Freq
/// screen. Fields are nullable/empty when the underlying sysfs path
/// isn't present (e.g. no cpufreq driver, no battery on a desktop) —
/// left unset rather than guessed, same convention as the rest of the
/// app's sensor readers.
class PowerFreqSample {
  final List<double?> perCoreFrequencyMHz;
  final double? minFreqMHz;
  final double? maxFreqMHz;
  final String? governor;
  final List<String> availableGovernors;
  final bool? turboEnabled;
  final String? frequencyDriver;

  // Battery (absent entirely on most desktops)
  final bool hasBattery;
  final double? batteryPercent;
  final String? batteryStatus; // Charging / Discharging / Full / Not charging
  final bool? acOnline;

  const PowerFreqSample({
    this.perCoreFrequencyMHz = const [],
    this.minFreqMHz,
    this.maxFreqMHz,
    this.governor,
    this.availableGovernors = const [],
    this.turboEnabled,
    this.frequencyDriver,
    this.hasBattery = false,
    this.batteryPercent,
    this.batteryStatus,
    this.acOnline,
  });
}
