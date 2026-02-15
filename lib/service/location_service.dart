import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'background_service.dart';

class LocationPoint {
  const LocationPoint({
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.speed,
    this.accuracy,
  });

  final double lat;
  final double lng;
  final DateTime timestamp;
  final double? speed;
  final double? accuracy;
}

class CrashEvent {
  const CrashEvent({
    required this.location,
    required this.timestamp,
    this.severity = 'high',
    this.impactG = 0,
    this.rotationRate = 0,
  });

  final LocationPoint location;
  final DateTime timestamp;
  final String severity;
  final double impactG;
  final double rotationRate;
}

/// Location service that bridges the background isolate's GPS + accelerometer
/// data into the UI isolate. When the background service is running, all
/// location updates and crash events come from there. When it isn't, falls
/// back to foreground-only tracking.
class LocationService {
  final StreamController<LocationPoint> _locationController =
      StreamController<LocationPoint>.broadcast();
  final StreamController<CrashEvent> _crashController =
      StreamController<CrashEvent>.broadcast();

  StreamSubscription<Map<String, dynamic>?>? _bgLocationSub;
  StreamSubscription<Map<String, dynamic>?>? _bgCrashSub;
  StreamSubscription<Map<String, dynamic>?>? _bgTelemetrySub;
  StreamSubscription<Map<String, dynamic>?>? _bgMotionSub;

  // Foreground fallback subscriptions
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  LocationPoint? _lastPoint;
  double _maxSpeed = 0;
  double _totalSpeed = 0;
  int _speedSamples = 0;
  double _latestRotationRate = 0;

  bool _backgroundRunning = false;

  // Crash detection parameters (foreground fallback)
  static const double _crashThresholdG = 4.0;
  static const double _crashThresholdWithRotationG = 3.0;
  static const double _rotationCrashThreshold = 5.0;
  static const Duration _crashCooldown = Duration(seconds: 10);
  DateTime? _lastCrashTime;

  Stream<LocationPoint> get locationStream => _locationController.stream;
  Stream<CrashEvent> get crashStream => _crashController.stream;
  double get maxSpeed => _maxSpeed;
  double get avgSpeed => _speedSamples > 0 ? _totalSpeed / _speedSamples : 0;
  double get latestRotationRate => _latestRotationRate;

