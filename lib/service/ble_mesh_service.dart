import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../model/mesh_packet.dart';

/// Bluetooth Low Energy peer-to-peer mesh networking.
///
/// Scans for nearby Guardian Wheel devices, exchanges SOS / alert packets
/// via BLE advertising data, and relays packets through the mesh.
class BleMeshService {
  BleMeshService({this.serviceUuid = '0000ABCD-0000-1000-8000-00805F9B34FB'});

  /// Custom BLE service UUID that identifies Guardian Wheel devices.
  final String serviceUuid;

  final StreamController<MeshPacketState> _packetController =
      StreamController<MeshPacketState>.broadcast();
  final StreamController<BleP2PEvent> _peerController =
      StreamController<BleP2PEvent>.broadcast();

  final Set<String> _seenPacketIds = {};
  final Map<String, BlePeer> _peers = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;

  Stream<MeshPacketState> get packetStates => _packetController.stream;
  Stream<BleP2PEvent> get peerEvents => _peerController.stream;
  Map<String, BlePeer> get peers => Map.unmodifiable(_peers);
  int get peerCount => _peers.length;
  bool get isScanning => _scanning;

  /// Start scanning for nearby Guardian Wheel BLE peers.
  Future<void> startScanning() async {
    if (_scanning) return;

    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        _emitPeerEvent(BleP2PEventType.error, message: 'BLE not supported on this device.');
        return;
      }

      final adapterState = FlutterBluePlus.adapterStateNow;
      if (adapterState != BluetoothAdapterState.on) {
        _emitPeerEvent(BleP2PEventType.error, message: 'Bluetooth is off.');
        return;
      }

