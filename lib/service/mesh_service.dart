import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../model/mesh_packet.dart';
import 'app_event_bus.dart';
import 'ble_mesh_service.dart';
import 'local_database.dart';

class MeshServiceException implements Exception {
  MeshServiceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'MeshServiceException(message: $message, cause: $cause)';
}

/// Unified mesh networking service.
/// Combines BLE P2P mesh with software-simulated relay, persists packets
/// locally for offline-first operation.
class MeshService {
  MeshService({Connectivity? connectivity, this.eventBus, BleMeshService? bleMesh})
      : _connectivity = connectivity ?? Connectivity(),
        _bleMesh = bleMesh ?? BleMeshService();

  final Connectivity _connectivity;
  final AppEventBus? eventBus;
  final BleMeshService _bleMesh;
  final LocalDatabase _localDb = LocalDatabase.instance;

  final StreamController<MeshPacketState> _packetStateController =
      StreamController<MeshPacketState>.broadcast();
  final Set<String> _seenPacketIds = <String>{};

  StreamSubscription<MeshPacketState>? _bleSub;

  Stream<MeshPacketState> get packetStates => _packetStateController.stream;
  Set<String> get seenPacketIds => Set<String>.unmodifiable(_seenPacketIds);
  BleMeshService get bleMesh => _bleMesh;
  int get peerCount => _bleMesh.peerCount;

  /// Start BLE scanning and bridge BLE packets into the unified stream.
  Future<void> startBleMesh() async {
    await _bleMesh.startScanning();
    _bleSub ??= _bleMesh.packetStates.listen((state) {
      // Bridge BLE packets into unified stream
      if (!_packetStateController.isClosed) {
        _packetStateController.add(state);
      }
      _persistPacket(state.packet);
    });
  }

  Future<void> stopBleMesh() async {
    await _bleSub?.cancel();
    _bleSub = null;
    await _bleMesh.stopScanning();
  }

  Future<MeshPacket> generateAlertPacket({
    required String origin,
    required double lat,
    required double lng,
    int ttl = 5,
    List<String> mockPeers = const ['peer-A', 'peer-B', 'peer-C'],
    Duration relayDelay = const Duration(milliseconds: 450),
  }) async {
    try {
      if (ttl <= 0) throw MeshServiceException('TTL must be > 0.');

      var packet = MeshPacket(
        id: '$origin-${DateTime.now().millisecondsSinceEpoch}',
        origin: origin,
        lat: lat,
        lng: lng,
        hop: 0,
        ttl: ttl,
        status: MeshPacketStatus.created,
        createdAt: DateTime.now().toUtc(),
      );

      _markSeen(packet.id);
      _emit(packet, MeshPacketStatus.created, 'Alert packet created.');
      _persistPacket(packet);

      // Try BLE broadcast first
      if (_bleMesh.isScanning && _bleMesh.peerCount > 0) {
        packet = await _bleMesh.broadcastAlert(
          origin: origin,
          lat: lat,
          lng: lng,
          ttl: ttl,
        );
        return packet;
      }

      // Fallback: software-simulated relay
      packet = await _simulateForwarding(
        packet: packet,
        peers: mockPeers,
        relayDelay: relayDelay,
      );
      return packet;
    } catch (error) {
      if (error is MeshServiceException) rethrow;
      throw MeshServiceException('Failed to generate alert packet.', cause: error);
    }
  }

  Future<MeshPacket> receivePacket({
    required MeshPacket packet,
    required String fromPeer,
  }) async {
    if (_seenPacketIds.contains(packet.id)) {
      final dropped = packet.copyWith(
        status: MeshPacketStatus.duplicateDropped,
        lastPeer: fromPeer,
      );
      _emit(dropped, MeshPacketStatus.duplicateDropped, 'Duplicate from $fromPeer.');
      return dropped;
    }

    _markSeen(packet.id);
    final relayed = packet.copyWith(
      hop: packet.hop + 1,
      status: MeshPacketStatus.forwarding,
      lastPeer: fromPeer,
    );
    _emit(relayed, MeshPacketStatus.forwarding, 'Received from $fromPeer, relaying.');
    _persistPacket(relayed);
    return relayed;
  }

  Future<MeshPacket> _simulateForwarding({
    required MeshPacket packet,
    required List<String> peers,
    required Duration relayDelay,
  }) async {
    var current = packet;

    for (final peer in peers) {
      if (current.hop >= current.ttl) {
        final expired = current.copyWith(status: MeshPacketStatus.expired, lastPeer: peer);
        _emit(expired, MeshPacketStatus.expired, 'TTL reached; expired.');
        return expired;
      }

      await Future<void>.delayed(relayDelay);
      current = current.copyWith(
        hop: current.hop + 1,
        status: MeshPacketStatus.forwarding,
        lastPeer: peer,
      );
      _emit(current, MeshPacketStatus.forwarding, 'Forwarded to $peer (hop ${current.hop}/${current.ttl}).');

      final internetAvailable = await _isInternetAvailable();
      if (internetAvailable) {
        final delivered = current.copyWith(
          status: MeshPacketStatus.delivered,
          deliveredAt: DateTime.now().toUtc(),
        );
        _emit(delivered, MeshPacketStatus.delivered, 'Internet available; delivered.');
        eventBus?.publishMeshDelivery(delivered, message: 'Packet delivered.');
        return delivered;
      }
    }

    final pending = current.copyWith(status: MeshPacketStatus.pending);
    _emit(pending, MeshPacketStatus.pending, 'No internet; pending in mesh.');
    return pending;
  }

  Future<bool> _isInternetAvailable() async {
    final result = await _connectivity.checkConnectivity();
    return result.any((e) => e != ConnectivityResult.none);
  }

  void _markSeen(String packetId) => _seenPacketIds.add(packetId);

  void _emit(MeshPacket packet, MeshPacketStatus status, String message) {
    if (_packetStateController.isClosed) return;
    _packetStateController.add(
      MeshPacketState(packet: packet, timestamp: DateTime.now().toUtc(), status: status, message: message),
    );
  }

  void _persistPacket(MeshPacket packet) {
    _localDb.insertMeshPacket({
      'id': packet.id,
      'origin': packet.origin,
      'lat': packet.lat,
      'lng': packet.lng,
      'hop': packet.hop,
      'ttl': packet.ttl,
      'status': packet.status.name,
      'last_peer': packet.lastPeer,
      'delivered_at': packet.deliveredAt?.toIso8601String(),
      'created_at': packet.createdAt.toIso8601String(),
      'synced': 0,
    });
  }

  Future<void> dispose() async {
    await stopBleMesh();
    if (!_packetStateController.isClosed) {
      await _packetStateController.close();
    }
  }
}