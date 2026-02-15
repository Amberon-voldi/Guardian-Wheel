import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/ride_status.dart';
import '../service/location_service.dart';
import '../theme/guardian_theme.dart';

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

    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${point.lat},${point.lng}');
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
    final speed = 0;
    final hasLocation = _currentLocation != null;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ride Command',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Guardian Wheel Safety System',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: GuardianTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _MeshBadge(peerCount: widget.meshPeerCount),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Status Strip ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _RideStatusPill(status: widget.rideStatus),
                  const SizedBox(width: 8),
                  _GpsBadge(hasSignal: hasLocation),
                ],
              ),
            ),

            const Spacer(),

            // ── SOS Button ──
            _SosButton(onLongPress: widget.onOpenRedAlert),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.touch_app, size: 16, color: Colors.grey.shade400),
                const SizedBox(width: 6),
                Text(
                  'Long press to trigger emergency alert',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey.shade500),
                ),
              ],
            ),

            const SizedBox(height: 24),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: widget.onSimulateCrash,
              icon: Icon(Icons.car_crash,
                  size: 15, color: Colors.grey.shade400),
              label: Text('Simulate Crash (Debug)',
                  style:
                      TextStyle(color: Colors.grey.shade400, fontSize: 12)),
            ),

            const Spacer(),

            // ── Telemetry ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: _TelemetryCard(
                      title: 'Coordinates',
                      value: '${lat.toStringAsFixed(4)}\u00b0 N',
                      subtitle: '${lng.toStringAsFixed(4)}\u00b0 E',
                      icon: Icons.near_me,
                      onTap: _openMaps,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TelemetryCard(
                      title: 'Speed',
                      value: (speed * 3.6).toStringAsFixed(1),
                      subtitle: 'km/h',
                      icon: Icons.speed,
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

// ══════════════════════════════════════════
// ── SOS Button with pulse animation ──
// ══════════════════════════════════════════

class _SosButton extends StatefulWidget {
  const _SosButton({required this.onLongPress});

  final VoidCallback onLongPress;

  @override
  State<_SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<_SosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        return Transform.scale(
          scale: _pulse.value,
          child: GestureDetector(
            onLongPress: widget.onLongPress,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: GuardianTheme.dangerGradient,
                boxShadow: [
                  BoxShadow(
                    color: GuardianTheme.danger
                        .withValues(alpha: 0.25 * _pulse.value),
                    blurRadius: 30 + (12 * _pulse.value),
                    spreadRadius: 4,
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
                    Icon(Icons.emergency_share,
                        size: 40, color: theme.colorScheme.error),
                    const SizedBox(height: 4),
                    Text(
                      'SOS',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════
// ── Helper Widgets ──
// ══════════════════════════════════════════

class _MeshBadge extends StatelessWidget {
  const _MeshBadge({required this.peerCount});

  final int peerCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: GuardianTheme.meshBlue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: GuardianTheme.meshBlue.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: peerCount > 0
                  ? GuardianTheme.success
                  : GuardianTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$peerCount PEERS',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: GuardianTheme.meshBlue,
            ),
          ),
        ],
      ),
    );
  }
}

class _RideStatusPill extends StatelessWidget {
  const _RideStatusPill({required this.status});

  final RideStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      RideStatus.active => ('ACTIVE', GuardianTheme.success, Icons.two_wheeler),
      RideStatus.emergency => (
        'EMERGENCY',
        GuardianTheme.danger,
        Icons.warning_amber_rounded
      ),
      RideStatus.completed => ('IDLE', GuardianTheme.textSecondary, Icons.pause_circle_outline),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _GpsBadge extends StatelessWidget {
  const _GpsBadge({required this.hasSignal});

  final bool hasSignal;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: (hasSignal ? GuardianTheme.success : GuardianTheme.warning)
            .withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasSignal ? Icons.gps_fixed : Icons.gps_not_fixed,
            size: 14,
            color: hasSignal ? GuardianTheme.success : GuardianTheme.warning,
          ),
          const SizedBox(width: 5),
          Text(
            hasSignal ? 'GPS' : 'NO GPS',
            style: TextStyle(
              color:
                  hasSignal ? GuardianTheme.success : GuardianTheme.warning,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _TelemetryCard extends StatelessWidget {
  const _TelemetryCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    this.onTap,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE8E8E8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon,
                        size: 14, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Text(title,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: GuardianTheme.textSecondary)),
                  if (onTap != null) ...[
                    const Spacer(),
                    Icon(Icons.open_in_new,
                        size: 12, color: Colors.grey.shade400),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(value,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              Text(subtitle,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: GuardianTheme.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
