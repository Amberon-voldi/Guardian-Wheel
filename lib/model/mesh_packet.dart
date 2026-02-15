class MeshPacket {
  const MeshPacket({
    required this.id,
    required this.origin,
    required this.lat,
    required this.lng,
    required this.hop,
    required this.ttl,
    required this.status,
    required this.createdAt,
    this.lastPeer,
    this.deliveredAt,
  });

  final String id;
  final String origin;
  final double lat;
  final double lng;
  final int hop;
  final int ttl;
  final MeshPacketStatus status;
  final DateTime createdAt;
  final String? lastPeer;
  final DateTime? deliveredAt;

  MeshPacket copyWith({
    String? id,
    String? origin,
    double? lat,
    double? lng,
    int? hop,
    int? ttl,
    MeshPacketStatus? status,
    DateTime? createdAt,
    String? lastPeer,
    DateTime? deliveredAt,
  }) {
    return MeshPacket(
      id: id ?? this.id,
      origin: origin ?? this.origin,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      hop: hop ?? this.hop,
      ttl: ttl ?? this.ttl,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      lastPeer: lastPeer ?? this.lastPeer,
      deliveredAt: deliveredAt ?? this.deliveredAt,
    );
  }
}

enum MeshPacketStatus {
  created,
  received,
  forwarded,
  forwarding,
  delivered,
  expired,
  duplicateDropped,
  pending,
  failed,
}

class MeshPacketState {
  const MeshPacketState({
    required this.packet,
    required this.timestamp,
    required this.status,
    this.message,
  });

  final MeshPacket packet;
  final DateTime timestamp;
  final MeshPacketStatus status;
  final String? message;
}