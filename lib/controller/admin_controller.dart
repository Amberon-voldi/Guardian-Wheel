import 'dart:async';

import '../model/mesh_packet.dart';
import '../service/mesh_service.dart';

class AdminController {
  AdminController({
    required MeshService meshService,
    this.refreshInterval = const Duration(seconds: 5),
  }) : _meshService = meshService;

  final MeshService _meshService;
  final Duration refreshInterval;

  final StreamController<AdminDashboardState> _stateController =
      StreamController<AdminDashboardState>.broadcast();

  final Map<String, AdminEmergencyItem> _itemsByPacketId = {};

  StreamSubscription<MeshPacketState>? _packetSub;
  Timer? _refreshTimer;

  AdminDashboardState _latestState = const AdminDashboardState(
    activeEmergencies: 0,
    items: [],
    updatedAt: null,
  );

  Stream<AdminDashboardState> get stream => _stateController.stream;
  AdminDashboardState get currentState => _latestState;

  void start() {
    _packetSub ??= _meshService.packetStates.listen(_onPacketState);
    _refreshTimer ??= Timer.periodic(refreshInterval, (_) => _publishState());
    _publishState();
  }

  Future<void> stop() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _packetSub?.cancel();
    _packetSub = null;
  }

  void _onPacketState(MeshPacketState state) {
    final packet = state.packet;
    final resolved = state.status == MeshPacketStatus.delivered ||
        state.status == MeshPacketStatus.expired ||
        state.status == MeshPacketStatus.duplicateDropped;

    _itemsByPacketId[packet.id] = AdminEmergencyItem(
      packetId: packet.id,
      riderId: packet.origin,
      hopCount: packet.hop,
      timestamp: state.timestamp,
      resolved: resolved,
    );

    _publishState();
  }

  void _publishState() {
    final items = _itemsByPacketId.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final activeEmergencies = items.where((item) => !item.resolved).length;

    _latestState = AdminDashboardState(
      activeEmergencies: activeEmergencies,
      items: items,
      updatedAt: DateTime.now().toUtc(),
    );

    if (!_stateController.isClosed) {
      _stateController.add(_latestState);
    }
  }

  Future<void> dispose() async {
    await stop();
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }
}

class AdminDashboardState {
  const AdminDashboardState({
    required this.activeEmergencies,
    required this.items,
    required this.updatedAt,
  });

  final int activeEmergencies;
  final List<AdminEmergencyItem> items;
  final DateTime? updatedAt;
}

class AdminEmergencyItem {
  const AdminEmergencyItem({
    required this.packetId,
    required this.riderId,
    required this.hopCount,
    required this.timestamp,
    required this.resolved,
  });

  final String packetId;
  final String riderId;
  final int hopCount;
  final DateTime timestamp;
  final bool resolved;
}