  Future<bool> requestPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;
    return true;
  }

  Future<LocationPoint> getCurrentLocation() async {
    try {
      final hasPermission = await requestPermissions();
      if (hasPermission) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        final point = LocationPoint(
          lat: pos.latitude,
          lng: pos.longitude,
          timestamp: pos.timestamp,
          speed: pos.speed,
          accuracy: pos.accuracy,
        );
        _lastPoint = point;
        return point;
      }
    } catch (_) {
      // Fall through to fallback
    }
    return _lastPoint ??
        LocationPoint(lat: 12.9716, lng: 77.5946, timestamp: DateTime.now().toUtc());
  }

  /// Start tracking via the background service (foreground notification on
  /// Android). If the background service fails to start, falls back to
  /// in-process tracking.
  void startTracking({Duration interval = const Duration(seconds: 2)}) {
    _startBackgroundTracking();
  }

  Future<void> _startBackgroundTracking() async {
    try {
      final service = FlutterBackgroundService();
      final isRunning = await service.isRunning();

      if (!isRunning) {
        await service.startService();
      } else {
        // Service already running — just tell it to start sensors
        service.invoke(BgKeys.startTracking);
      }

      _backgroundRunning = true;
      _listenToBackgroundEvents();
    } catch (_) {
      // Background service unavailable — fall back to foreground tracking
      _backgroundRunning = false;
      _startForegroundTracking();
    }
  }

  /// Listen to events coming from the background isolate.
  void _listenToBackgroundEvents() {
    final service = FlutterBackgroundService();

    _bgLocationSub?.cancel();
    _bgLocationSub = service.on(BgKeys.locationUpdate).listen((data) {
      if (data == null) return;
      final point = LocationPoint(
        lat: (data['lat'] as num).toDouble(),
        lng: (data['lng'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          data['timestamp'] as int,
          isUtc: true,
        ),
        speed: (data['speed'] as num?)?.toDouble(),
        accuracy: (data['accuracy'] as num?)?.toDouble(),
      );
      _lastPoint = point;

      if (point.speed != null && point.speed! > 0) {
        final speedKmh = point.speed! * 3.6;
        if (speedKmh > _maxSpeed) _maxSpeed = speedKmh;
        _totalSpeed += speedKmh;
        _speedSamples++;
      }

      if (!_locationController.isClosed) {
        _locationController.add(point);
      }
    });

    _bgCrashSub?.cancel();
    _bgCrashSub = service.on(BgKeys.crashDetected).listen((data) {
      if (data == null) return;
      final now = DateTime.fromMillisecondsSinceEpoch(
        data['timestamp'] as int,
        isUtc: true,
      );
      final location = LocationPoint(
        lat: (data['lat'] as num).toDouble(),
        lng: (data['lng'] as num).toDouble(),
        timestamp: now,
        speed: (data['speed'] as num?)?.toDouble(),
      );
      _lastPoint = location;

      if (!_crashController.isClosed) {
        _crashController.add(CrashEvent(
          location: location,
          timestamp: now,
          severity: (data['severity'] as String?) ?? 'high',
          impactG: (data['impactG'] as num?)?.toDouble() ?? 0,
          rotationRate: (data['rotationRate'] as num?)?.toDouble() ?? 0,
        ));
      }
    });

    _bgTelemetrySub?.cancel();
    _bgTelemetrySub = service.on(BgKeys.telemetryUpdate).listen((data) {
      if (data == null) return;
      _maxSpeed = (data['maxSpeed'] as num?)?.toDouble() ?? _maxSpeed;
      final bgAvg = (data['avgSpeed'] as num?)?.toDouble() ?? 0;
      final bgSamples = (data['speedSamples'] as int?) ?? 0;
      _latestRotationRate =
          (data['gyroMagnitude'] as num?)?.toDouble() ?? _latestRotationRate;
      if (bgSamples > _speedSamples) {
        _totalSpeed = bgAvg * bgSamples;
        _speedSamples = bgSamples;
      }
    });

    _bgMotionSub?.cancel();
    _bgMotionSub = service.on(BgKeys.motionUpdate).listen((data) {
      if (data == null) return;
      _latestRotationRate =
          (data['rotationRate'] as num?)?.toDouble() ?? _latestRotationRate;
    });
  }

  /// Foreground-only fallback (same as before, used if bg service unavailable).
  void _startForegroundTracking() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      (pos) {
        final point = LocationPoint(
          lat: pos.latitude,
          lng: pos.longitude,
          timestamp: pos.timestamp,
          speed: pos.speed,
          accuracy: pos.accuracy,
        );
        if (pos.speed > 0) {
          final speedKmh = pos.speed * 3.6;
          if (speedKmh > _maxSpeed) _maxSpeed = speedKmh;
          _totalSpeed += speedKmh;
          _speedSamples++;
        }
        _lastPoint = point;
        if (!_locationController.isClosed) {
          _locationController.add(point);
        }
      },
      onError: (_) {},
    );

    _accelSub?.cancel();
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      final gForce = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          ) /
          9.81;

      final likelyCrash = gForce >= _crashThresholdG ||
          (gForce >= _crashThresholdWithRotationG &&
              _latestRotationRate >= _rotationCrashThreshold);

      if (likelyCrash) {
        _handlePotentialCrash(gForce, rotationRate: _latestRotationRate);
      }
    });

    _gyroSub?.cancel();
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      _latestRotationRate =
          math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    });
  }

  void _handlePotentialCrash(double impactG, {double rotationRate = 0}) {
    final now = DateTime.now().toUtc();
    if (_lastCrashTime != null &&
        now.difference(_lastCrashTime!) < _crashCooldown) {
      return;
    }
    _lastCrashTime = now;

    final location = _lastPoint ?? LocationPoint(lat: 0, lng: 0, timestamp: now);
    final severity = impactG >= 8.0
        ? 'critical'
        : impactG >= 6.0
            ? 'high'
            : 'medium';

    if (!_crashController.isClosed) {
      _crashController.add(
        CrashEvent(
          location: location,
          timestamp: now,
          severity: severity,
          impactG: impactG,
          rotationRate: rotationRate,
        ),
      );
    }
  }

  void simulateCrash({String severity = 'high'}) {
    if (_backgroundRunning) {
      FlutterBackgroundService().invoke(BgKeys.simulateCrash);
      return;
    }
    // Foreground fallback
    final now = DateTime.now().toUtc();
    final location = _lastPoint ?? LocationPoint(lat: 12.9716, lng: 77.5946, timestamp: now);
    if (!_crashController.isClosed) {
      _crashController.add(
        CrashEvent(
          location: location,
          timestamp: now,
          severity: severity,
          impactG: 6.0,
          rotationRate: _latestRotationRate,
        ),
      );
    }
  }

  void stopTracking() {
    if (_backgroundRunning) {
      FlutterBackgroundService().invoke(BgKeys.stopTracking);
      _bgLocationSub?.cancel();
      _bgCrashSub?.cancel();
      _bgTelemetrySub?.cancel();
      _bgMotionSub?.cancel();
      _bgLocationSub = null;
      _bgCrashSub = null;
      _bgTelemetrySub = null;
      _bgMotionSub = null;
      _backgroundRunning = false;
    }
    _positionSub?.cancel();
    _positionSub = null;
    _accelSub?.cancel();
    _accelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
  }

  /// Fully stop the background service process.
  Future<void> stopBackgroundService() async {
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (running) {
      service.invoke(BgKeys.stopService);
    }
    stopTracking();
  }

  void resetTelemetry() {
    _maxSpeed = 0;
    _totalSpeed = 0;
    _speedSamples = 0;
    _latestRotationRate = 0;
  }

  Future<void> dispose() async {
    await stopBackgroundService();
    if (!_locationController.isClosed) {
      await _locationController.close();
    }
    if (!_crashController.isClosed) {
      await _crashController.close();
    }
  }
}