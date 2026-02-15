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
    String? gatewayPacketsCollectionId,
    WifiDirectService? wifiDirectService,
    Future<bool> Function(MeshPacket packet)? gatewayUploader,
  })
      : _connectivity = connectivity ?? Connectivity(),
        _bleMesh = bleMesh ?? BleMeshService(),
        _databases = databases,
        _databaseId = databaseId,
        _meshNodesCollectionId = meshNodesCollectionId,
        _gatewayPacketsCollectionId = gatewayPacketsCollectionId,
        _gatewayUploader = gatewayUploader,
        _wifiDirectService = wifiDirectService ?? WifiDirectService();

  final Connectivity _connectivity;
  final AppEventBus? eventBus;
  final BleMeshService _bleMesh;
  final appwrite.Databases? _databases;
  final String? _databaseId;
  final String? _meshNodesCollectionId;
  final String? _gatewayPacketsCollectionId;
  final Future<bool> Function(MeshPacket packet)? _gatewayUploader;
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
      final packet = state.packet;
      final fromPeer = packet.lastPeer ?? 'ble-peer';

      if (state.status == MeshPacketStatus.duplicateDropped ||
          state.status == MeshPacketStatus.expired) {
        return;
      }

      // Ignore our own packet lifecycle echoes from BLE simulator.
      if (packet.origin == _currentUserId &&
          (state.status == MeshPacketStatus.created ||
              state.status == MeshPacketStatus.forwarding ||
              state.status == MeshPacketStatus.forwarded)) {
        return;
      }

      final normalizedIncoming = packet.copyWith(
        hop: packet.hop > 0 ? packet.hop - 1 : 0,
        status: MeshPacketStatus.created,
      );

      unawaited(receivePacket(packet: normalizedIncoming, fromPeer: fromPeer));
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

      final packet = MeshPacket(
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

      final delivered = await _tryDeliverAsGateway(packet);
      if (delivered != null) {
        return delivered;
      }

      final rebroadcasted = await _rebroadcastPacket(
        packet: packet,
        fromPeer: null,
        fallbackPeers: mockPeers,
        relayDelay: relayDelay,
      );
      return rebroadcasted;
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

    final received = packet.copyWith(
      status: MeshPacketStatus.received,
      lastPeer: fromPeer,
    );
    _emit(received, MeshPacketStatus.received, 'Received from $fromPeer.');
    _persistPacket(received);

    final nextHopPacket = received.copyWith(
      hop: received.hop + 1,
      lastPeer: fromPeer,
    );

    if (nextHopPacket.hop > nextHopPacket.ttl) {
      final expired = nextHopPacket.copyWith(status: MeshPacketStatus.expired);
      _emit(expired, MeshPacketStatus.expired, 'TTL exceeded; dropped.');
      _persistPacket(expired);
      return expired;
    }

    final delivered = await _tryDeliverAsGateway(nextHopPacket);
    if (delivered != null) {
      return delivered;
    }

    return _rebroadcastPacket(packet: nextHopPacket, fromPeer: fromPeer);
  }

  Future<MeshPacket> _rebroadcastPacket({
    required MeshPacket packet,
    required String? fromPeer,
    List<String> fallbackPeers = const ['peer-A', 'peer-B', 'peer-C'],
    Duration relayDelay = const Duration(milliseconds: 450),
  }) async {
    final candidatePeers = <String>{
      ..._bleMesh.peers.keys,
      ..._wifiDirectPeers.values
          .where((peer) => peer.userId.isNotEmpty)
          .map((peer) => peer.userId),
      if (_bleMesh.peerCount == 0 && _wifiDirectPeers.isEmpty) ...fallbackPeers,
    };

    if (fromPeer != null && fromPeer.isNotEmpty) {
      candidatePeers.remove(fromPeer);
    }
    if (_currentUserId != null) {
      candidatePeers.remove(_currentUserId);
    }

    if (candidatePeers.isEmpty) {
      final pending = packet.copyWith(status: MeshPacketStatus.pending);
      _emit(pending, MeshPacketStatus.pending, 'No peers available; packet pending.');
      _persistPacket(pending);
      return pending;
    }

    await Future<void>.delayed(relayDelay);
    final forwarded = packet.copyWith(
      status: MeshPacketStatus.forwarded,
      lastPeer: candidatePeers.first,
    );
    _emit(
      forwarded,
      MeshPacketStatus.forwarded,
      'Forwarded to ${candidatePeers.length} peer(s) at hop ${forwarded.hop}/${forwarded.ttl}.',
    );
    _persistPacket(forwarded);
    return forwarded;
  }

  Future<MeshPacket?> _tryDeliverAsGateway(MeshPacket packet) async {
    final internetAvailable = await _isInternetAvailable();
    if (!internetAvailable) return null;

    final uploaded = await _uploadPacketToBackend(packet);
    if (!uploaded) return null;

    final delivered = packet.copyWith(
      status: MeshPacketStatus.delivered,
      deliveredAt: DateTime.now().toUtc(),
    );
    _emit(delivered, MeshPacketStatus.delivered, 'Gateway delivered packet.');
    _persistPacket(delivered);
    eventBus?.publishMeshDelivery(delivered, message: 'Packet delivered by gateway.');
    return delivered;
  }

  Future<bool> _uploadPacketToBackend(MeshPacket packet) async {
    final customUploader = _gatewayUploader;
    if (customUploader != null) {
      try {
        return await customUploader(packet);
      } catch (_) {
        return false;
      }
    }

    final databases = _databases;
    final databaseId = _databaseId;
    final collectionId = _gatewayPacketsCollectionId;
    if (databases == null || databaseId == null || collectionId == null) {
      return false;
    }

    try {
      await databases.createDocument(
        databaseId: databaseId,
        collectionId: collectionId,
        documentId: packet.id,
        data: {
          'userId': packet.origin,
          'rideId': packet.id,
          'type': 'mesh_sos',
          'status': 'open',
          'lat': packet.lat,
          'lng': packet.lng,
          'message': 'Mesh packet delivered at hop ${packet.hop}/${packet.ttl}',
        },
      );
      return true;
    } on appwrite.AppwriteException catch (error) {
      if (error.code == 409) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isInternetAvailable() async {
    try {
      final result = await _connectivity.checkConnectivity();
      return result.any((e) => e != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  void _markSeen(String packetId) => _seenPacketIds.add(packetId);

  void _emit(MeshPacket packet, MeshPacketStatus status, String message) {
    if (_packetStateController.isClosed) return;
    _packetStateController.add(
      MeshPacketState(packet: packet, timestamp: DateTime.now().toUtc(), status: status, message: message),
    );
  }

  void _persistPacket(MeshPacket packet) {
    unawaited(_localDb.insertMeshPacket({
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
    }));
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