import 'dart:async';

import '../model/mesh_packet.dart';
import '../model/ride.dart';
import '../model/safety_alert.dart';

enum AppEventType {
  rideUpdate,
  alert,
  meshDelivery,
}

class AppEvent {
  const AppEvent({
    required this.type,
    required this.timestamp,
    this.ride,
    this.alert,
    this.meshPacket,
    this.message,
  });

  final AppEventType type;
  final DateTime timestamp;
  final Ride? ride;
  final SafetyAlert? alert;
  final MeshPacket? meshPacket;
  final String? message;
}

class AppEventBus {
  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  Stream<AppEvent> get stream => _controller.stream;

  void publishRideUpdate(Ride ride, {String? message}) {
    _publish(
      AppEvent(
        type: AppEventType.rideUpdate,
        timestamp: DateTime.now().toUtc(),
        ride: ride,
        message: message,
      ),
    );
  }

  void publishAlert(SafetyAlert alert, {String? message}) {
    _publish(
      AppEvent(
        type: AppEventType.alert,
        timestamp: DateTime.now().toUtc(),
        alert: alert,
        message: message,
      ),
    );
  }

  void publishMeshDelivery(MeshPacket packet, {String? message}) {
    _publish(
      AppEvent(
        type: AppEventType.meshDelivery,
        timestamp: DateTime.now().toUtc(),
        meshPacket: packet,
        message: message,
      ),
    );
  }

  void _publish(AppEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  Future<void> dispose() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}