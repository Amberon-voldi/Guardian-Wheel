import 'dart:async';

import 'package:flutter/material.dart';
import 'package:appwrite/appwrite.dart';
import 'package:audioplayers/audioplayers.dart';

import '../config/env_config.dart';
import '../controller/alert_controller.dart';
import '../controller/admin_controller.dart';
import '../controller/ride_controller.dart';
import '../model/ride_status.dart';
import '../model/in_app_notification.dart';
import '../screens/hazard_report_screen.dart';
import '../screens/admin_view_screen.dart';
import '../screens/mesh_alerts_screen.dart';
import '../screens/red_alert_screen.dart';
import '../screens/rider_profile_screen.dart';
import '../screens/sensor_detections_screen.dart';
import '../screens/sos_command_screen.dart';
import '../screens/tactical_map_screen.dart';
import '../service/location_service.dart';
import '../service/mesh_service.dart';
import '../service/ride_service.dart';
import '../service/safety_service.dart';
import '../service/sensor_detection_service.dart';
import '../service/sync_service.dart';
import '../service/user_profile_service.dart';
import '../theme/guardian_theme.dart';
import '../widgets/guardian_bottom_nav.dart';

class GuardianWheelApp extends StatelessWidget {
  const GuardianWheelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guardian Wheel',
      theme: GuardianTheme.lightTheme(),
      themeMode: ThemeMode.light,
      home: const GuardianShell(),
    );
  }
}

class GuardianShell extends StatefulWidget {
  const GuardianShell({super.key});

  @override
  State<GuardianShell> createState() => _GuardianShellState();
}

class _GuardianShellState extends State<GuardianShell> {
  late final Client _client;
  late final Databases _databases;
  late final Account _account;
  late final Realtime _realtime;

  late final MeshService _meshService;
  late final LocationService _locationService;
  late final RideService _rideService;
  late final SafetyService _safetyService;
  late final SensorDetectionService _sensorDetectionService;
  late final SyncService _syncService;
  late final RideController _rideController;
  late final AlertController _alertController;
  late final UserProfileService _userProfileService;

  StreamSubscription<RideNavigationEvent>? _rideNavigationSub;
  StreamSubscription<RideCrashCountdownEvent>? _crashCountdownSub;
  StreamSubscription<RideStatus>? _rideStatusSub;
  StreamSubscription<int>? _meshPeerCountSub;
  StreamSubscription<LocationPoint>? _locationMeshNodeSub;
  StreamSubscription<HazardDetectionEvent>? _hazardDetectionSub;

  late final String _currentRiderId;
  int _currentTab = 1;
  final List<HazardDetectionEvent> _hazardDetections = [];
  InAppNotification? _activeNotification;
  Timer? _notificationTimer;
  final ValueNotifier<int> _crashCountdownSeconds = ValueNotifier<int>(10);
  bool _isCrashCountdownVisible = false;
  final AudioPlayer _alarmPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();

    // Appwrite client
    _client = Client()
        .setEndpoint(EnvConfig.appwriteEndpoint)
        .setProject(EnvConfig.appwriteProjectId);
    _databases = Databases(_client);
    _account = Account(_client);
    _realtime = Realtime(_client);
    _currentRiderId = EnvConfig.appUserId;

    _ensureSession();

    // Services
    _locationService = LocationService();
    _meshService = MeshService(
      databases: _databases,
      databaseId: EnvConfig.appwriteDatabaseId,
      meshNodesCollectionId: EnvConfig.meshNodesCollection,
      gatewayPacketsCollectionId: EnvConfig.alertsCollection,
    );
    _userProfileService = UserProfileService(databases: _databases);

    _rideService = RideService(
      databases: _databases,
      realtime: _realtime,
      databaseId: EnvConfig.appwriteDatabaseId,
      ridesCollectionId: EnvConfig.ridesCollection,
    );

    _safetyService = SafetyService(
      databases: _databases,
      rideService: _rideService,
      databaseId: EnvConfig.appwriteDatabaseId,
      alertsCollectionId: EnvConfig.alertsCollection,
    );

    _syncService = SyncService(databases: _databases);
    _syncService.start();

    _sensorDetectionService = SensorDetectionService(
      locationProvider: _locationService.getCurrentLocation,
    )..startMonitoring();

    _rideController = RideController(
      userId: _currentRiderId,
      locationService: _locationService,
      rideService: _rideService,
      safetyService: _safetyService,
      meshService: _meshService,
    );

    _alertController = AlertController(
      meshService: _meshService,
      currentRiderId: _currentRiderId,
    )..startListening();

    _meshService.startMesh(currentUserId: _currentRiderId);

