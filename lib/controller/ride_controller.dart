import 'dart:async';

import '../model/ride_status.dart';
import '../service/location_service.dart';
import '../service/mesh_service.dart';
import '../service/ride_service.dart';
import '../service/safety_service.dart';

enum RideNavigationEventType { openAlert }

class RideNavigationEvent {
  const RideNavigationEvent({
    required this.type,
    required this.reason,
    required this.timestamp,
  });

  final RideNavigationEventType type;
  final String reason;
  final DateTime timestamp;
}

class RideController {
  RideController({
    required this.userId,
    required LocationService locationService,
    required RideService rideService,
    required SafetyService safetyService,
    required MeshService meshService,
  }) : _locationService = locationService,
       _rideService = rideService,
       _safetyService = safetyService,
       _meshService = meshService;

  final String userId;
  final LocationService _locationService;
  final RideService _rideService;
  final SafetyService _safetyService;
  final MeshService _meshService;

  final StreamController<RideStatus> _statusController =
      StreamController<RideStatus>.broadcast();
  final StreamController<LocationPoint> _locationController =
      StreamController<LocationPoint>.broadcast();
  final StreamController<RideNavigationEvent> _navigationController =
      StreamController<RideNavigationEvent>.broadcast();

  StreamSubscription<LocationPoint>? _locationSub;
  StreamSubscription<CrashEvent>? _crashSub;

  String? _rideId;
  RideStatus _status = RideStatus.completed;
  LocationPoint? _latestLocation;

  String? get rideId => _rideId;
  RideStatus get status => _status;
  LocationPoint? get latestLocation => _latestLocation;
  bool get systemsActive => _status != RideStatus.completed;

  Stream<RideStatus> get statusStream => _statusController.stream;
  Stream<LocationPoint> get locationStream => _locationController.stream;
  Stream<RideNavigationEvent> get navigationEvents => _navigationController.stream;

  Future<void> startRide() async {
    final location = await _locationService.getCurrentLocation();

    try {
      final ride = await _rideService.startRide(
        userId: userId,
        startLat: location.lat,
        startLng: location.lng,
      );
      _rideId = ride.id;
      _setStatus(RideStatus.active);
    } catch (_) {
      _rideId = '$userId-${DateTime.now().millisecondsSinceEpoch}';
      _setStatus(RideStatus.active);
    }

    _latestLocation = location;
    _locationService.startTracking();
    _attachStreams();
  }

  Future<void> endRide() async {
    final location = await _locationService.getCurrentLocation();

    if (_rideId != null) {
      try {
        await _rideService.endRide(
          rideId: _rideId!,
          endLat: location.lat,
          endLng: location.lng,
        );
      } catch (_) {
        // keep graceful local state transition
      }
    }

    _locationService.stopTracking();
    await _detachStreams();
    _setStatus(RideStatus.completed);
  }

  Future<void> triggerManualSos() async {
    await _activateEmergency(reason: 'manual_sos');
  }

  Future<void> _activateEmergency({required String reason}) async {
    if (!systemsActive) {
      await startRide();
    }

    final location = _latestLocation ?? await _locationService.getCurrentLocation();
    _latestLocation = location;

    _setStatus(RideStatus.emergency);

    final currentRideId = _rideId;
    if (currentRideId != null) {
      try {
        if (reason == 'crash_detected') {
          await _safetyService.triggerCrashAlert(
            userId: userId,
            rideId: currentRideId,
            lat: location.lat,
            lng: location.lng,
          );
        } else {
          await _safetyService.triggerManualSos(
            userId: userId,
            rideId: currentRideId,
            currentLat: location.lat,
            currentLng: location.lng,
            message: reason,
          );
        }
      } catch (_) {
        // continue mesh + navigation even if backend write fails
      }
    }

    try {
      await _meshService.generateAlertPacket(
        origin: userId,
        lat: location.lat,
        lng: location.lng,
      );
    } catch (_) {
      // keep flow resilient
    }

    _emitNavigation(reason: reason);
  }

  void _attachStreams() {
    _locationSub ??= _locationService.locationStream.listen((point) {
      _latestLocation = point;
      if (!_locationController.isClosed) {
        _locationController.add(point);
      }
    });

    _crashSub ??= _locationService.crashStream.listen((event) {
      _latestLocation = event.location;
      _activateEmergency(reason: 'crash_detected');
    });
  }

  Future<void> _detachStreams() async {
    await _locationSub?.cancel();
    await _crashSub?.cancel();
    _locationSub = null;
    _crashSub = null;
  }

  void _setStatus(RideStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _emitNavigation({required String reason}) {
    if (_navigationController.isClosed) return;
    _navigationController.add(
      RideNavigationEvent(
        type: RideNavigationEventType.openAlert,
        reason: reason,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> dispose() async {
    _locationService.stopTracking();
    await _detachStreams();
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
    if (!_locationController.isClosed) {
      await _locationController.close();
    }
    if (!_navigationController.isClosed) {
      await _navigationController.close();
    }
  }
}