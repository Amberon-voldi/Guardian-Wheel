class Hazard {
  const Hazard({
    required this.id,
    required this.sourceTable,
    required this.lat,
    required this.lng,
    required this.distanceKm,
    this.type,
    this.title,
    this.severity,
    this.status,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String sourceTable;
  final double lat;
  final double lng;
  final double distanceKm;
  final String? type;
  final String? title;
  final String? severity;
  final String? status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class HazardMarker {
  const HazardMarker({
    required this.id,
    required this.lat,
    required this.lng,
    required this.label,
    required this.category,
    required this.isCritical,
    required this.distanceKm,
  });

  final String id;
  final double lat;
  final double lng;
  final String label;
  final String category;
  final bool isCritical;
  final double distanceKm;
}