    _rideNavigationSub = _rideController.navigationEvents.listen((event) {
      if (!mounted) return;
      if (event.type == RideNavigationEventType.openAlert) {
        unawaited(_stopAlarm());
        _dismissCrashCountdownDialog();
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const RedAlertScreen()));
      }
    });

    _crashCountdownSub = _rideController.crashCountdownEvents.listen((event) {
      if (!mounted) return;
      if (event.type == RideCrashCountdownEventType.started) {
        unawaited(_startAlarm());
        _crashCountdownSeconds.value = event.secondsRemaining;
        _showCrashCountdownDialog();
        return;
      }
      if (event.type == RideCrashCountdownEventType.tick) {
        _crashCountdownSeconds.value = event.secondsRemaining;
        return;
      }
      unawaited(_stopAlarm());
      _dismissCrashCountdownDialog();
    });

    _rideStatusSub = _rideController.statusStream.listen((_) {
      if (mounted) setState(() {});
    });

    _meshPeerCountSub = _meshService.peerCountStream.listen((_) {
      if (mounted) setState(() {});
    });

    _locationMeshNodeSub = _locationService.locationStream.listen((point) {
      _meshService.updateSelfNode(
        userId: _currentRiderId,
        lat: point.lat,
        lng: point.lng,
        isActive: true,
      );
    });

    _hazardDetectionSub = _sensorDetectionService.hazardStream.listen((
      hazardEvent,
    ) {
      if (!mounted) return;
      _hazardDetections.insert(0, hazardEvent);
      if (_hazardDetections.length > 250) {
        _hazardDetections.removeRange(250, _hazardDetections.length);
      }
      _showDetectionNotification(hazardEvent);
    });
  }

  Future<void> _ensureSession() async {
    try {
      await _account.get();
    } catch (_) {
      try {
        await _account.createAnonymousSession();
      } catch (_) {
        // Non-blocking: app remains offline-first.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── Tab pages ──
          IndexedStack(
            index: _currentTab,
            children: [
              // Tab 0: Map
              AnimatedBuilder(
                animation: _alertController,
                builder: (_, __) => TacticalMapScreen(
                  onReportHazard: _openHazardReport,
                  incomingRoute: _alertController.navigationRoute,
                  locationService: _locationService,
                  sensorDetectionService: _sensorDetectionService,
                  currentRiderId: _currentRiderId,
                  isActive: _currentTab == 0,
                  databases: _databases,
                ),
              ),

              // Tab 1: Ride / SOS
              SosCommandScreen(
                onOpenRedAlert: _triggerManualSos,
                onStartRide: _startRide,
                onEndRide: _endRide,
                onSimulateCrash: () => _locationService.simulateCrash(),
                rideStatus: _rideController.status,
                meshPeerCount: _meshService.peerCount,
                locationService: _locationService,
              ),

              // Tab 2: Mesh Alerts
              MeshAlertsScreen(
                onOpenAdmin: _openAdminView,
                meshService: _meshService,
                alertController: _alertController,
              ),

              // Tab 3: Profile
              RiderProfileScreen(
                userId: _currentRiderId,
                userProfileService: _userProfileService,
                onOpenDetectionsPage: _openDetectionsPage,
              ),
            ],
          ),

          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: SafeArea(
              child: _TopDropNotificationCard(
                notification: _activeNotification,
                onPrimaryAction: _openDetectionsPage,
                onSecondaryAction: _dismissNotification,
              ),
            ),
          ),

          // ── Incoming help request overlay ──
          AnimatedBuilder(
            animation: _alertController,
            builder: (_, __) {
              if (!_alertController.showIncomingHelpUi ||
                  _alertController.incomingPacket == null) {
                return const SizedBox.shrink();
              }
              final packet = _alertController.incomingPacket!;
              return Positioned(
                left: 16,
                right: 16,
                bottom: 100,
                child: Material(
                  elevation: 8,
                  shadowColor: GuardianTheme.danger.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: GuardianTheme.danger.withValues(
                                  alpha: 0.1,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.emergency,
                                color: GuardianTheme.danger,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Incoming Help Request',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Rider: ${packet.origin} • Hop: ${packet.hop}',
                                    style: const TextStyle(
                                      color: GuardianTheme.textSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _alertController.dismissIncomingHelp,
                                child: const Text('Dismiss'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () {
                                  _alertController.acceptIncomingHelp(
                                    currentLat:
                                        _rideController.latestLocation?.lat ??
                                        12.9716,
                                    currentLng:
                                        _rideController.latestLocation?.lng ??
                                        77.5946,
                                  );
                                  // Switch to map tab to show route
                                  setState(() => _currentTab = 0);
                                },
                                icon: const Icon(Icons.navigation, size: 18),
                                label: const Text('Accept & Route'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: GuardianBottomNav(
        currentIndex: _currentTab,
        onTap: (i) => setState(() => _currentTab = i),
      ),
    );
  }

  // ── Actions ──

  Future<void> _startRide() async {
    await _rideController.startRide();
    setState(() {});
  }

  Future<void> _endRide() async {
    await _rideController.endRide();
    setState(() {});
  }

  Future<void> _triggerManualSos() async {
    await _rideController.triggerManualSos();
  }

  void _openHazardReport() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HazardReportScreen(
          databases: _databases,
          userId: _currentRiderId,
          locationService: _locationService,
        ),
      ),
    );
  }

  void _openAdminView() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminViewScreen(
          controller: AdminController(meshService: _meshService),
        ),
      ),
    );
  }

  void _openDetectionsPage() {
    _dismissNotification();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SensorDetectionsScreen(
          sensorDetectionService: _sensorDetectionService,
          initialEvents: List<HazardDetectionEvent>.from(_hazardDetections),
        ),
      ),
    );
  }

  void _showDetectionNotification(HazardDetectionEvent event) {
    final accuracy = (event.severity * 100).clamp(0, 100).round();
    final title = switch (event.type) {
      HazardType.pothole => 'Pothole Detected',
      HazardType.roughRoad => 'Rough Road Detected',
      HazardType.crashRisk => 'Crash Risk Detected',
      HazardType.overspeed => 'Over Speed Detected',
    };

    final notificationType = switch (event.type) {
      HazardType.pothole => InAppNotificationType.warning,
      HazardType.roughRoad => InAppNotificationType.warning,
      HazardType.crashRisk => InAppNotificationType.danger,
      HazardType.overspeed => InAppNotificationType.info,
    };

    _notificationTimer?.cancel();
    setState(() {
      _activeNotification = InAppNotification(
        id: 'hazard_${event.timestamp.microsecondsSinceEpoch}',
        title: title,
        message: '${event.description} • Accuracy $accuracy%',
        type: notificationType,
        createdAt: DateTime.now().toUtc(),
        primaryActionLabel: 'View',
        secondaryActionLabel: 'Dismiss',
        confidence: accuracy / 100,
      );
    });

    _notificationTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() {
        _activeNotification = null;
      });
    });
  }

  void _dismissNotification() {
    _notificationTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _activeNotification = null;
    });
  }

  void _showCrashCountdownDialog() {
    if (_isCrashCountdownVisible || !mounted) {
      return;
    }
    _isCrashCountdownVisible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return ValueListenableBuilder<int>(
          valueListenable: _crashCountdownSeconds,
          builder: (context, remaining, _) {
            return AlertDialog(
              title: const Text('Crash detected'),
              content: Text(
                'Sending SOS in $remaining seconds. Tap cancel if you are safe.',
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _rideController.cancelPendingCrashSos();
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Cancel SOS'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      _isCrashCountdownVisible = false;
    });
  }

  void _dismissCrashCountdownDialog() {
    if (!_isCrashCountdownVisible || !mounted) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _startAlarm() async {
    try {
      await _alarmPlayer.setReleaseMode(ReleaseMode.loop);
      await _alarmPlayer.play(AssetSource('sound/alarm.mp3'));
    } catch (_) {
      // Keep countdown flow even if alarm audio fails.
    }
  }

  Future<void> _stopAlarm() async {
    try {
      await _alarmPlayer.stop();
    } catch (_) {
      // no-op
    }
  }

  @override
  void dispose() {
    unawaited(_stopAlarm());
    _alarmPlayer.dispose();
    _rideNavigationSub?.cancel();
    _crashCountdownSub?.cancel();
    _rideStatusSub?.cancel();
    _meshPeerCountSub?.cancel();
    _locationMeshNodeSub?.cancel();
    _hazardDetectionSub?.cancel();
    _notificationTimer?.cancel();
    _crashCountdownSeconds.dispose();
    _alertController.dispose();
    _rideController.dispose();
    _sensorDetectionService.dispose();
    _meshService.updateSelfNode(
      userId: _currentRiderId,
      lat: _rideController.latestLocation?.lat ?? 0,
      lng: _rideController.latestLocation?.lng ?? 0,
      isActive: false,
    );
    _locationService.dispose();
    _safetyService.dispose();
    _meshService.dispose();
    _syncService.dispose();
    super.dispose();
  }
}

class _TopDropNotificationCard extends StatelessWidget {
  const _TopDropNotificationCard({
    required this.notification,
    required this.onPrimaryAction,
    required this.onSecondaryAction,
  });

  final InAppNotification? notification;
  final VoidCallback onPrimaryAction;
  final VoidCallback onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final active = notification != null;
    final theme = Theme.of(context);

    Color accentColor() {
      return switch (notification?.type) {
        InAppNotificationType.warning => GuardianTheme.warning,
        InAppNotificationType.success => GuardianTheme.success,
        InAppNotificationType.danger => GuardianTheme.danger,
        _ => GuardianTheme.accentBlue,
      };
    }

    final accent = accentColor();

    return IgnorePointer(
      ignoring: !active,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        offset: active ? Offset.zero : const Offset(0, -1.4),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: active ? 1 : 0,
          child: Material(
            elevation: 8,
            shadowColor: Colors.black.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
            color: Colors.white,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: 0.2)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: notification == null
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.notifications_active,
                                color: accent,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                notification!.title,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (notification!.confidence != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${(notification!.confidence! * 100).round()}%',
                                  style: TextStyle(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          notification!.message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: GuardianTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            TextButton(
                              onPressed: onSecondaryAction,
                              child: Text(
                                notification!.secondaryActionLabel ?? 'Dismiss',
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: onPrimaryAction,
                              child: Text(
                                notification!.primaryActionLabel ?? 'View',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
