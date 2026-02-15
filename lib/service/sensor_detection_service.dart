import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'location_service.dart';

// ── Models ───────────────────────────────────────────────────────────

enum HazardType { pothole, roughRoad, crashRisk, overspeed }

class HazardDetectionEvent {
  const HazardDetectionEvent({
    required this.type,
    required this.lat,
    required this.lng,
    required this.severity,
    required this.timestamp,
    required this.description,
    this.impactValue = 0,
  });

  final HazardType type;
  final double lat;
  final double lng;

  /// 0.0 (mild) → 1.0 (severe).
  final double severity;
  final DateTime timestamp;
  final String description;
  final double impactValue;
}

// ── Service ──────────────────────────────────────────────────────────

/// Monitors the accelerometer to detect potholes and rough road surfaces
/// and emits [HazardDetectionEvent]s for the UI to display.
class SensorDetectionService {
  SensorDetectionService({required this.locationProvider});

  /// Callback that returns the rider's current location on demand.
  final Future<LocationPoint> Function() locationProvider;

  // Thresholds
  static const double _gravityMagnitude = 9.81;
  static const double _potholeSpikeThresholdG = 2.5;
  static const Duration _potholeMaxDuration = Duration(milliseconds: 300);
  static const double _potholeMinSpeedKmh = 15.0;
  static const double _minimalRotationThreshold = 2.0;
  static const double _roughRoadMinSpikeG = 1.2;
  static const double _roughRoadMaxSpikeG = 2.0;
  static const int _roughRoadRequiredSpikes = 5;
  static const Duration _roughRoadWindow = Duration(seconds: 5);
  static const double _roughRoadMaxSpeedVarianceKmh = 10.0;
  static const double _crashSpikeThresholdG = 4.0;
  static const double _crashRotationThreshold = 4.5;
  static const Duration _crashMinImpactDuration = Duration(milliseconds: 500);
  static const double _crashFinalSpeedMaxKmh = 5.0;
  static const double _crashMinRapidDropKmh = 15.0;
  static const Duration _crashSpeedDropWindow = Duration(seconds: 3);
  static const double _overspeedThresholdKmh = 60.0;
  static const Duration _potholeCooldown = Duration(seconds: 4);
  static const Duration _roughRoadCooldown = Duration(seconds: 10);
  static const Duration _crashCooldown = Duration(seconds: 8);
  static const Duration _overspeedCooldown = Duration(seconds: 20);

  final List<DateTime> _roughRoadSpikeTimes = [];
  final List<_SpeedSample> _speedHistory = [];
  DateTime? _lastPotholeTime;
  DateTime? _lastRoughRoadTime;
  DateTime? _lastCrashTime;
  DateTime? _lastOverspeedTime;
  DateTime? _potholeSpikeStart;
  double _potholePeakG = 0;
  DateTime? _crashImpactStart;
  double _crashImpactPeakG = 0;

  double _latestRotationRate = 0;
  double _latestSpeedKmh = 0;
  double _lastKnownLat = 12.9716;
  double _lastKnownLng = 77.5946;
  bool _monitoring = false;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<Position>? _positionSub;
  final StreamController<HazardDetectionEvent> _controller =
      StreamController<HazardDetectionEvent>.broadcast();

  Stream<HazardDetectionEvent> get hazardStream => _controller.stream;
  bool get isMonitoring => _monitoring;

  // ── Lifecycle ────────────────────────────────────────────────────

  void startMonitoring() {
    if (_monitoring) return;
    _monitoring = true;

    unawaited(_primeLocation());

    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen(_process);

    _gyroSub =
        gyroscopeEventStream(
          samplingPeriod: const Duration(milliseconds: 100),
        ).listen((event) {
          _latestRotationRate = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          );
        });

