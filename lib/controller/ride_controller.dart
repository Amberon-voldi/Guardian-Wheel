import 'dart:async';

import '../model/ride_status.dart';
import '../service/location_service.dart';
import '../service/mesh_service.dart';
import '../service/ride_service.dart';
import '../service/safety_service.dart';

enum RideNavigationEventType { openAlert }

enum RideCrashCountdownEventType { started, tick, cancelled }

class RideNavigationEvent {
  const RideNavigationEvent({
    required this.type,
    required this.reason,
    required this.timestamp,
    this.countdownSeconds,
    this.isCrashCountdown = false,
  });

  final RideNavigationEventType type;
  final String reason;
  final DateTime timestamp;
  final int? countdownSeconds;
  final bool isCrashCountdown;
}

class RideCrashCountdownEvent {
  const RideCrashCountdownEvent({
    required this.type,
    required this.secondsRemaining,
    required this.timestamp,
  });

  final RideCrashCountdownEventType type;
  final int secondsRemaining;
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
  final StreamController<RideCrashCountdownEvent> _crashCountdownController =
      StreamController<RideCrashCountdownEvent>.broadcast();

  StreamSubscription<LocationPoint>? _locationSub;
  StreamSubscription<CrashEvent>? _crashSub;
  Timer? _crashCountdownTimer;
  CrashEvent? _pendingCrashEvent;
  int _crashSecondsRemaining = 0;
  static const int _crashCountdownSeconds = 10;

  String? _rideId;
  RideStatus _status = RideStatus.completed;
  LocationPoint? _latestLocation;

  String? get rideId => _rideId;
  RideStatus get status => _status;
  LocationPoint? get latestLocation => _latestLocation;
  bool get systemsActive => _status != RideStatus.completed;

  Stream<RideStatus> get statusStream => _statusController.stream;
  Stream<LocationPoint> get locationStream => _locationController.stream;
  Stream<RideNavigationEvent> get navigationEvents =>
      _navigationController.stream;
  Stream<RideCrashCountdownEvent> get crashCountdownEvents =>
      _crashCountdownController.stream;

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
    cancelPendingCrashSos();
    await _activateEmergency(reason: 'manual_sos');
  }

  Future<void> triggerCrashSos() async {
    await _activateEmergency(reason: 'crash_detected');
  }

  void cancelPendingCrashSos() {
    _crashCountdownTimer?.cancel();
    _crashCountdownTimer = null;
    _pendingCrashEvent = null;
    if (_crashSecondsRemaining > 0) {
      _crashSecondsRemaining = 0;
      _emitCrashCountdown(
        type: RideCrashCountdownEventType.cancelled,
        secondsRemaining: 0,
      );
    }
  }

  Future<void> _activateEmergency({required String reason}) async {
    if (!systemsActive) {
      await startRide();
    }

    final location =
        _latestLocation ?? await _locationService.getCurrentLocation();
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
      _startCrashSosCountdown(event);
    });
  }

  void _startCrashSosCountdown(CrashEvent crashEvent) {
    if (_crashCountdownTimer != null) {
      return;
    }

    _pendingCrashEvent = crashEvent;
    _crashSecondsRemaining = _crashCountdownSeconds;
    _emitCrashCountdown(
      type: RideCrashCountdownEventType.started,
      secondsRemaining: _crashSecondsRemaining,
    );

    _crashCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _crashSecondsRemaining -= 1;

      if (_crashSecondsRemaining <= 0) {
        timer.cancel();
        _crashCountdownTimer = null;
        final pending = _pendingCrashEvent;
        _pendingCrashEvent = null;

        if (pending != null) {
          _latestLocation = pending.location;
        }
        unawaited(triggerCrashSos());
        return;
      }

      _emitCrashCountdown(
        type: RideCrashCountdownEventType.tick,
        secondsRemaining: _crashSecondsRemaining,
      );
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

  void _emitCrashCountdown({
    required RideCrashCountdownEventType type,
    required int secondsRemaining,
  }) {
    if (_crashCountdownController.isClosed) {
      return;
    }
    _crashCountdownController.add(
      RideCrashCountdownEvent(
        type: type,
        secondsRemaining: secondsRemaining,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> dispose() async {
    _locationService.stopTracking();
    cancelPendingCrashSos();
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
    if (!_crashCountdownController.isClosed) {
      await _crashCountdownController.close();
    }
  }
}
