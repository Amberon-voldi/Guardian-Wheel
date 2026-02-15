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
  int index = 0;

  late final Client _client;
  late final Databases _databases;
  late final Realtime _realtime;

  late final MeshService _meshService;
  late final LocationService _locationService;
  late final RideService _rideService;
  late final SafetyService _safetyService;
  late final SyncService _syncService;
  late final RideController _rideController;
  late final AlertController _alertController;

  StreamSubscription<RideNavigationEvent>? _rideNavigationSub;
  StreamSubscription<RideStatus>? _rideStatusSub;

  static const String _currentRiderId = 'RIDER-KA-05-9922';

  @override
  void initState() {
    super.initState();

    // Appwrite client
    _client = Client()
        .setEndpoint(EnvConfig.appwriteEndpoint)
        .setProject(EnvConfig.appwriteProjectId);
    _databases = Databases(_client);
    _realtime = Realtime(_client);

    // Services
    _locationService = LocationService();
    _meshService = MeshService(bleMesh: BleMeshService());

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
    _meshService.startBleMesh();

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
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      AnimatedBuilder(
        animation: Listenable.merge([_alertController]),
        builder: (_, __) => SosCommandScreen(
          onOpenRedAlert: _triggerManualSos,
          onStartRide: _startRide,
          onEndRide: _endRide,
          onSimulateCrash: () => _locationService.simulateCrash(),
          rideStatus: _rideController.status,
          meshPeerCount: _meshService.peerCount,
          locationService: _locationService,
        ),
      ),
      AnimatedBuilder(
        animation: _alertController,
        builder: (_, __) => TacticalMapScreen(
          onReportHazard: _openHazardReport,
          incomingRoute: _alertController.navigationRoute,
          locationService: _locationService,
        ),
      ),
      MeshAlertsScreen(
        onOpenAdmin: _openAdminView,
        meshService: _meshService,
        alertController: _alertController,
      ),
      const RiderProfileScreen(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(index: index, children: screens),
          // Incoming help overlay
          AnimatedBuilder(
            animation: _alertController,
            builder: (_, __) {
              if (!_alertController.showIncomingHelpUi || _alertController.incomingPacket == null) {
                return const SizedBox.shrink();
              }
              final packet = _alertController.incomingPacket!;
              return Positioned(
                left: 12,
                right: 12,
                bottom: 90,
                child: Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.emergency, color: Theme.of(context).colorScheme.error, size: 20),
                            const SizedBox(width: 8),
                            const Text('Incoming Help Request', style: TextStyle(fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('Rider: ${packet.origin} • Hop: ${packet.hop}'),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _alertController.dismissIncomingHelp,
                                child: const Text('Dismiss'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () {
                                  _alertController.acceptIncomingHelp(
                                    currentLat: _rideController.latestLocation?.lat ?? 12.9716,
                                    currentLng: _rideController.latestLocation?.lng ?? 77.5946,
                                  );
                                  setState(() => index = 1);
                                },
                                child: const Text('Accept & Route'),
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
        currentIndex: index,
        onTap: (value) => setState(() => index = value),
      ),
    );
  }

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
    _alertController.dispose();
    _rideController.dispose();
    _locationService.dispose();
    _safetyService.dispose();
    _meshService.dispose();
    _syncService.dispose();
    super.dispose();
  }
}