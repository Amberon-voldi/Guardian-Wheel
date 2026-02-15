import 'dart:async';
import 'dart:math' as math;

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;

import '../model/hazard.dart';
import 'local_database.dart';

class HazardServiceException implements Exception {
  HazardServiceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'HazardServiceException(message: $message, cause: $cause)';
}

/// Offline-first hazard service. Queries local SQLite first, then enriches
/// from Appwrite when online.
class HazardService {
  HazardService({
    required Databases databases,
    required Realtime realtime,
    required this.databaseId,
    required this.potholesCollectionId,
    required this.connectivityZonesCollectionId,
  }) : _databases = databases,
       _realtime = realtime;

  final Databases _databases;
  final Realtime _realtime;
  final String databaseId;
  final String potholesCollectionId;
  final String connectivityZonesCollectionId;
  final LocalDatabase _localDb = LocalDatabase.instance;

  Future<List<Hazard>> fetchNearbyHazards({
    required double centerLat,
    required double centerLng,
    required double radiusKm,
    int limitPerTable = 100,
  }) async {
    // Try local first
    final bounds = _boundingBox(centerLat, centerLng, radiusKm);
    final localPotholes = await _localDb.getNearbyPotholes(bounds.minLat, bounds.maxLat, bounds.minLng, bounds.maxLng);
    final localZones = await _localDb.getNearbyConnectivityZones(bounds.minLat, bounds.maxLat, bounds.minLng, bounds.maxLng);

    final hazards = <Hazard>[
      ..._mapLocalRowsToHazards(localPotholes, 'potholes', centerLat, centerLng, radiusKm),
      ..._mapLocalRowsToHazards(localZones, 'connectivity_zones', centerLat, centerLng, radiusKm),
    ];

    // Enrich from remote if possible
    try {
      final bounds = _boundingBox(centerLat, centerLng, radiusKm);
      final results = await Future.wait([
        _databases.listDocuments(
          databaseId: databaseId,
          collectionId: potholesCollectionId,
          queries: [
            Query.greaterThanEqual('lat', bounds.minLat),
            Query.lessThanEqual('lat', bounds.maxLat),
            Query.greaterThanEqual('lng', bounds.minLng),
            Query.lessThanEqual('lng', bounds.maxLng),
            Query.limit(limitPerTable),
          ],
        ),
        _databases.listDocuments(
          databaseId: databaseId,
          collectionId: connectivityZonesCollectionId,
          queries: [
            Query.greaterThanEqual('lat', bounds.minLat),
            Query.lessThanEqual('lat', bounds.maxLat),
            Query.greaterThanEqual('lng', bounds.minLng),
            Query.lessThanEqual('lng', bounds.maxLng),
            Query.limit(limitPerTable),
          ],
        ),
      ]);

      final remoteHazards = <Hazard>[
        ..._mapDocumentsToHazards(
          documents: results[0].documents,
          sourceTable: potholesCollectionId,
          centerLat: centerLat,
          centerLng: centerLng,
          radiusKm: radiusKm,
        ),
        ..._mapDocumentsToHazards(
          documents: results[1].documents,
          sourceTable: connectivityZonesCollectionId,
          centerLat: centerLat,
          centerLng: centerLng,
          radiusKm: radiusKm,
        ),
      ];

      // Merge: remote overwrites local by id
      final merged = <String, Hazard>{};
      for (final h in hazards) { merged[h.id] = h; }
      for (final h in remoteHazards) { merged[h.id] = h; }

      final result = merged.values.toList()..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
      return result;
    } catch (_) {
      // Offline fallback – local only
      hazards.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
      return hazards;
    }
  }

  List<Hazard> _mapLocalRowsToHazards(
    List<Map<String, dynamic>> rows,
    String sourceTable,
    double centerLat,
    double centerLng,
    double radiusKm,
  ) {
    final hazards = <Hazard>[];
    for (final row in rows) {
      final lat = _toDouble(row['lat']);
      final lng = _toDouble(row['lng']);
      if (lat == null || lng == null) continue;
      final dist = _haversineKm(centerLat, centerLng, lat, lng);
      if (dist > radiusKm) continue;
      hazards.add(Hazard(
        id: (row['id'] ?? '') as String,
        sourceTable: sourceTable,
        lat: lat,
        lng: lng,
        distanceKm: dist,
        severity: row['severity'] as String?,
        createdAt: _parseDateTime(row['created_at']),
      ));
    }
    return hazards;
  }

