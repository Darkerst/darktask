/// Why a GPU's load reading is currently unavailable, and whether the
/// app can offer an in-app fix for it.
enum GpuDiagnosticKind {
  ok,
  toolMissing,
  permissionDenied,
  unknown,
}

class GpuDiagnostic {
  final GpuDiagnosticKind kind;
  final String message;

  const GpuDiagnostic({required this.kind, required this.message});

  bool get canOfferPermissionFix => kind == GpuDiagnosticKind.permissionDenied;
  bool get canOfferInstall => kind == GpuDiagnosticKind.toolMissing;

  static const ok = GpuDiagnostic(kind: GpuDiagnosticKind.ok, message: 'OK');
}
