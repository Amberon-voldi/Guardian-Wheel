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
  static const double _gravityLowPassAlpha = 0.78;
  static const double _potholeSpikeThresholdG = 1.6;
  static const double _potholeMinSpikeDurationMs = 0;
  static const Duration _potholeMaxDuration = Duration(milliseconds: 300);
  static const double _potholeMinSpeedKmh = 0.0;
  static const double _potholeMaxSpeedKmh = 85.0;
  static const double _minimalRotationThreshold = 12.0;
  static const double _roughRoadMinSpikeG = 0.4;
  static const double _roughRoadMaxSpikeG = 3.0;
  static const int _roughRoadRequiredSpikes = 1;
  static const Duration _roughRoadWindow = Duration(seconds: 6);
  static const Duration _roughRoadMinSpikeGap = Duration(milliseconds: 100);
  static const double _roughRoadMinSpeedKmh = 0.0;
  static const double _roughRoadMaxSpeedVarianceKmh = 14.0;
  static const double _crashSpikeThresholdG = 2.2;
  static const double _crashRotationThreshold = 2.0;
  static const Duration _crashMinImpactDuration = Duration(milliseconds: 20);
  static const double _crashFinalSpeedMaxKmh = 5.0;
  static const double _crashMinRapidDropKmh = 0.0;
  static const double _crashMinPreImpactSpeedKmh = 0.0;
  static const Duration _crashSpeedDropWindow = Duration(seconds: 3);
  static const double _overspeedThresholdKmh = 60.0;
  static const int _overspeedRequiredReadings = 2;
  static const double _maxReliableGpsAccuracyMeters = 9999.0;
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
  DateTime? _lastRoughRoadSpikeTime;
  DateTime? _potholeSpikeStart;
  double _potholePeakG = 0;
  DateTime? _crashImpactStart;
  double _crashImpactPeakG = 0;
  int _overspeedConsecutiveReadings = 0;

  double _gravityX = 0;
  double _gravityY = 0;
  double _gravityZ = 0;

  double _latestRotationRate = 0;
  double _latestSpeedKmh = 0;
  double _latestSpeedAccuracyMeters = 999;
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
            _latestSpeedAccuracyMeters = pos.accuracy;
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
    _gravityX =
        _gravityLowPassAlpha * _gravityX + (1 - _gravityLowPassAlpha) * event.x;
    _gravityY =
        _gravityLowPassAlpha * _gravityY + (1 - _gravityLowPassAlpha) * event.y;
    _gravityZ =
        _gravityLowPassAlpha * _gravityZ + (1 - _gravityLowPassAlpha) * event.z;

    final linearX = event.x - _gravityX;
    final linearY = event.y - _gravityY;
    final linearZ = event.z - _gravityZ;

    final linearMagnitudeG =
        math.sqrt(linearX * linearX + linearY * linearY + linearZ * linearZ) /
        _gravityMagnitude;

    _processPothole(now: now, linearMagnitudeG: linearMagnitudeG);
    _processRoughRoad(now: now, linearMagnitudeG: linearMagnitudeG);
    _processCrash(now: now, linearMagnitudeG: linearMagnitudeG);
  }

  void _processPothole({
    required DateTime now,
    required double linearMagnitudeG,
  }) {
    final inSpike = linearMagnitudeG > _potholeSpikeThresholdG;

    if (inSpike) {
      _potholeSpikeStart ??= now;
      if (linearMagnitudeG > _potholePeakG) {
        _potholePeakG = linearMagnitudeG;
      }
      return;
    }

    final spikeStart = _potholeSpikeStart;
    if (spikeStart == null) {
      return;
    }

    final duration = now.difference(spikeStart);
    final speedMaintained =
        _latestSpeedKmh > _potholeMinSpeedKmh &&
        _latestSpeedKmh < _potholeMaxSpeedKmh;
    final noMajorTilt = _latestRotationRate < _minimalRotationThreshold;
    final gpsReliable =
        _latestSpeedAccuracyMeters <= _maxReliableGpsAccuracyMeters;
    final durationMs = duration.inMilliseconds.toDouble();

    if (duration <= _potholeMaxDuration &&
        durationMs >= _potholeMinSpikeDurationMs &&
        speedMaintained &&
        noMajorTilt &&
        gpsReliable) {
      _checkPothole(_potholePeakG, duration);
    }

    _potholeSpikeStart = null;
    _potholePeakG = 0;
  }

  void _processRoughRoad({
    required DateTime now,
    required double linearMagnitudeG,
  }) {
    _pruneRoughRoadSamples(now);
    final gpsReliable =
        _latestSpeedAccuracyMeters <= _maxReliableGpsAccuracyMeters;
    if (_latestSpeedKmh < _roughRoadMinSpeedKmh || !gpsReliable) {
      return;
    }
    final isSpike =
        linearMagnitudeG >= _roughRoadMinSpikeG &&
        linearMagnitudeG <= _roughRoadMaxSpikeG;
    if (isSpike) {
      if (_lastRoughRoadSpikeTime != null &&
          now.difference(_lastRoughRoadSpikeTime!) < _roughRoadMinSpikeGap) {
        return;
      }
      _lastRoughRoadSpikeTime = now;
      _roughRoadSpikeTimes.add(now);
      _pruneRoughRoadSamples(now);
      if (_roughRoadSpikeTimes.length >= _roughRoadRequiredSpikes) {
        _checkRoughRoad(now);
      }
    }
  }

  void _processCrash({
    required DateTime now,
    required double linearMagnitudeG,
  }) {
    if (linearMagnitudeG >= _crashSpikeThresholdG) {
      _crashImpactStart ??= now;
      if (linearMagnitudeG > _crashImpactPeakG) {
        _crashImpactPeakG = linearMagnitudeG;
      }
      return;
    }

    final impactStart = _crashImpactStart;
    if (impactStart == null) {
      return;
    }

    final duration = now.difference(impactStart);
    final speedDroppedRapidly = _hasRapidSpeedDrop(now);
    final preImpactSpeedOk =
        _maxSpeedInCrashWindow(now) >= _crashMinPreImpactSpeedKmh;
    final finalSpeedLow = _latestSpeedKmh <= _crashFinalSpeedMaxKmh;
    final tiltDetected = _latestRotationRate >= _crashRotationThreshold;
    final gpsReliable =
        _latestSpeedAccuracyMeters <= _maxReliableGpsAccuracyMeters;

    if (duration >= _crashMinImpactDuration &&
        preImpactSpeedOk &&
        speedDroppedRapidly &&
        finalSpeedLow &&
        tiltDetected &&
        gpsReliable) {
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
    final gpsReliable =
        _latestSpeedAccuracyMeters <= _maxReliableGpsAccuracyMeters;
    if (!gpsReliable || speedKmh < _overspeedThresholdKmh) {
      _overspeedConsecutiveReadings = 0;
      return;
    }

    _overspeedConsecutiveReadings++;
    if (_overspeedConsecutiveReadings < _overspeedRequiredReadings) {
      return;
    }

    final now = DateTime.now().toUtc();
    if (_lastOverspeedTime != null &&
        now.difference(_lastOverspeedTime!) < _overspeedCooldown) {
      return;
    }
    _lastOverspeedTime = now;
    _overspeedConsecutiveReadings = 0;

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
    if (_crashMinRapidDropKmh <= 0) {
      return true;
    }
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

  double _maxSpeedInCrashWindow(DateTime now) {
    if (_speedHistory.isEmpty) {
      return 0;
    }

    var maxRecentSpeed = 0.0;
    for (final sample in _speedHistory) {
      if (now.difference(sample.timestamp) > _crashSpeedDropWindow) {
        continue;
      }
      if (sample.speedKmh > maxRecentSpeed) {
        maxRecentSpeed = sample.speedKmh;
      }
    }
    return maxRecentSpeed;
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
