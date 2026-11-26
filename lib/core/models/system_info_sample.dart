/// Static (or slow-changing) system information — hostname, OS,
/// kernel, hardware, and desktop-environment details. Read once per
/// screen visit rather than polled every second, since none of this
/// changes second to second. Fields are nullable/left as "onbekend"
/// (rather than guessed) when the underlying source isn't readable —
/// e.g. some DMI fields require root on some distros.
class SystemInfoSample {
  final String hostname;
  final String osName;
  final String kernelVersion;
  final String architecture;
  final Duration uptime;
  final String cpuModel;
  final int cpuCores;
  final double totalMemoryGiB;
  final List<String> gpuNames;

  // Hardware (DMI — /sys/class/dmi/id/*)
  final String? systemVendor;
  final String? systemModel;
  final String? biosVersion;
  final String? biosDate;

  // Software environment
  final String? desktopEnvironment;
  final String? displayServer; // "Wayland" / "X11" / null
  final String? shell;
  final String? locale;

  const SystemInfoSample({
    required this.hostname,
    required this.osName,
    required this.kernelVersion,
    required this.architecture,
    required this.uptime,
    required this.cpuModel,
    required this.cpuCores,
    this.totalMemoryGiB = 0,
    this.gpuNames = const [],
    this.systemVendor,
    this.systemModel,
    this.biosVersion,
    this.biosDate,
    this.desktopEnvironment,
    this.displayServer,
    this.shell,
    this.locale,
  });

  factory SystemInfoSample.unknown() => const SystemInfoSample(
        hostname: 'onbekend',
        osName: 'onbekend',
        kernelVersion: 'onbekend',
        architecture: 'onbekend',
        uptime: Duration.zero,
        cpuModel: 'onbekend',
        cpuCores: 0,
      );
}
