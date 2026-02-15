enum RideStatus {
  active,
  emergency,
  completed;

  String get value {
    switch (this) {
      case RideStatus.active:
        return 'active';
      case RideStatus.emergency:
        return 'emergency';
      case RideStatus.completed:
        return 'completed';
    }
  }

  static RideStatus fromValue(String value) {
    switch (value.toLowerCase()) {
      case 'active':
        return RideStatus.active;
      case 'emergency':
        return RideStatus.emergency;
      case 'completed':
        return RideStatus.completed;
      default:
        return RideStatus.active;
    }
  }
}