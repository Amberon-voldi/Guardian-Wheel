import 'dart:async';

import 'package:flutter/material.dart';
import 'package:appwrite/appwrite.dart';

import '../config/env_config.dart';
import '../controller/alert_controller.dart';
import '../controller/admin_controller.dart';
import '../controller/ride_controller.dart';
import '../model/ride_status.dart';
import '../screens/hazard_report_screen.dart';
import '../screens/admin_view_screen.dart';
import '../screens/mesh_alerts_screen.dart';
import '../screens/red_alert_screen.dart';
import '../screens/rider_profile_screen.dart';
import '../screens/sos_command_screen.dart';
import '../screens/tactical_map_screen.dart';
import '../service/ble_mesh_service.dart';
import '../service/location_service.dart';
import '../service/mesh_service.dart';
import '../service/ride_service.dart';
import '../service/safety_service.dart';
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
  late final SyncService _syncService;
  late final RideController _rideController;
  late final AlertController _alertController;
  late final UserProfileService _userProfileService;

  StreamSubscription<RideNavigationEvent>? _rideNavigationSub;
  StreamSubscription<RideStatus>? _rideStatusSub;
  StreamSubscription<int>? _meshPeerCountSub;
  StreamSubscription<LocationPoint>? _locationMeshNodeSub;

  late final String _currentRiderId;
  int _currentTab = 0;

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
      bleMesh: BleMeshService(),
      databases: _databases,
      databaseId: EnvConfig.appwriteDatabaseId,
      meshNodesCollectionId: EnvConfig.meshNodesCollection,
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

    // Start BLE mesh scanning
    _meshService.startBleMesh(currentUserId: _currentRiderId);

    _rideNavigationSub = _rideController.navigationEvents.listen((event) {
      if (!mounted) return;
      if (event.type == RideNavigationEventType.openAlert) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const RedAlertScreen()),
        );
      }
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
              ),
            ],
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
                                color: GuardianTheme.danger
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.emergency,
                                  color: GuardianTheme.danger, size: 22),
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
                                        fontSize: 16),
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
                                onPressed:
                                    _alertController.dismissIncomingHelp,
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
                                icon:
                                    const Icon(Icons.navigation, size: 18),
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

  @override
  void dispose() {
    _rideNavigationSub?.cancel();
    _rideStatusSub?.cancel();
    _meshPeerCountSub?.cancel();
    _locationMeshNodeSub?.cancel();
    _alertController.dispose();
    _rideController.dispose();
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
