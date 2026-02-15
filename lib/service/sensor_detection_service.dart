import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import 'location_service.dart';

// ── Models ───────────────────────────────────────────────────────────

enum HazardType { pothole, roughRoad }

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

  // Thresholds (values in m/s²)
  static const double _gravityMagnitude = 9.81;
  static const double _potholeThreshold = 18.0; // ~1.8 G spike
  static const double _roughRoadRmsThreshold = 3.5;
  static const int _roughRoadWindowSize = 30; // ~3 s at 100 ms sampling
  static const Duration _potholeCooldown = Duration(seconds: 5);
  static const Duration _roughRoadCooldown = Duration(seconds: 15);

  final List<double> _accelDeviations = [];
  DateTime? _lastPotholeTime;
  DateTime? _lastRoughRoadTime;
  bool _monitoring = false;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  final StreamController<HazardDetectionEvent> _controller =
      StreamController<HazardDetectionEvent>.broadcast();

  Stream<HazardDetectionEvent> get hazardStream => _controller.stream;
  bool get isMonitoring => _monitoring;

  // ── Lifecycle ────────────────────────────────────────────────────

  void startMonitoring() {
    if (_monitoring) return;
    _monitoring = true;
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen(_process);
  }

  void stopMonitoring() {
    _monitoring = false;
    _accelSub?.cancel();
    _accelSub = null;
    _accelDeviations.clear();
  }

  Future<void> dispose() async {
    stopMonitoring();
    if (!_controller.isClosed) await _controller.close();
  }

  // ── Processing ───────────────────────────────────────────────────

  void _process(AccelerometerEvent event) {
    final magnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    final deviation = (magnitude - _gravityMagnitude).abs();

    // Pothole / bump detection – single sharp spike
    if (magnitude > _potholeThreshold) {
      _checkPothole(magnitude);
    }

    // Rough road – sustained vibration over a sliding window
    _accelDeviations.add(deviation);
    if (_accelDeviations.length > _roughRoadWindowSize) {
      _accelDeviations.removeAt(0);
    }
    if (_accelDeviations.length == _roughRoadWindowSize) {
      _checkRoughRoad();
    }
  }

  void _checkPothole(double impact) {
    final now = DateTime.now().toUtc();
    if (_lastPotholeTime != null &&
        now.difference(_lastPotholeTime!) < _potholeCooldown) {
      return;
    }
    _lastPotholeTime = now;

    final severity = ((impact - _potholeThreshold) / 12.0).clamp(0.2, 1.0);
    _emitHazard(
      type: HazardType.pothole,
      severity: severity,
      description:
          'Pothole or bump detected (${impact.toStringAsFixed(1)} m/s\u00B2)',
      impactValue: impact,
    );
  }

  void _checkRoughRoad() {
    final now = DateTime.now().toUtc();
    if (_lastRoughRoadTime != null &&
        now.difference(_lastRoughRoadTime!) < _roughRoadCooldown) {
      return;
    }

    final sumSq =
        _accelDeviations.fold<double>(0, (sum, d) => sum + d * d);
    final rms = math.sqrt(sumSq / _accelDeviations.length);

    if (rms > _roughRoadRmsThreshold) {
      _lastRoughRoadTime = now;
      final severity = ((rms - _roughRoadRmsThreshold) / 5.0).clamp(0.2, 1.0);
      _emitHazard(
        type: HazardType.roughRoad,
        severity: severity,
        description:
            'Rough road surface detected (vibration ${rms.toStringAsFixed(1)})',
        impactValue: rms,
      );
    }
  }

  Future<void> _emitHazard({
    required HazardType type,
    required double severity,
    required String description,
    double impactValue = 0,
  }) async {
    if (_controller.isClosed) return;
    try {
      final loc = await locationProvider();
      _controller.add(HazardDetectionEvent(
        type: type,
        lat: loc.lat,
        lng: loc.lng,
        severity: severity,
        timestamp: DateTime.now().toUtc(),
        description: description,
        impactValue: impactValue,
      ));
    } catch (_) {
      // Location unavailable – skip this event.
    }
  }
}
