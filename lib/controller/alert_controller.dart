import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../model/mesh_packet.dart';
import '../service/mesh_service.dart';

class AlertController extends ChangeNotifier {
  AlertController({
    required MeshService meshService,
    required this.currentRiderId,
  }) : _meshService = meshService;

  final MeshService _meshService;
  final String currentRiderId;

  StreamSubscription<MeshPacketState>? _packetSubscription;

  MeshPacketState? _latestPacketState;
  MeshPacket? _incomingPacket;
  bool _showIncomingHelpUi = false;
  bool _acceptedIncomingHelp = false;
  AlertRoute? _navigationRoute;

  MeshPacketState? get latestPacketState => _latestPacketState;
  MeshPacket? get incomingPacket => _incomingPacket;
  bool get showIncomingHelpUi => _showIncomingHelpUi;
  bool get acceptedIncomingHelp => _acceptedIncomingHelp;
  AlertRoute? get navigationRoute => _navigationRoute;

  void startListening() {
    _packetSubscription ??= _meshService.packetStates.listen(_onPacketState);
  }

  Future<void> stopListening() async {
    await _packetSubscription?.cancel();
    _packetSubscription = null;
  }

  void _onPacketState(MeshPacketState state) {
    _latestPacketState = state;

    final packet = state.packet;
    final fromCurrentRider = packet.origin == currentRiderId;
    if (fromCurrentRider) {
      notifyListeners();
      return;
    }

    if (state.status == MeshPacketStatus.expired || state.status == MeshPacketStatus.duplicateDropped) {
      return;
    }

    _incomingPacket = packet;
    _showIncomingHelpUi = true;
    _acceptedIncomingHelp = false;
    _navigationRoute = null;
    notifyListeners();
  }

  void dismissIncomingHelp() {
    _showIncomingHelpUi = false;
    notifyListeners();
  }

  AlertRoute? acceptIncomingHelp({
    required double currentLat,
    required double currentLng,
  }) {
    final packet = _incomingPacket;
    if (packet == null) {
      return null;
    }

    _acceptedIncomingHelp = true;
    _showIncomingHelpUi = false;
    _navigationRoute = _buildRoute(
      fromLat: currentLat,
      fromLng: currentLng,
      toLat: packet.lat,
      toLng: packet.lng,
    );
    notifyListeners();
    return _navigationRoute;
  }

  AlertRoute _buildRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) {
    final distanceKm = _haversineKm(fromLat, fromLng, toLat, toLng);

    final waypoints = <AlertRoutePoint>[
      AlertRoutePoint(lat: fromLat, lng: fromLng),
      AlertRoutePoint(lat: toLat, lng: toLng),
    ];

    return AlertRoute(
      waypoints: waypoints,
      distanceKm: distanceKm,
      estimatedMinutes: _estimateMinutes(distanceKm),
    );
  }

  int _estimateMinutes(double distanceKm) {
    const avgKmPerHour = 25.0;
    final minutes = (distanceKm / avgKmPerHour) * 60;
    return minutes.clamp(1, 180).round();
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degToRad(double degree) => degree * math.pi / 180.0;

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}

class AlertRoute {
  const AlertRoute({
    required this.waypoints,
    required this.distanceKm,
    required this.estimatedMinutes,
  });

  final List<AlertRoutePoint> waypoints;
  final double distanceKm;
  final int estimatedMinutes;
}

class AlertRoutePoint {
  const AlertRoutePoint({
    required this.lat,
    required this.lng,
  });

  final double lat;
  final double lng;
}