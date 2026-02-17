import 'dart:async';

import 'package:flutter/services.dart';

enum WifiDirectBootstrapState {
  idle,
  discovering,
  connecting,
  connected,
  go,
  failed,
}

class WifiDirectBootstrapEvent {
  const WifiDirectBootstrapEvent({
    this.state,
    this.message,
    this.callback,
    this.ip,
    this.ownerIp,
    this.groupFormed,
    this.isGroupOwner,
    this.targetAddress,
    this.targetName,
    this.appPeerCount,
    this.pendingPeerCount,
    this.reasonCode,
  });

  final WifiDirectBootstrapState? state;
  final String? message;
  final String? callback;
  final String? ip;
  final String? ownerIp;
  final bool? groupFormed;
  final bool? isGroupOwner;
  final String? targetAddress;
  final String? targetName;
  final int? appPeerCount;
  final int? pendingPeerCount;
  final int? reasonCode;

  factory WifiDirectBootstrapEvent.fromMap(Map<dynamic, dynamic> map) {
    final stateName = (map['state'] ?? '').toString().toLowerCase();
    final callback = (map['event'] ?? '').toString();

    final parsedState = switch (stateName) {
      'idle' => WifiDirectBootstrapState.idle,
      'discovering' => WifiDirectBootstrapState.discovering,
      'connecting' => WifiDirectBootstrapState.connecting,
      'connected' => WifiDirectBootstrapState.connected,
      'go' => WifiDirectBootstrapState.go,
      'failed' => WifiDirectBootstrapState.failed,
      _ => null,
    };

    return WifiDirectBootstrapEvent(
      state: parsedState,
      message: (map['message'] ?? '').toString().ifEmpty(null),
      callback: callback.ifEmpty(null),
      ip: (map['ip'] ?? '').toString().ifEmpty(null),
      ownerIp: (map['ownerIp'] ?? '').toString().ifEmpty(null),
      groupFormed: map['groupFormed'] as bool?,
      isGroupOwner: map['isGroupOwner'] as bool?,
      targetAddress: (map['targetAddress'] ?? '').toString().ifEmpty(null),
      targetName: (map['targetName'] ?? '').toString().ifEmpty(null),
      appPeerCount: (map['appPeerCount'] as num?)?.toInt(),
      pendingPeerCount: (map['pendingPeerCount'] as num?)?.toInt(),
      reasonCode: (map['reasonCode'] as num?)?.toInt(),
    );
  }
}

class WifiDirectPeer {
  const WifiDirectPeer({
    required this.address,
    required this.name,
    required this.userId,
    required this.appMarker,
    required this.isGuardianApp,
    required this.status,
  });

  final String address;
  final String name;
  final String userId;
  final String appMarker;
  final bool isGuardianApp;
  final int status;

  factory WifiDirectPeer.fromMap(Map<dynamic, dynamic> map) {
    return WifiDirectPeer(
      address: (map['address'] ?? '') as String,
      name: (map['name'] ?? 'WiFi-Direct Peer') as String,
      userId: (map['userId'] ?? '') as String,
      appMarker: (map['appMarker'] ?? '') as String,
      isGuardianApp:
          (map['isGuardianApp'] as bool?) ??
          ((map['appMarker'] ?? '').toString() == '1'),
      status: (map['status'] as num?)?.toInt() ?? 0,
    );
  }
}

class WifiDirectService {
  static const MethodChannel _methodChannel = MethodChannel(
    'guardian_wheel/wifi_direct/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'guardian_wheel/wifi_direct/events',
  );
  static const EventChannel _stateEventChannel = EventChannel(
    'guardian_wheel/wifi_direct/state',
  );

  Stream<List<WifiDirectPeer>> get peersStream =>
      _eventChannel.receiveBroadcastStream().map((event) {
        final list = (event as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<dynamic, dynamic>>()
            .map(WifiDirectPeer.fromMap)
            .toList(growable: false);
        return list;
      });

  Stream<WifiDirectBootstrapEvent> get stateStream =>
      _stateEventChannel.receiveBroadcastStream().map((event) {
        final map =
            (event as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{});
        return WifiDirectBootstrapEvent.fromMap(map);
      });

  Future<void> startDiscovery({required String userId}) async {
    try {
      await _methodChannel.invokeMethod<void>('startDiscovery', {
        'userId': userId,
      });
    } catch (_) {}
  }

  Future<void> stopDiscovery() async {
    try {
      await _methodChannel.invokeMethod<void>('stopDiscovery');
    } catch (_) {}
  }

  Future<void> connect(String peerAddress) async {
    try {
      await _methodChannel.invokeMethod<void>('connect', {
        'address': peerAddress,
      });
    } catch (_) {}
  }
}

extension on String {
  String? ifEmpty(String? fallback) => isEmpty ? fallback : this;
}
