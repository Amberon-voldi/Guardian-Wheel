import 'ride.dart';
import 'safety_alert.dart';

enum SafetyEventType {
  sosTriggered,
  alertCreated,
  rideMarkedEmergency,
  failed,
}

class SafetyEvent {
  const SafetyEvent({
    required this.type,
    required this.timestamp,
    this.alert,
    this.ride,
    this.message,
  });

  final SafetyEventType type;
  final DateTime timestamp;
  final SafetyAlert? alert;
  final Ride? ride;
  final String? message;
}

class ManualSosResult {
  const ManualSosResult({
    required this.alert,
    required this.updatedRide,
  });

  final SafetyAlert alert;
  final Ride updatedRide;
}