  Future<List<HazardMarker>> fetchNearbyHazardMarkers({
    required double centerLat,
    required double centerLng,
    required double radiusKm,
    int limitPerTable = 100,
  }) async {
    final hazards = await fetchNearbyHazards(
      centerLat: centerLat,
      centerLng: centerLng,
      radiusKm: radiusKm,
      limitPerTable: limitPerTable,
    );
    return hazards.map(_toMarker).toList(growable: false);
  }

  Stream<List<HazardMarker>> streamNearbyHazardMarkers({
    required double centerLat,
    required double centerLng,
    required double radiusKm,
    int limitPerTable = 100,
  }) {
    final controller = StreamController<List<HazardMarker>>.broadcast();

    Future<void> refresh() async {
      try {
        final markers = await fetchNearbyHazardMarkers(
          centerLat: centerLat,
          centerLng: centerLng,
          radiusKm: radiusKm,
          limitPerTable: limitPerTable,
        );
        controller.add(markers);
      } catch (error) {
        controller.addError(
          error is HazardServiceException
              ? error
              : HazardServiceException('Failed to refresh nearby markers.', cause: error),
        );
      }
    }

    final channels = <String>[
      'databases.$databaseId.collections.$potholesCollectionId.documents',
      'databases.$databaseId.collections.$connectivityZonesCollectionId.documents',
    ];

    final realtimeSubscription = _realtime.subscribe(channels);
    final sub = realtimeSubscription.stream.listen(
      (_) => refresh(),
      onError: (error) => controller.addError(
        HazardServiceException('Realtime hazard stream error.', cause: error),
      ),
    );

    refresh();

    controller.onCancel = () async {
      await sub.cancel();
      realtimeSubscription.close();
    };

    return controller.stream;
  }

  List<Hazard> _mapDocumentsToHazards({
    required List<models.Document> documents,
    required String sourceTable,
    required double centerLat,
    required double centerLng,
    required double radiusKm,
  }) {
    final hazards = <Hazard>[];

    for (final document in documents) {
      final data = <String, dynamic>{
        ...document.data,
        r'$id': document.$id,
        r'$createdAt': document.$createdAt,
        r'$updatedAt': document.$updatedAt,
      };

      final lat = _extractDouble(data, const ['lat', 'latitude', 'startLat']);
      final lng = _extractDouble(data, const ['lng', 'longitude', 'startLng']);

      if (lat == null || lng == null) continue;

      final distanceKm = _haversineKm(centerLat, centerLng, lat, lng);
      if (distanceKm > radiusKm) continue;

      final type = _extractString(data, const ['type', 'hazardType', 'zoneType']);
      final title = _extractString(data, const ['title', 'name', 'label', 'description']);
      final severity = _extractString(data, const ['severity', 'level', 'riskLevel']);
      final status = _extractString(data, const ['status', 'state']);

      hazards.add(
        Hazard(
          id: (data[r'$id'] ?? '') as String,
          sourceTable: sourceTable,
          lat: lat,
          lng: lng,
          distanceKm: distanceKm,
          type: type,
          title: title,
          severity: severity,
          status: status,
          createdAt: _extractDateTime(data[r'$createdAt']),
          updatedAt: _extractDateTime(data[r'$updatedAt']),
        ),
      );
    }

    return hazards;
  }

  HazardMarker _toMarker(Hazard hazard) {
    final category = hazard.type ??
        (hazard.sourceTable == potholesCollectionId ? 'pothole' : 'connectivity_zone');

    final label = hazard.title ?? category.replaceAll('_', ' ').toUpperCase();
    final severity = (hazard.severity ?? '').toLowerCase();
    final status = (hazard.status ?? '').toLowerCase();

    final isCritical =
        severity == 'high' || severity == 'critical' || status == 'danger' || category.contains('theft');

    return HazardMarker(
      id: hazard.id,
      lat: hazard.lat,
      lng: hazard.lng,
      label: label,
      category: category,
      isCritical: isCritical,
      distanceKm: hazard.distanceKm,
    );
  }

  _GeoBox _boundingBox(double lat, double lng, double radiusKm) {
    const kmPerDegreeLat = 111.32;
    final latDelta = radiusKm / kmPerDegreeLat;
    final lngDelta = radiusKm / (kmPerDegreeLat * math.cos(_degToRad(lat)).abs().clamp(0.01, 1.0));

    return _GeoBox(
      minLat: lat - latDelta,
      maxLat: lat + latDelta,
      minLng: lng - lngDelta,
      maxLng: lng + lngDelta,
    );
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degToRad(double degrees) => degrees * math.pi / 180;

  double? _extractDouble(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  String? _extractString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  DateTime? _extractDateTime(dynamic value) {
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  DateTime? _parseDateTime(dynamic value) {
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

class _GeoBox {
  const _GeoBox({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
}