    _startGpsMonitoring();
  }

  Future<void> _primeLocation() async {
    try {
      final loc = await locationProvider();
      _lastKnownLat = loc.lat;
      _lastKnownLng = loc.lng;
      final speed = loc.speed ?? 0;
      if (speed > 0) {
        _latestSpeedKmh = speed * 3.6;
      }
    } catch (_) {
      // Keep default coordinates as fallback.
    }
  }

  void _startGpsMonitoring() {
    _positionSub?.cancel();
    try {
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 3,
            ),
          ).listen((pos) {
            _lastKnownLat = pos.latitude;
            _lastKnownLng = pos.longitude;

            final speedMps = pos.speed > 0 ? pos.speed : 0;
            _latestSpeedKmh = speedMps * 3.6;
            _recordSpeed(_latestSpeedKmh);
            _checkOverspeed(_latestSpeedKmh);
          }, onError: (_) {});
    } catch (_) {
      // GPS stream unavailable (permissions/offline/device limitation).
    }
  }

  void stopMonitoring() {
    _monitoring = false;
    _accelSub?.cancel();
    _accelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _roughRoadSpikeTimes.clear();
    _speedHistory.clear();
    _potholeSpikeStart = null;
    _crashImpactStart = null;
  }

  Future<void> dispose() async {
    stopMonitoring();
    if (!_controller.isClosed) await _controller.close();
  }

  // ── Processing ───────────────────────────────────────────────────

  void _process(AccelerometerEvent event) {
    final now = DateTime.now().toUtc();
    final magnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    final magnitudeG = magnitude / _gravityMagnitude;
    final verticalG = event.z.abs() / _gravityMagnitude;

    _processPothole(now: now, verticalG: verticalG);
    _processRoughRoad(now: now, magnitudeG: magnitudeG);
    _processCrash(now: now, magnitudeG: magnitudeG);
  }

  void _processPothole({required DateTime now, required double verticalG}) {
    final inSpike = verticalG > _potholeSpikeThresholdG;

    if (inSpike) {
      _potholeSpikeStart ??= now;
      if (verticalG > _potholePeakG) {
        _potholePeakG = verticalG;
      }
      return;
    }

    final spikeStart = _potholeSpikeStart;
    if (spikeStart == null) {
      return;
    }

    final duration = now.difference(spikeStart);
    final speedMaintained = _latestSpeedKmh > _potholeMinSpeedKmh;
    final noMajorTilt = _latestRotationRate < _minimalRotationThreshold;

    if (duration <= _potholeMaxDuration && speedMaintained && noMajorTilt) {
      _checkPothole(_potholePeakG, duration);
    }

    _potholeSpikeStart = null;
    _potholePeakG = 0;
  }

  void _processRoughRoad({required DateTime now, required double magnitudeG}) {
    _pruneRoughRoadSamples(now);
    if (magnitudeG >= _roughRoadMinSpikeG &&
        magnitudeG <= _roughRoadMaxSpikeG) {
      _roughRoadSpikeTimes.add(now);
      _pruneRoughRoadSamples(now);
      if (_roughRoadSpikeTimes.length >= _roughRoadRequiredSpikes) {
        _checkRoughRoad(now);
      }
    }
  }

  void _processCrash({required DateTime now, required double magnitudeG}) {
    if (magnitudeG >= _crashSpikeThresholdG) {
      _crashImpactStart ??= now;
      if (magnitudeG > _crashImpactPeakG) {
        _crashImpactPeakG = magnitudeG;
      }
      return;
    }

    final impactStart = _crashImpactStart;
    if (impactStart == null) {
      return;
    }

    final duration = now.difference(impactStart);
    final speedDroppedRapidly = _hasRapidSpeedDrop(now);
    final finalSpeedLow = _latestSpeedKmh <= _crashFinalSpeedMaxKmh;
    final tiltDetected = _latestRotationRate >= _crashRotationThreshold;

    if (duration >= _crashMinImpactDuration &&
        speedDroppedRapidly &&
        finalSpeedLow &&
        tiltDetected) {
      _checkCrashRisk(_crashImpactPeakG, duration);
    }

    _crashImpactStart = null;
    _crashImpactPeakG = 0;
  }

  void _checkCrashRisk(double impactG, Duration duration) {
    final now = DateTime.now().toUtc();
    if (_lastCrashTime != null &&
        now.difference(_lastCrashTime!) < _crashCooldown) {
      return;
    }
    _lastCrashTime = now;

    final severity = ((impactG - _crashSpikeThresholdG) / 4.0).clamp(0.35, 1.0);
    _emitHazard(
      type: HazardType.crashRisk,
      severity: severity,
      description:
          'Crash detected (${impactG.toStringAsFixed(1)}g, ${duration.inMilliseconds}ms, speed ${_latestSpeedKmh.toStringAsFixed(1)} km/h)',
      impactValue: impactG,
    );
  }

  void _checkOverspeed(double speedKmh) {
    if (speedKmh < _overspeedThresholdKmh) return;

    final now = DateTime.now().toUtc();
    if (_lastOverspeedTime != null &&
        now.difference(_lastOverspeedTime!) < _overspeedCooldown) {
      return;
    }
    _lastOverspeedTime = now;

    final severity = ((speedKmh - _overspeedThresholdKmh) / 40.0).clamp(
      0.2,
      1.0,
    );
    _emitHazard(
      type: HazardType.overspeed,
      severity: severity,
      description: 'High speed detected (${speedKmh.toStringAsFixed(1)} km/h)',
      impactValue: speedKmh,
    );
  }

  void _checkPothole(double impactG, Duration duration) {
    final now = DateTime.now().toUtc();
    if (_lastPotholeTime != null &&
        now.difference(_lastPotholeTime!) < _potholeCooldown) {
      return;
    }
    _lastPotholeTime = now;

    final severity = ((impactG - _potholeSpikeThresholdG) / 2.5).clamp(
      0.2,
      1.0,
    );
    _emitHazard(
      type: HazardType.pothole,
      severity: severity,
      description:
          'Pothole detected (${impactG.toStringAsFixed(1)}g, ${duration.inMilliseconds}ms)',
      impactValue: impactG,
    );
  }

  void _checkRoughRoad(DateTime now) {
    if (_lastRoughRoadTime != null &&
        now.difference(_lastRoughRoadTime!) < _roughRoadCooldown) {
      return;
    }

    final speedStable = _isSpeedStableInWindow();
    final noMajorTilt = _latestRotationRate < _minimalRotationThreshold;
    if (!speedStable || !noMajorTilt) {
      return;
    }

    _lastRoughRoadTime = now;
    final severity =
        ((_roughRoadSpikeTimes.length - _roughRoadRequiredSpikes) / 6.0).clamp(
          0.2,
          1.0,
        );
    _emitHazard(
      type: HazardType.roughRoad,
      severity: severity,
      description:
          'Rough road detected (${_roughRoadSpikeTimes.length} spikes in ${_roughRoadWindow.inSeconds}s)',
      impactValue: _roughRoadSpikeTimes.length.toDouble(),
    );
  }

  void _recordSpeed(double speedKmh) {
    final now = DateTime.now().toUtc();
    _speedHistory.add(_SpeedSample(timestamp: now, speedKmh: speedKmh));
    _pruneSpeedHistory(now);
  }

  void _pruneSpeedHistory(DateTime now) {
    _speedHistory.removeWhere(
      (sample) => now.difference(sample.timestamp) > _roughRoadWindow,
    );
  }

  void _pruneRoughRoadSamples(DateTime now) {
    _roughRoadSpikeTimes.removeWhere(
      (sampleTime) => now.difference(sampleTime) > _roughRoadWindow,
    );
  }

  bool _isSpeedStableInWindow() {
    if (_speedHistory.length < 2) {
      return true;
    }
    var minSpeed = _speedHistory.first.speedKmh;
    var maxSpeed = _speedHistory.first.speedKmh;
    for (final sample in _speedHistory) {
      if (sample.speedKmh < minSpeed) {
        minSpeed = sample.speedKmh;
      }
      if (sample.speedKmh > maxSpeed) {
        maxSpeed = sample.speedKmh;
      }
    }
    return (maxSpeed - minSpeed) <= _roughRoadMaxSpeedVarianceKmh;
  }

  bool _hasRapidSpeedDrop(DateTime now) {
    final recentSamples = _speedHistory
        .where(
          (sample) => now.difference(sample.timestamp) <= _crashSpeedDropWindow,
        )
        .toList(growable: false);
    if (recentSamples.isEmpty) {
      return false;
    }

    var maxRecentSpeed = recentSamples.first.speedKmh;
    for (final sample in recentSamples) {
      if (sample.speedKmh > maxRecentSpeed) {
        maxRecentSpeed = sample.speedKmh;
      }
    }

    return (maxRecentSpeed - _latestSpeedKmh) >= _crashMinRapidDropKmh;
  }

  Future<void> _emitHazard({
    required HazardType type,
    required double severity,
    required String description,
    double impactValue = 0,
  }) async {
    if (_controller.isClosed) return;

    var lat = _lastKnownLat;
    var lng = _lastKnownLng;

    try {
      final loc = await locationProvider();
      lat = loc.lat;
      lng = loc.lng;
      _lastKnownLat = lat;
      _lastKnownLng = lng;
    } catch (_) {
      // Keep last-known location fallback.
    }

    _controller.add(
      HazardDetectionEvent(
        type: type,
        lat: lat,
        lng: lng,
        severity: severity,
        timestamp: DateTime.now().toUtc(),
        description: description,
        impactValue: impactValue,
      ),
    );
  }
}

class _SpeedSample {
  const _SpeedSample({required this.timestamp, required this.speedKmh});

  final DateTime timestamp;
  final double speedKmh;
}