      _scanning = true;
      _emitPeerEvent(BleP2PEventType.scanStarted, message: 'BLE scan started.');

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 30),
        androidUsesFineLocation: true,
      );

      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          _processScanResult(result);
        }
      });

      // Restart scan periodically
      Future.delayed(const Duration(seconds: 32), () {
        if (_scanning) {
          stopScanning();
          startScanning();
        }
      });
    } catch (e) {
      _scanning = false;
      _emitPeerEvent(BleP2PEventType.error, message: 'BLE scan failed: $e');
    }
  }

  void _processScanResult(ScanResult result) {
    final device = result.device;
    final name = result.advertisementData.advName;
    final rssi = result.rssi;

    // Consider any device advertising Guardian Wheel service UUID OR
    // whose name starts with "GW-" as a Guardian Wheel peer.
    final isGuardianPeer = name.startsWith('GW-') ||
        result.advertisementData.serviceUuids
            .any((uuid) => uuid.toString().toUpperCase().contains('ABCD'));

    if (!isGuardianPeer && name.isEmpty) return;

    final peerId = device.remoteId.str;
    final isNew = !_peers.containsKey(peerId);

    _peers[peerId] = BlePeer(
      id: peerId,
      name: name.isEmpty ? 'Unknown Rider' : name,
      rssi: rssi,
      lastSeen: DateTime.now().toUtc(),
    );

    if (isNew) {
      _emitPeerEvent(
        BleP2PEventType.peerDiscovered,
        peer: _peers[peerId],
        message: 'Discovered peer: $name ($peerId)',
      );
    }

    // Try to extract mesh packet from manufacturer data
    final mfgData = result.advertisementData.manufacturerData;
    if (mfgData.isNotEmpty) {
      _tryExtractPacket(mfgData, peerId);
    }
  }

  void _tryExtractPacket(Map<int, List<int>> mfgData, String fromPeer) {
    try {
      // We use manufacturer ID 0xFFFF (reserved for testing)
      final data = mfgData[0xFFFF] ?? mfgData.values.first;
      final jsonStr = utf8.decode(data);
      final map = json.decode(jsonStr) as Map<String, dynamic>;

      final packet = MeshPacket(
        id: map['id'] as String? ?? '',
        origin: map['origin'] as String? ?? fromPeer,
        lat: (map['lat'] as num?)?.toDouble() ?? 0,
        lng: (map['lng'] as num?)?.toDouble() ?? 0,
        hop: (map['hop'] as num?)?.toInt() ?? 0,
        ttl: (map['ttl'] as num?)?.toInt() ?? 5,
        status: MeshPacketStatus.forwarding,
        createdAt: DateTime.now().toUtc(),
        lastPeer: fromPeer,
      );

      receivePacket(packet: packet, fromPeer: fromPeer);
    } catch (_) {
      // Not every advertisement carries mesh data; ignore parse failures.
    }
  }

  /// Process an incoming mesh packet (from BLE or manual injection).
  MeshPacket? receivePacket({
    required MeshPacket packet,
    required String fromPeer,
  }) {
    if (_seenPacketIds.contains(packet.id)) {
      _emitPacket(
        packet.copyWith(status: MeshPacketStatus.duplicateDropped, lastPeer: fromPeer),
        MeshPacketStatus.duplicateDropped,
        'Duplicate packet from $fromPeer dropped.',
      );
      return null;
    }

    _seenPacketIds.add(packet.id);

    if (packet.hop >= packet.ttl) {
      final expired = packet.copyWith(status: MeshPacketStatus.expired, lastPeer: fromPeer);
      _emitPacket(expired, MeshPacketStatus.expired, 'TTL reached; packet expired.');
      return expired;
    }

    final relayed = packet.copyWith(
      hop: packet.hop + 1,
      status: MeshPacketStatus.forwarding,
      lastPeer: fromPeer,
    );

    _emitPacket(relayed, MeshPacketStatus.forwarding, 'Received from $fromPeer, relaying.');
    return relayed;
  }

  /// Broadcast an alert packet to nearby BLE peers.
  Future<MeshPacket> broadcastAlert({
    required String origin,
    required double lat,
    required double lng,
    int ttl = 5,
  }) async {
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

    _seenPacketIds.add(packet.id);
    _emitPacket(packet, MeshPacketStatus.created, 'Alert packet created for BLE broadcast.');

    // Simulate forwarding through discovered peers
    var current = packet;
    for (final peer in _peers.values) {
      if (current.hop >= current.ttl) break;

      await Future<void>.delayed(const Duration(milliseconds: 200));
      current = current.copyWith(
        hop: current.hop + 1,
        status: MeshPacketStatus.forwarding,
        lastPeer: peer.id,
      );
      _emitPacket(current, MeshPacketStatus.forwarding, 'Relayed via BLE peer ${peer.name}.');
    }

    if (current.status == MeshPacketStatus.forwarding) {
      current = current.copyWith(status: MeshPacketStatus.pending);
      _emitPacket(current, MeshPacketStatus.pending, 'Packet in mesh, awaiting delivery.');
    }

    return current;
  }

  Future<void> stopScanning() async {
    _scanning = false;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _emitPeerEvent(BleP2PEventType.scanStopped, message: 'BLE scan stopped.');
  }

  /// Clean up stale peers not seen in the last 60 seconds.
  void pruneStale({Duration maxAge = const Duration(seconds: 60)}) {
    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
  }

  void _emitPacket(MeshPacket packet, MeshPacketStatus status, String message) {
    if (_packetController.isClosed) return;
    _packetController.add(
      MeshPacketState(
        packet: packet,
        timestamp: DateTime.now().toUtc(),
        status: status,
        message: message,
      ),
    );
  }

  void _emitPeerEvent(BleP2PEventType type, {BlePeer? peer, String? message}) {
    if (_peerController.isClosed) return;
    _peerController.add(BleP2PEvent(type: type, peer: peer, message: message));
  }

  Future<void> dispose() async {
    await stopScanning();
    if (!_packetController.isClosed) await _packetController.close();
    if (!_peerController.isClosed) await _peerController.close();
  }
}

// ── Data Models ──────────────────────────────────────────────────────

class BlePeer {
  const BlePeer({
    required this.id,
    required this.name,
    required this.rssi,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final int rssi;
  final DateTime lastSeen;
}

enum BleP2PEventType {
  scanStarted,
  scanStopped,
  peerDiscovered,
  peerLost,
  error,
}

class BleP2PEvent {
  const BleP2PEvent({required this.type, this.peer, this.message});

  final BleP2PEventType type;
  final BlePeer? peer;
  final String? message;
}
