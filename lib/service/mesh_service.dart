import 'dart:async';
import 'dart:io';

import 'package:appwrite/appwrite.dart' as appwrite;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../model/mesh_packet.dart';
import 'app_event_bus.dart';
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
/// Uses Wi‑Fi Direct P2P bootstrap and relay simulation, persists packets
/// locally for offline-first operation.
class MeshService {
  MeshService({
    Connectivity? connectivity,
    this.eventBus,
    appwrite.Databases? databases,
    String? databaseId,
    String? meshNodesCollectionId,
    String? gatewayPacketsCollectionId,
    WifiDirectService? wifiDirectService,
    Future<bool> Function(MeshPacket packet)? gatewayUploader,
  }) : _connectivity = connectivity ?? Connectivity(),
       _databases = databases,
       _databaseId = databaseId,
       _meshNodesCollectionId = meshNodesCollectionId,
       _gatewayPacketsCollectionId = gatewayPacketsCollectionId,
       _gatewayUploader = gatewayUploader,
       _wifiDirectService = wifiDirectService ?? WifiDirectService();

  final Connectivity _connectivity;
  final AppEventBus? eventBus;
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
  final StreamController<WifiDirectBootstrapEvent> _wifiStateController =
      StreamController<WifiDirectBootstrapEvent>.broadcast();
  final Set<String> _seenPacketIds = <String>{};

  StreamSubscription<List<WifiDirectPeer>>? _wifiPeerSub;
  StreamSubscription<WifiDirectBootstrapEvent>? _wifiStateSub;
  Timer? _wifiRestartDebounce;
  String? _currentUserId;
  WifiDirectBootstrapState _lastWifiState = WifiDirectBootstrapState.idle;

  Stream<MeshPacketState> get packetStates => _packetStateController.stream;
  Stream<int> get peerCountStream => _peerCountController.stream;
  Stream<WifiDirectBootstrapEvent> get wifiStateEvents =>
      _wifiStateController.stream;
  WifiDirectBootstrapState get wifiState => _lastWifiState;
  bool get isWifiDirectActive =>
      _lastWifiState == WifiDirectBootstrapState.discovering ||
      _lastWifiState == WifiDirectBootstrapState.connecting ||
      _lastWifiState == WifiDirectBootstrapState.connected ||
      _lastWifiState == WifiDirectBootstrapState.go;
  Set<String> get seenPacketIds => Set<String>.unmodifiable(_seenPacketIds);
  int get peerCount => _wifiDirectPeers.length;

  Future<void> startMesh({required String currentUserId}) async {
    _currentUserId = currentUserId;
    await _ensureNearbyPermissions();

    _wifiPeerSub ??= _wifiDirectService.peersStream.listen(
      (peers) {
        final filteredPeers = peers
            .where((peer) {
              final isAppPeer = peer.isGuardianApp || peer.appMarker == '1';
              if (!isAppPeer) return false;
              if (peer.userId.isEmpty) return false;
              return peer.userId != _currentUserId;
            })
            .toList(growable: false);

        _wifiDirectPeers
          ..clear()
          ..addEntries(
            filteredPeers.map((peer) => MapEntry(peer.address, peer)),
          );

        if (!_peerCountController.isClosed) {
          _peerCountController.add(peerCount);
        }
      },
      onError: (_) {
        _emitWifiEvent(
          const WifiDirectBootstrapEvent(
            state: WifiDirectBootstrapState.failed,
            message: 'Wi‑Fi Direct peer stream failed.',
          ),
        );
        _scheduleWifiRestart();
      },
    );

    _wifiStateSub ??= _wifiDirectService.stateStream.listen(
      (event) {
        _emitWifiEvent(event);
        final callback = event.callback;
        if (callback == 'onDisconnected' ||
            event.state == WifiDirectBootstrapState.failed) {
          _scheduleWifiRestart();
        }
      },
      onError: (_) {
        _emitWifiEvent(
          const WifiDirectBootstrapEvent(
            state: WifiDirectBootstrapState.failed,
            message: 'Wi‑Fi Direct state stream failed.',
          ),
        );
        _scheduleWifiRestart();
      },
    );

    await _wifiDirectService.startDiscovery(userId: currentUserId);

    if (!_peerCountController.isClosed) {
      _peerCountController.add(peerCount);
    }
  }

  Future<void> stopMesh() async {
    _wifiRestartDebounce?.cancel();
    _wifiRestartDebounce = null;
    await _wifiPeerSub?.cancel();
    _wifiPeerSub = null;
    await _wifiStateSub?.cancel();
    _wifiStateSub = null;
    _wifiDirectPeers.clear();
    await _wifiDirectService.stopDiscovery();
    _emitWifiEvent(
      const WifiDirectBootstrapEvent(
        state: WifiDirectBootstrapState.idle,
        message: 'Wi‑Fi Direct stopped.',
      ),
    );
  }

  Future<void> restartMesh() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    await stopMesh();
    await startMesh(currentUserId: userId);
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
    if (databases == null ||
        databaseId == null ||
        meshNodesCollectionId == null) {
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
        relayDelay: relayDelay,
      );
      return rebroadcasted;
    } catch (error) {
      if (error is MeshServiceException) rethrow;
      throw MeshServiceException(
        'Failed to generate alert packet.',
        cause: error,
      );
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
      _emit(
        dropped,
        MeshPacketStatus.duplicateDropped,
        'Duplicate from $fromPeer.',
      );
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
    Duration relayDelay = const Duration(milliseconds: 450),
  }) async {
    final candidatePeers = <String>{
      ..._wifiDirectPeers.values
          .where((peer) => peer.userId.isNotEmpty)
          .map((peer) => peer.userId),
    };

    if (fromPeer != null && fromPeer.isNotEmpty) {
      candidatePeers.remove(fromPeer);
    }
    if (_currentUserId != null) {
      candidatePeers.remove(_currentUserId);
    }

    if (candidatePeers.isEmpty) {
      final pending = packet.copyWith(status: MeshPacketStatus.pending);
      _emit(
        pending,
        MeshPacketStatus.pending,
        'No peers available; packet pending.',
      );
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
    eventBus?.publishMeshDelivery(
      delivered,
      message: 'Packet delivered by gateway.',
    );
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
      MeshPacketState(
        packet: packet,
        timestamp: DateTime.now().toUtc(),
        status: status,
        message: message,
      ),
    );
  }

  void _persistPacket(MeshPacket packet) {
    unawaited(
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
      }),
    );
  }

  Future<void> dispose() async {
    await stopMesh();
    if (!_peerCountController.isClosed) {
      await _peerCountController.close();
    }
    if (!_packetStateController.isClosed) {
      await _packetStateController.close();
    }
    if (!_wifiStateController.isClosed) {
      await _wifiStateController.close();
    }
  }

  Future<void> _ensureNearbyPermissions() async {
    if (!Platform.isAndroid) return;
    await <ph.Permission>[
      ph.Permission.locationWhenInUse,
      ph.Permission.location,
      ph.Permission.nearbyWifiDevices,
    ].request();
  }

  void _emitWifiEvent(WifiDirectBootstrapEvent event) {
    if (event.state != null) {
      _lastWifiState = event.state!;
    }
    if (!_wifiStateController.isClosed) {
      _wifiStateController.add(event);
    }
  }

  void _scheduleWifiRestart() {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    _wifiRestartDebounce?.cancel();
    _wifiRestartDebounce = Timer(const Duration(seconds: 2), () async {
      await restartMesh();
    });
  }
}
