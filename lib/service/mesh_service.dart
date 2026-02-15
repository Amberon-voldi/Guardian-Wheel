import 'dart:async';
import 'dart:io';

import 'package:appwrite/appwrite.dart' as appwrite;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../model/mesh_packet.dart';
import 'app_event_bus.dart';
import 'ble_mesh_service.dart';
import 'local_database.dart';
import 'wifi_direct_service.dart';

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
  MeshService({
    Connectivity? connectivity,
    this.eventBus,
    BleMeshService? bleMesh,
    appwrite.Databases? databases,
    String? databaseId,
    String? meshNodesCollectionId,
    WifiDirectService? wifiDirectService,
  })
      : _connectivity = connectivity ?? Connectivity(),
        _bleMesh = bleMesh ?? BleMeshService(),
        _databases = databases,
        _databaseId = databaseId,
        _meshNodesCollectionId = meshNodesCollectionId,
        _wifiDirectService = wifiDirectService ?? WifiDirectService();

  final Connectivity _connectivity;
  final AppEventBus? eventBus;
  final BleMeshService _bleMesh;
  final appwrite.Databases? _databases;
  final String? _databaseId;
  final String? _meshNodesCollectionId;
  final WifiDirectService _wifiDirectService;
  final Map<String, WifiDirectPeer> _wifiDirectPeers = {};
  final LocalDatabase _localDb = LocalDatabase.instance;

  final StreamController<MeshPacketState> _packetStateController =
      StreamController<MeshPacketState>.broadcast();
  final StreamController<int> _peerCountController =
      StreamController<int>.broadcast();
  final Set<String> _seenPacketIds = <String>{};

  StreamSubscription<MeshPacketState>? _bleSub;
  StreamSubscription<BleP2PEvent>? _blePeerSub;
  StreamSubscription<List<WifiDirectPeer>>? _wifiPeerSub;
  String? _currentUserId;

  Stream<MeshPacketState> get packetStates => _packetStateController.stream;
    Stream<int> get peerCountStream => _peerCountController.stream;
  Set<String> get seenPacketIds => Set<String>.unmodifiable(_seenPacketIds);
  BleMeshService get bleMesh => _bleMesh;
  int get peerCount => _bleMesh.peerCount + _wifiDirectPeers.length;

  /// Start BLE scanning and bridge BLE packets into the unified stream.
  Future<void> startBleMesh({required String currentUserId}) async {
    _currentUserId = currentUserId;
    await _ensureNearbyPermissions();
    await _bleMesh.startScanning();
    _bleSub ??= _bleMesh.packetStates.listen((state) {
      // Bridge BLE packets into unified stream
      if (!_packetStateController.isClosed) {
        _packetStateController.add(state);
      }
      _persistPacket(state.packet);
    });

    _blePeerSub ??= _bleMesh.peerEvents.listen((_) {
      if (!_peerCountController.isClosed) {
        _peerCountController.add(peerCount);
      }
    });

    _wifiPeerSub ??= _wifiDirectService.peersStream.listen((peers) {
      final filteredPeers = peers.where((peer) {
        if (peer.userId.isEmpty) return false;
        return peer.userId != _currentUserId;
      }).toList(growable: false);

      _wifiDirectPeers
        ..clear()
        ..addEntries(filteredPeers.map((peer) => MapEntry(peer.address, peer)));

      if (!_peerCountController.isClosed) {
        _peerCountController.add(peerCount);
      }

      for (final peer in filteredPeers) {
        _wifiDirectService.connect(peer.address);
      }
    }, onError: (_) {
      // Unsupported platform/plugin path; BLE mesh continues.
    });

    await _wifiDirectService.startDiscovery(userId: currentUserId);

    if (!_peerCountController.isClosed) {
      _peerCountController.add(peerCount);
    }
  }

  Future<void> stopBleMesh() async {
    await _bleSub?.cancel();
    _bleSub = null;
    await _blePeerSub?.cancel();
    _blePeerSub = null;
    await _wifiPeerSub?.cancel();
    _wifiPeerSub = null;
    _wifiDirectPeers.clear();
    await _wifiDirectService.stopDiscovery();
    await _bleMesh.stopScanning();
  }

  Future<void> updateSelfNode({
    required String userId,
    required double lat,
    required double lng,
    bool isActive = true,
  }) async {
    final databases = _databases;
    final databaseId = _databaseId;
    final meshNodesCollectionId = _meshNodesCollectionId;
    if (databases == null || databaseId == null || meshNodesCollectionId == null) {
      return;
    }

    final data = {
      'user_id': userId,
      'lat': lat,
      'lng': lng,
      'is_active': isActive,
      'last_ping_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      await databases.updateDocument(
        databaseId: databaseId,
        collectionId: meshNodesCollectionId,
        documentId: userId,
        data: data,
      );
    } on appwrite.AppwriteException catch (error) {
      if (error.code == 404) {
        try {
          await databases.createDocument(
            databaseId: databaseId,
            collectionId: meshNodesCollectionId,
            documentId: userId,
            data: data,
          );
        } catch (_) {}
      }
    } catch (_) {}
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
    await _blePeerSub?.cancel();
    await stopBleMesh();
    if (!_peerCountController.isClosed) {
      await _peerCountController.close();
    }
    if (!_packetStateController.isClosed) {
      await _packetStateController.close();
    }
  }

  Future<void> _ensureNearbyPermissions() async {
    if (!Platform.isAndroid) return;
    await <ph.Permission>[
      ph.Permission.locationWhenInUse,
      ph.Permission.location,
      ph.Permission.nearbyWifiDevices,
      ph.Permission.bluetoothScan,
      ph.Permission.bluetoothConnect,
    ].request();
  }
}