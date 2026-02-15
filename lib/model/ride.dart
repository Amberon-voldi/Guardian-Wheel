import 'ride_status.dart';

class Ride {
  const Ride({
    required this.id,
    required this.userId,
    required this.startLat,
    required this.startLng,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.endLat,
    this.endLng,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String userId;
  final double startLat;
  final double startLng;
  final double? endLat;
  final double? endLng;
  final RideStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  Ride copyWith({
    String? id,
    String? userId,
    double? startLat,
    double? startLng,
    double? endLat,
    double? endLng,
    RideStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? endedAt,
  }) {
    return Ride(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      startLat: startLat ?? this.startLat,
      startLng: startLng ?? this.startLng,
      endLat: endLat ?? this.endLat,
      endLng: endLng ?? this.endLng,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
    );
  }

  factory Ride.fromMap(Map<String, dynamic> map) {
    final id = (map[r'$id'] ?? map['id'] ?? '') as String;

    return Ride(
      id: id,
      userId: (map['userId'] ?? '') as String,
      startLat: _toDouble(map['startLat']),
      startLng: _toDouble(map['startLng']),
      endLat: _toNullableDouble(map['endLat']),
      endLng: _toNullableDouble(map['endLng']),
      status: RideStatus.fromValue((map['status'] ?? RideStatus.active.value) as String),
      createdAt: _toDateTime(map[r'$createdAt']) ?? DateTime.now().toUtc(),
      updatedAt: _toDateTime(map[r'$updatedAt']) ?? DateTime.now().toUtc(),
      startedAt: _toDateTime(map['startedAt']),
      endedAt: _toDateTime(map['endedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'startLat': startLat,
      'startLng': startLng,
      'endLat': endLat,
      'endLng': endLng,
      'status': status.value,
      'startedAt': startedAt?.toUtc().toIso8601String(),
      'endedAt': endedAt?.toUtc().toIso8601String(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static double? _toNullableDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _toDateTime(dynamic value) {
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }
}