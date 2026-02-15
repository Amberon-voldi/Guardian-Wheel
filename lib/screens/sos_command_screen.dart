import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/ride_status.dart';
import '../service/location_service.dart';

class SosCommandScreen extends StatefulWidget {
  const SosCommandScreen({
    required this.onOpenRedAlert,
    required this.onStartRide,
    required this.onEndRide,
    required this.onSimulateCrash,
    required this.rideStatus,
    required this.meshPeerCount,
    required this.locationService,
    super.key,
  });

  final VoidCallback onOpenRedAlert;
  final VoidCallback onStartRide;
  final VoidCallback onEndRide;
  final VoidCallback onSimulateCrash;
  final RideStatus rideStatus;
  final int meshPeerCount;
  final LocationService locationService;

  @override
  State<SosCommandScreen> createState() => _SosCommandScreenState();
}

class _SosCommandScreenState extends State<SosCommandScreen> {
  LocationPoint? _currentLocation;
  StreamSubscription<LocationPoint>? _locationSub;

  @override
  void initState() {
    super.initState();
    _loadInitialLocation();
    _locationSub = widget.locationService.locationStream.listen((point) {
      if (mounted) setState(() => _currentLocation = point);
    });
  }

  Future<void> _loadInitialLocation() async {
    final loc = await widget.locationService.getCurrentLocation();
    if (mounted) setState(() => _currentLocation = loc);
  }

  Future<void> _openMaps() async {
    final point = _currentLocation;
    if (point == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location not available')),
        );
      }
      return;
    }

    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${point.lat},${point.lng}');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open maps')),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open maps')),
        );
      }
    }
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lat = _currentLocation?.lat ?? 0;
    final lng = _currentLocation?.lng ?? 0;
    final speed = _currentLocation?.speed;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Status bar
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFE8E8E8)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 10, color: Colors.green.shade500),
                        const SizedBox(width: 8),
                        Text(
                          'MESH: ${widget.meshPeerCount} PEERS',
                          style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _RideStatusPill(status: widget.rideStatus),
              const Spacer(),

              // SOS Button
              GestureDetector(
                onLongPress: widget.onOpenRedAlert,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [theme.colorScheme.error, const Color(0xFFFF6D00)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.error.withValues(alpha: 0.3),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.emergency_share, size: 44, color: theme.colorScheme.error),
                        const SizedBox(height: 6),
                        Text(
                          'HOLD\nFOR SOS',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Long press to trigger Red Alert mode',
                style: theme.textTheme.labelMedium?.copyWith(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),

              // Ride controls
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.rideStatus == RideStatus.completed ? widget.onStartRide : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start Ride'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: widget.rideStatus == RideStatus.completed ? null : widget.onEndRide,
                      icon: const Icon(Icons.stop),
                      label: const Text('End Ride'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),
              // Crash simulate (debug)
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: widget.onSimulateCrash,
                  icon: const Icon(Icons.car_crash, size: 18),
                  label: const Text('Simulate Crash (Debug)'),
                  style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600),
                ),
              ),

              const Spacer(),

              // Status cards
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _openMaps,
                      borderRadius: BorderRadius.circular(8),
                      child: _StatusCard(
                        title: 'Coordinates',
                        line1: '${lat.toStringAsFixed(4)}° N',
                        line2: '${lng.toStringAsFixed(4)}° E',
                        icon: Icons.near_me,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatusCard(
                      title: 'Speed',
                      line1: speed != null ? '${(speed * 3.6).toStringAsFixed(1)} km/h' : '0 km/h',
                      line2: 'LIVE TELEMETRY',
                      icon: Icons.speed,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RideStatusPill extends StatelessWidget {
  const _RideStatusPill({required this.status});

  final RideStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      RideStatus.active => ('RIDE: ACTIVE', Colors.green),
      RideStatus.emergency => ('RIDE: EMERGENCY', Theme.of(context).colorScheme.error),
      RideStatus.completed => ('RIDE: IDLE', Colors.grey),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.title, required this.line1, required this.line2, required this.icon});

  final String title;
  final String line1;
  final String line2;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.labelSmall?.copyWith(color: Colors.grey.shade600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(line1, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            Text(line2, style: theme.textTheme.labelSmall?.copyWith(color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }
}