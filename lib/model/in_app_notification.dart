enum InAppNotificationType {
  info,
  warning,
  success,
  danger,
}

class InAppNotification {
  const InAppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.createdAt,
    this.primaryActionLabel,
    this.secondaryActionLabel,
    this.confidence,
  });

  final String id;
  final String title;
  final String message;
  final InAppNotificationType type;
  final DateTime createdAt;
  final String? primaryActionLabel;
  final String? secondaryActionLabel;
  final double? confidence;
}
