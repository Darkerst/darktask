/// A single point-in-time reading for one mounted filesystem.
class DiskSample {
  final String device;
  final String fsType;
  final String mountPoint;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;

  const DiskSample({
    required this.device,
    required this.fsType,
    required this.mountPoint,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
  });

  double get usedPercent => totalBytes == 0 ? 0 : (usedBytes / totalBytes) * 100;
}
