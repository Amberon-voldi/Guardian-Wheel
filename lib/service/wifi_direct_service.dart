import 'dart:async';

import 'package:flutter/services.dart';

class WifiDirectPeer {
  const WifiDirectPeer({
    required this.address,
    required this.name,
    required this.userId,
    required this.status,
  });

  final String address;
  final String name;
  final String userId;
  final int status;

  factory WifiDirectPeer.fromMap(Map<dynamic, dynamic> map) {
    return WifiDirectPeer(
      address: (map['address'] ?? '') as String,
      name: (map['name'] ?? 'WiFi-Direct Peer') as String,
      userId: (map['userId'] ?? '') as String,
      status: (map['status'] as num?)?.toInt() ?? 0,
    );
  }
}

class WifiDirectService {
  static const MethodChannel _methodChannel = MethodChannel('guardian_wheel/wifi_direct/methods');
  static const EventChannel _eventChannel = EventChannel('guardian_wheel/wifi_direct/events');

  Stream<List<WifiDirectPeer>> get peersStream => _eventChannel.receiveBroadcastStream().map((event) {
        final list = (event as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<dynamic, dynamic>>()
            .map(WifiDirectPeer.fromMap)
            .toList(growable: false);
        return list;
      });

  Future<void> startDiscovery({required String userId}) async {
    try {
      await _methodChannel.invokeMethod<void>('startDiscovery', {'userId': userId});
    } catch (_) {}
  }

  Future<void> stopDiscovery() async {
    try {
      await _methodChannel.invokeMethod<void>('stopDiscovery');
    } catch (_) {}
  }

  Future<void> connect(String peerAddress) async {
    try {
      await _methodChannel.invokeMethod<void>('connect', {'address': peerAddress});
    } catch (_) {}
  }
}
