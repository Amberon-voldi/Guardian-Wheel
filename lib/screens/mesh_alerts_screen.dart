import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/alert_controller.dart';
import '../model/mesh_packet.dart';
import '../service/mesh_service.dart';
import '../theme/guardian_theme.dart';

class MeshAlertsScreen extends StatefulWidget {
  const MeshAlertsScreen({
    this.onOpenAdmin,
    required this.meshService,
    required this.alertController,
    super.key,
  });

  final VoidCallback? onOpenAdmin;
  final MeshService meshService;
  final AlertController alertController;

  @override
  State<MeshAlertsScreen> createState() => _MeshAlertsScreenState();
}

class _MeshAlertsScreenState extends State<MeshAlertsScreen> {
  final List<MeshPacketState> _packets = [];
  StreamSubscription<MeshPacketState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.meshService.packetStates.listen((state) {
      if (mounted) {
        setState(() {
          _packets.insert(0, state);
          if (_packets.length > 50) _packets.removeLast();
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final critical = _packets.where((p) =>
        p.status == MeshPacketStatus.created ||
        p.status == MeshPacketStatus.forwarding).toList();
    final resolved = _packets.where((p) =>
        p.status == MeshPacketStatus.delivered ||
        p.status == MeshPacketStatus.expired ||
        p.status == MeshPacketStatus.duplicateDropped).toList();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Mesh Alerts', style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900, letterSpacing: -0.5,
                        )),
                        const SizedBox(height: 2),
                        Text(
                          'Nearby rider communication',
                          style: theme.textTheme.bodySmall?.copyWith(color: GuardianTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: GuardianTheme.meshBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: GuardianTheme.meshBlue.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.meshService.peerCount > 0 ? GuardianTheme.success : GuardianTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${widget.meshService.peerCount} NODES',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: GuardianTheme.meshBlue),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: widget.onOpenAdmin,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                    tooltip: 'Open Admin View',
                    style: IconButton.styleFrom(backgroundColor: Colors.grey.shade100),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _packets.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: GuardianTheme.meshBlue.withValues(alpha: 0.06),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.cell_tower, size: 48, color: GuardianTheme.meshBlue.withValues(alpha: 0.4)),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No mesh activity yet',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: GuardianTheme.textPrimary, fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Alerts from nearby riders will appear here\nwhen mesh peers are discovered.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(color: GuardianTheme.textSecondary),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        children: [
                          if (critical.isNotEmpty) ...[
                            _SectionLabel(icon: Icons.error, text: 'ACTIVE (${critical.length})', color: theme.colorScheme.error),
                            ...critical.map((s) => _PacketCard(state: s, critical: true)),
                          ],
                          if (resolved.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _SectionLabel(icon: Icons.check_circle, text: 'RESOLVED (${resolved.length})', color: Colors.green),
                            ...resolved.map((s) => _PacketCard(state: s)),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
        ],
      ),
    );
  }
}

class _PacketCard extends StatelessWidget {
  const _PacketCard({required this.state, this.critical = false});

  final MeshPacketState state;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final packet = state.packet;
    final timeAgo = DateTime.now().toUtc().difference(state.timestamp);
    final timeStr = timeAgo.inMinutes < 1
        ? '${timeAgo.inSeconds}s ago'
        : '${timeAgo.inMinutes}m ago';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  critical ? Icons.warning_amber : Icons.check_circle_outline,
                  size: 16,
                  color: critical ? theme.colorScheme.error : Colors.green,
                ),
                const SizedBox(width: 6),
                Text(
                  '${state.status.name.toUpperCase()} • $timeStr',
                  style: theme.textTheme.labelMedium?.copyWith(color: Colors.grey.shade600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              packet.origin,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Hop: ${packet.hop}/${packet.ttl} • ${state.message ?? ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}