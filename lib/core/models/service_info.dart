/// A single systemd service unit, combining `systemctl list-units` and
/// `systemctl list-unit-files` output.
class ServiceInfo {
  final String unitName;
  final String loadState; // loaded / not-found / masked / ...
  final String activeState; // active / inactive / failed / ...
  final String subState; // running / dead / waiting / failed / ...
  final String description;
  final String enabledState; // enabled / disabled / static / masked / unknown

  const ServiceInfo({
    required this.unitName,
    required this.loadState,
    required this.activeState,
    required this.subState,
    required this.description,
    required this.enabledState,
  });

  bool get isRunning => activeState == 'active';
  bool get isFailed => activeState == 'failed';
  bool get isEnabled => enabledState == 'enabled';
}
