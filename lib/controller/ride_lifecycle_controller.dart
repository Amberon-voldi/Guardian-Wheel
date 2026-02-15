import 'package:flutter/foundation.dart';

import '../model/ride_status.dart';

class RideLifecycleController extends ChangeNotifier {
  String? _rideId;
  RideStatus _status = RideStatus.completed;
  DateTime? _startedAt;
  DateTime? _endedAt;
  double _currentLat = 12.9716;
  double _currentLng = 77.5946;

  String? get rideId => _rideId;
  RideStatus get status => _status;
  DateTime? get startedAt => _startedAt;
  DateTime? get endedAt => _endedAt;
  double get currentLat => _currentLat;
  double get currentLng => _currentLng;
  bool get isRideActive => _status == RideStatus.active || _status == RideStatus.emergency;

  void startRide({
    required String riderId,
    required double startLat,
    required double startLng,
  }) {
    _rideId = '${riderId}_${DateTime.now().millisecondsSinceEpoch}';
    _status = RideStatus.active;
    _startedAt = DateTime.now().toUtc();
    _endedAt = null;
    _currentLat = startLat;
    _currentLng = startLng;
    notifyListeners();
  }

  void markEmergency() {
    if (!isRideActive) return;
    _status = RideStatus.emergency;
    notifyListeners();
  }

  void endRide({
    required double endLat,
    required double endLng,
  }) {
    _status = RideStatus.completed;
    _endedAt = DateTime.now().toUtc();
    _currentLat = endLat;
    _currentLng = endLng;
    notifyListeners();
  }

  void updateCurrentLocation(double lat, double lng) {
    _currentLat = lat;
    _currentLng = lng;
    notifyListeners();
  }
}