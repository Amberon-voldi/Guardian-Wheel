import 'dart:async';

import 'package:flutter/material.dart';

import '../service/sensor_detection_service.dart';
import '../theme/guardian_theme.dart';

class SensorDetectionsScreen extends StatefulWidget {
  const SensorDetectionsScreen({
    required this.sensorDetectionService,
    required this.initialEvents,
    super.key,
  });

  final SensorDetectionService sensorDetectionService;
  final List<HazardDetectionEvent> initialEvents;

  @override
  State<SensorDetectionsScreen> createState() => _SensorDetectionsScreenState();
}

class _SensorDetectionsScreenState extends State<SensorDetectionsScreen> {
  late final List<HazardDetectionEvent> _events;
  StreamSubscription<HazardDetectionEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _events = List<HazardDetectionEvent>.from(widget.initialEvents);
    _sub = widget.sensorDetectionService.hazardStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _events.insert(0, event);
        if (_events.length > 250) {
          _events.removeRange(250, _events.length);
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _typeLabel(HazardType type) {
    return switch (type) {
      HazardType.pothole => 'Pothole / Bump',
      HazardType.roughRoad => 'Rough Road',
      HazardType.crashRisk => 'Crash Risk',
      HazardType.overspeed => 'Over Speed',
    };
  }

  IconData _typeIcon(HazardType type) {
    return switch (type) {
      HazardType.pothole => Icons.car_crash,
      HazardType.roughRoad => Icons.terrain,
      HazardType.crashRisk => Icons.warning_amber,
      HazardType.overspeed => Icons.speed,
    };
  }

  Color _typeColor(HazardType type) {
    return switch (type) {
      HazardType.pothole => GuardianTheme.danger,
      HazardType.roughRoad => GuardianTheme.warning,
      HazardType.crashRisk => GuardianTheme.danger,
      HazardType.overspeed => GuardianTheme.accentBlue,
    };
  }

  String _timeText(DateTime timestamp) {
    final local = timestamp.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sensor Detections (Temp)')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _SummaryCard(
                      icon: Icons.sensors,
                      title: 'Monitoring',
                      value: widget.sensorDetectionService.isMonitoring
                          ? 'ACTIVE'
                          : 'OFF',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SummaryCard(
                      icon: Icons.analytics_outlined,
                      title: 'Detections',
                      value: '${_events.length}',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _events.isEmpty
                  ? Center(
                      child: Text(
                        'No sensor detections yet',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: GuardianTheme.textSecondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      itemCount: _events.length,
                      itemBuilder: (context, index) {
                        final event = _events[index];
                        final color = _typeColor(event.type);
                        final accuracy = (event.severity * 100).clamp(0, 100);

                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        _typeIcon(event.type),
                                        color: color,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _typeLabel(event.type),
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _timeText(event.timestamp),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: GuardianTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  event.description,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Accuracy: ${accuracy.toStringAsFixed(0)}%',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: accuracy / 100,
                                    minHeight: 8,
                                    backgroundColor:
                                        color.withValues(alpha: 0.12),
                                    valueColor:
                                        AlwaysStoppedAnimation<Color>(color),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    Chip(
                                      label: Text(
                                          'Impact: ${event.impactValue.toStringAsFixed(2)}'),
                                    ),
                                    Chip(
                                      label: Text(
                                        'Lat: ${event.lat.toStringAsFixed(5)}',
                                      ),
                                    ),
                                    Chip(
                                      label: Text(
                                        'Lng: ${event.lng.toStringAsFixed(5)}',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: GuardianTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
