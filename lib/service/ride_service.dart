import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:uuid/uuid.dart';

import '../model/ride.dart';
import '../model/ride_status.dart';
import 'app_event_bus.dart';
import 'local_database.dart';

class RideServiceException implements Exception {
  RideServiceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'RideServiceException(message: $message, cause: $cause)';
}

/// Offline-first ride service. All writes go to local SQLite first,
/// then attempt Appwrite sync. Falls back gracefully when offline.
class RideService {
  RideService({
    required Databases databases,
    required Realtime realtime,
    required this.databaseId,
    required this.ridesCollectionId,
    this.eventBus,
  }) : _databases = databases,
       _realtime = realtime;

  final Databases _databases;
  final Realtime _realtime;
  final String databaseId;
  final String ridesCollectionId;
  final AppEventBus? eventBus;
  final LocalDatabase _localDb = LocalDatabase.instance;
  static const _uuid = Uuid();

  Future<Ride> startRide({
    required String userId,
    required double startLat,
    required double startLng,
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();

    final localRow = {
      'id': id,
      'user_id': userId,
      'start_lat': startLat,
      'start_lng': startLng,
      'end_lat': null,
      'end_lng': null,
      'status': RideStatus.active.value,
      'crash_detected': 0,
      'avg_speed': null,
      'max_speed': null,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'synced': 0,
    };

    await _localDb.insertRide(localRow);

    final ride = Ride(
      id: id,
      userId: userId,
      startLat: startLat,
      startLng: startLng,
      status: RideStatus.active,
      createdAt: now,
      updatedAt: now,
    );

    // Try remote sync in background
    _trySyncRide(id, {
      'user_id': userId,
      'start_lat': startLat,
      'start_lng': startLng,
      'status': RideStatus.active.value,
      'crash_detected': false,
    });

    eventBus?.publishRideUpdate(ride, message: 'Ride started.');
    return ride;
  }

  Future<Ride> endRide({
    required String rideId,
    required double endLat,
    required double endLng,
    double? avgSpeed,
    double? maxSpeed,
  }) async {
    final now = DateTime.now().toUtc();
    final updates = {
      'end_lat': endLat,
      'end_lng': endLng,
      'status': RideStatus.completed.value,
      'avg_speed': avgSpeed,
      'max_speed': maxSpeed,
      'updated_at': now.toIso8601String(),
      'synced': 0,
    };

    await _localDb.updateRide(rideId, updates);

    final local = await _localDb.getRide(rideId);
    final ride = _rideFromLocal(local!, rideId);

    _trySyncRide(rideId, {
      'end_lat': endLat,
      'end_lng': endLng,
      'status': RideStatus.completed.value,
      'avg_speed': avgSpeed,
      'max_speed': maxSpeed,
    }, update: true);

    eventBus?.publishRideUpdate(ride, message: 'Ride ended.');
    return ride;
  }

  Future<Ride> updateRideStatus({
    required String rideId,
    required RideStatus status,
    bool? crashDetected,
  }) async {
    final now = DateTime.now().toUtc();
    final updates = <String, dynamic>{
      'status': status.value,
      'updated_at': now.toIso8601String(),
      'synced': 0,
    };
    if (crashDetected != null) {
      updates['crash_detected'] = crashDetected ? 1 : 0;
    }

    await _localDb.updateRide(rideId, updates);

    final local = await _localDb.getRide(rideId);
    final ride = _rideFromLocal(local!, rideId);

    _trySyncRide(rideId, {
      'status': status.value,
      if (crashDetected != null) 'crash_detected': crashDetected,
    }, update: true);

    eventBus?.publishRideUpdate(ride, message: 'Ride status updated to ${status.value}.');
    return ride;
  }

  Stream<Ride> streamLiveRideUpdates({String? rideId, String? userId}) {
    final controller = StreamController<Ride>.broadcast();
    final channels = <String>[
      if (rideId != null)
        'databases.$databaseId.collections.$ridesCollectionId.documents.$rideId'
      else
        'databases.$databaseId.collections.$ridesCollectionId.documents',
    ];

    try {
      final subscription = _realtime.subscribe(channels);
      final sub = subscription.stream.listen(
        (event) {
          try {
            final payload = event.payload;
            if (payload.isEmpty) return;
            final ride = Ride.fromMap(payload);
            if (userId != null && ride.userId != userId) return;
            eventBus?.publishRideUpdate(ride, message: 'Realtime ride update.');
            controller.add(ride);
          } catch (error) {
            controller.addError(RideServiceException('Failed to parse realtime ride update.', cause: error));
          }
        },
        onError: (error) {
          controller.addError(RideServiceException('Realtime ride stream error.', cause: error));
        },
      );

      controller.onCancel = () async {
        await sub.cancel();
        subscription.close();
      };
    } catch (_) {
      // Offline – no realtime stream available.
    }

    return controller.stream;
  }

  Future<Ride> getRideById(String rideId) async {
    // Check local first
    final local = await _localDb.getRide(rideId);
    if (local != null) return _rideFromLocal(local, rideId);

    try {
      final document = await _databases.getDocument(
        databaseId: databaseId,
        collectionId: ridesCollectionId,
        documentId: rideId,
      );
      return Ride.fromMap(document.data..[r'$id'] = document.$id);
    } on AppwriteException catch (error) {
      throw RideServiceException('Failed to fetch ride.', cause: error);
    }
  }

  Future<List<Ride>> listRidesForUser(String userId) async {
    try {
      final docs = await _databases.listDocuments(
        databaseId: databaseId,
        collectionId: ridesCollectionId,
        queries: [
          Query.equal('user_id', userId),
          Query.orderDesc(r'$createdAt'),
        ],
      );
      return docs.documents.map(_fromDocument).toList(growable: false);
    } catch (_) {
      // Fallback: return empty when offline
      return [];
    }
  }

  void _trySyncRide(String id, Map<String, dynamic> data, {bool update = false}) {
    Future(() async {
      try {
        if (update) {
          await _databases.updateDocument(
            databaseId: databaseId,
            collectionId: ridesCollectionId,
            documentId: id,
            data: data,
          );
        } else {
          await _databases.createDocument(
            databaseId: databaseId,
            collectionId: ridesCollectionId,
            documentId: id,
            data: data,
          );
        }
        await _localDb.markSynced('rides', id);
      } catch (_) {
        // Will be synced later by SyncService.
      }
    });
  }

  Ride _rideFromLocal(Map<String, dynamic> row, String id) {
    return Ride(
      id: id,
      userId: (row['user_id'] ?? '') as String,
      startLat: (row['start_lat'] as num?)?.toDouble() ?? 0,
      startLng: (row['start_lng'] as num?)?.toDouble() ?? 0,
      endLat: (row['end_lat'] as num?)?.toDouble(),
      endLng: (row['end_lng'] as num?)?.toDouble(),
      status: RideStatus.fromValue((row['status'] ?? 'active') as String),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ?? DateTime.now().toUtc(),
    );
  }

  Ride _fromDocument(models.Document doc) {
    return Ride.fromMap(doc.data..[r'$id'] = doc.$id..[r'$createdAt'] = doc.$createdAt..[r'$updatedAt'] = doc.$updatedAt);
  }

  Future<void> dispose() async {}
}