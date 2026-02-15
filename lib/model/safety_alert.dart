class SafetyAlert {
  const SafetyAlert({
    required this.id,
    required this.userId,
    required this.rideId,
    required this.type,
    required this.status,
    required this.lat,
    required this.lng,
    required this.createdAt,
    required this.updatedAt,
    this.message,
  });

  final String id;
  final String userId;
  final String rideId;
  final String type;
  final String status;
  final double lat;
  final double lng;
  final String? message;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory SafetyAlert.fromMap(Map<String, dynamic> map) {
    return SafetyAlert(
      id: (map[r'$id'] ?? '') as String,
      userId: (map['userId'] ?? '') as String,
      rideId: (map['rideId'] ?? '') as String,
      type: (map['type'] ?? 'manual_sos') as String,
      status: (map['status'] ?? 'open') as String,
      lat: _toDouble(map['lat']),
      lng: _toDouble(map['lng']),
      message: map['message'] as String?,
      createdAt: _toDateTime(map[r'$createdAt']) ?? DateTime.now().toUtc(),
      updatedAt: _toDateTime(map[r'$updatedAt']) ?? DateTime.now().toUtc(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'rideId': rideId,
      'type': type,
      'status': status,
      'lat': lat,
      'lng': lng,
      'message': message,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static DateTime? _toDateTime(dynamic value) {
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }
}