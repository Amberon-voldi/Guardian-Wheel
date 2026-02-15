import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Keys used to communicate between the background isolate and the UI.
class BgKeys {
  static const String locationUpdate = 'location_update';
  static const String crashDetected = 'crash_detected';
  static const String telemetryUpdate = 'telemetry_update';
  static const String motionUpdate = 'motion_update';
  static const String stopService = 'stop_service';
  static const String startTracking = 'start_tracking';
  static const String stopTracking = 'stop_tracking';
  static const String simulateCrash = 'simulate_crash';
}

/// Notification channel for the Android foreground service.
const String _notificationChannelId = 'guardian_wheel_bg';
const int _notificationId = 888;

/// Initialise and configure the background service.
/// Call this once from main() before runApp.
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // Android notification channel for the foreground service
  const androidChannel = AndroidNotificationChannel(
    _notificationChannelId,
    'Guardian Wheel Background',
    description: 'Crash detection & ride tracking running in background',
    importance: Importance.low,
  );

  final flnPlugin = FlutterLocalNotificationsPlugin();
  await flnPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: _notificationChannelId,
      initialNotificationTitle: 'Guardian Wheel',
      initialNotificationContent: 'Monitoring ride safety...',
      foregroundServiceNotificationId: _notificationId,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: _onStart,
      onBackground: _onIosBackground,
    ),
  );
}

/// iOS background fetch entry‐point. Must be a top-level function.
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// Main background isolate entry-point.
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // ---- state ----------------------------------------------------------
  StreamSubscription<Position>? positionSub;
  StreamSubscription<AccelerometerEvent>? accelSub;
  StreamSubscription<GyroscopeEvent>? gyroSub;
  Timer? telemetryTimer;

  double maxSpeed = 0;
  double totalSpeed = 0;
  int speedSamples = 0;
  double lastLat = 0;
  double lastLng = 0;
  double lastSpeed = 0;
  double lastGyroMagnitude = 0;
  DateTime? lastCrashTime;

  const double crashThresholdG = 4.0;
  const double crashThresholdWithRotationG = 3.0;
  const double rotationCrashThreshold = 5.0;
  const crashCooldown = Duration(seconds: 10);

  // ---- helpers --------------------------------------------------------
  void sendLocation(Position pos) {
    lastLat = pos.latitude;
    lastLng = pos.longitude;
    lastSpeed = pos.speed;

    final speedKmh = pos.speed * 3.6;
    if (speedKmh > 0) {
      if (speedKmh > maxSpeed) maxSpeed = speedKmh;
      totalSpeed += speedKmh;
      speedSamples++;
    }

    service.invoke(BgKeys.locationUpdate, {
      'lat': pos.latitude,
      'lng': pos.longitude,
      'speed': pos.speed,
      'accuracy': pos.accuracy,
      'timestamp': (pos.timestamp).millisecondsSinceEpoch,
    });
  }

  void sendTelemetry() {
    service.invoke(BgKeys.telemetryUpdate, {
      'maxSpeed': maxSpeed,
      'avgSpeed': speedSamples > 0 ? totalSpeed / speedSamples : 0.0,
      'speedSamples': speedSamples,
      'gyroMagnitude': lastGyroMagnitude,
      'isMoving': (lastSpeed * 3.6) > 1.5 || lastGyroMagnitude > 0.8,
    });
  }

  void handleCrash(double impactG, {double? rotationRate}) {
    final now = DateTime.now().toUtc();
    if (lastCrashTime != null && now.difference(lastCrashTime!) < crashCooldown) {
      return;
    }
    lastCrashTime = now;

    final rotation = rotationRate ?? lastGyroMagnitude;

    final severity = impactG >= 8.0
        ? 'critical'
        : impactG >= 6.0 || rotation >= 8.0
            ? 'high'
            : 'medium';

    service.invoke(BgKeys.crashDetected, {
      'lat': lastLat,
      'lng': lastLng,
      'speed': lastSpeed,
      'impactG': impactG,
      'rotationRate': rotation,
      'severity': severity,
      'timestamp': now.millisecondsSinceEpoch,
    });

    // Update notification to show crash detected
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: '⚠️ CRASH DETECTED',
        content: 'Impact: ${impactG.toStringAsFixed(1)}G • Rot: ${rotation.toStringAsFixed(1)} — Emergency alert sent',
      );
    }
  }

  // ---- start GPS + accelerometer --------------------------------------
  void startSensors() {
    // GPS
    positionSub?.cancel();
    positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      sendLocation,
      onError: (_) {},
    );

    // Accelerometer for crash detection
    accelSub?.cancel();
    accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      final gForce = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          ) /
          9.81;

      final likelyCrash = gForce >= crashThresholdG ||
          (gForce >= crashThresholdWithRotationG &&
              lastGyroMagnitude >= rotationCrashThreshold);

      if (likelyCrash) {
        handleCrash(gForce, rotationRate: lastGyroMagnitude);
      }
    });

    // Gyroscope for movement + orientation change monitoring
    gyroSub?.cancel();
    gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      lastGyroMagnitude =
          math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

      service.invoke(BgKeys.motionUpdate, {
        'rotationRate': lastGyroMagnitude,
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
    });

    // Periodic telemetry push every 5s
    telemetryTimer?.cancel();
    telemetryTimer = Timer.periodic(const Duration(seconds: 5), (_) => sendTelemetry());

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Guardian Wheel',
        content: 'Ride tracking & crash detection active',
      );
    }
  }

  void stopSensors() {
    positionSub?.cancel();
    positionSub = null;
    accelSub?.cancel();
    accelSub = null;
    gyroSub?.cancel();
    gyroSub = null;
    telemetryTimer?.cancel();
    telemetryTimer = null;
    maxSpeed = 0;
    totalSpeed = 0;
    speedSamples = 0;
    lastGyroMagnitude = 0;

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Guardian Wheel',
        content: 'Monitoring paused',
      );
    }
  }

  // ---- command listeners from UI ------------------------------------
  service.on(BgKeys.startTracking).listen((_) {
    startSensors();
  });

  service.on(BgKeys.stopTracking).listen((_) {
    stopSensors();
  });

  service.on(BgKeys.simulateCrash).listen((_) {
    handleCrash(6.0, rotationRate: lastGyroMagnitude);
  });

  service.on(BgKeys.stopService).listen((_) {
    stopSensors();
    service.stopSelf();
  });

  // Auto-start sensors immediately when service starts
  startSensors();
}
