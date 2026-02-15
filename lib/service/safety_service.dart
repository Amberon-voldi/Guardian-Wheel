import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:uuid/uuid.dart';

import '../model/ride_status.dart';
import '../model/safety_alert.dart';
import '../model/safety_event.dart';
import 'app_event_bus.dart';
import 'local_database.dart';
import 'ride_service.dart';

class SafetyServiceException implements Exception {
  SafetyServiceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'SafetyServiceException(message: $message, cause: $cause)';
}

/// Offline-first safety / SOS service.
class SafetyService {
  SafetyService({
    required Databases databases,
    required this.rideService,
    required this.databaseId,
    required this.alertsCollectionId,
    this.eventBus,
  }) : _databases = databases;

  final Databases _databases;
  final RideService rideService;
  final String databaseId;
  final String alertsCollectionId;
  final AppEventBus? eventBus;
  final LocalDatabase _localDb = LocalDatabase.instance;
  static const _uuid = Uuid();

  final StreamController<SafetyEvent> _eventController = StreamController<SafetyEvent>.broadcast();
  Stream<SafetyEvent> get events => _eventController.stream;

  Future<ManualSosResult> triggerManualSos({
    required String userId,
    required String rideId,
    required double currentLat,
    required double currentLng,
    String? message,
  }) async {
    _emit(SafetyEvent(
      type: SafetyEventType.sosTriggered,
      timestamp: DateTime.now().toUtc(),
      message: 'Manual SOS triggered.',
    ));

    try {
      final alert = await _createAlert(
        userId: userId,
        rideId: rideId,
        alertType: 'sos_manual',
        lat: currentLat,
        lng: currentLng,
      );

      _emit(SafetyEvent(
        type: SafetyEventType.alertCreated,
        timestamp: DateTime.now().toUtc(),
        alert: alert,
        message: 'Alert created.',
      ));
      eventBus?.publishAlert(alert, message: 'Alert created.');

      final updatedRide = await rideService.updateRideStatus(
        rideId: rideId,
        status: RideStatus.emergency,
      );

      _emit(SafetyEvent(
        type: SafetyEventType.rideMarkedEmergency,
        timestamp: DateTime.now().toUtc(),
        alert: alert,
        ride: updatedRide,
        message: 'Ride status set to emergency.',
      ));

      return ManualSosResult(alert: alert, updatedRide: updatedRide);
    } catch (error) {
      _emit(SafetyEvent(
        type: SafetyEventType.failed,
        timestamp: DateTime.now().toUtc(),
        message: error.toString(),
      ));
      rethrow;
    }
  }

  Future<SafetyAlert> triggerCrashAlert({
    required String userId,
    required String rideId,
    required double lat,
    required double lng,
  }) async {
    final alert = await _createAlert(
      userId: userId,
      rideId: rideId,
      alertType: 'crash_auto',
      lat: lat,
      lng: lng,
    );

    await rideService.updateRideStatus(
      rideId: rideId,
      status: RideStatus.emergency,
      crashDetected: true,
    );

    eventBus?.publishAlert(alert, message: 'Crash alert created.');
    return alert;
  }

  Future<SafetyAlert> _createAlert({
    required String userId,
    required String rideId,
    required String alertType,
    required double lat,
    required double lng,
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();

    // Always save locally first (offline-first)
    await _localDb.insertAlert({
      'id': id,
      'user_id': userId,
      'ride_id': rideId,
      'alert_type': alertType,
      'lat': lat,
      'lng': lng,
      'notified_contacts': 0,
      'resolved': 0,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'synced': 0,
    });

    // Try remote in background
    _trySyncAlert(id, {
      'user_id': userId,
      'ride_id': rideId,
      'alert_type': alertType,
      'lat': lat,
      'lng': lng,
      'notified_contacts': false,
      'resolved': false,
    });

    return SafetyAlert(
      id: id,
      userId: userId,
      rideId: rideId,
      type: alertType,
      status: 'open',
      lat: lat,
      lng: lng,
      createdAt: now,
      updatedAt: now,
    );
  }

  void _trySyncAlert(String id, Map<String, dynamic> data) {
    Future(() async {
      try {
        await _databases.createDocument(
          databaseId: databaseId,
          collectionId: alertsCollectionId,
          documentId: id,
          data: data,
        );
        await _localDb.markSynced('alerts', id);
      } catch (_) {
        // Will sync later.
      }
    });
  }

  void _emit(SafetyEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  Future<void> dispose() async {
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }
}