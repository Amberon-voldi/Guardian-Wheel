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
  final List<String> _wifiEvents = [];
  StreamSubscription<MeshPacketState>? _sub;
  StreamSubscription<int>? _peerSub;
  StreamSubscription? _wifiStateSub;
  bool _showWifiEvents = false;
  String _wifiStatusMessage = 'Wi‑Fi Direct idle';
  String _ownerDiagText = 'Owner diagnostics unavailable';

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

    _peerSub = widget.meshService.peerCountStream.listen((_) {
      if (mounted) setState(() {});
    });

    _wifiStateSub = widget.meshService.wifiStateEvents.listen((event) {
      if (!mounted) return;
      final stateName = event.state?.name.toUpperCase();
      final callback = event.callback;
      final message = event.message;
      final ip = event.ip;
      final line = [
        if (stateName != null) stateName,
        if (callback != null) callback,
        if (message != null) message,
        if (ip != null) 'ip=$ip',
        if (event.ownerIp != null) 'ownerIp=${event.ownerIp}',
        if (event.targetAddress != null) 'target=${event.targetAddress}',
        if (event.reasonCode != null) 'reason=${event.reasonCode}',
      ].join(' • ');

      final ownerDiag = [
        if (event.ownerIp != null) 'Owner IP: ${event.ownerIp}',
        if (event.groupFormed != null) 'Group Formed: ${event.groupFormed}',
        if (event.isGroupOwner != null) 'I am GO: ${event.isGroupOwner}',
        if (event.targetAddress != null) 'Target: ${event.targetAddress}',
        if (event.targetName != null) 'Target Name: ${event.targetName}',
        if (event.appPeerCount != null) 'App Peers: ${event.appPeerCount}',
        if (event.pendingPeerCount != null)
          'Pending Peers: ${event.pendingPeerCount}',
        if (event.reasonCode != null) 'Last Reason Code: ${event.reasonCode}',
      ].join(' • ');

      setState(() {
        if (line.isNotEmpty) {
          _wifiEvents.insert(0, line);
        }
        if (_wifiEvents.length > 40) {
          _wifiEvents.removeLast();
        }
        if (ownerDiag.isNotEmpty) {
          _ownerDiagText = ownerDiag;
        }
        _wifiStatusMessage = stateName != null
            ? 'Wi‑Fi Direct $stateName'
            : (message ?? _wifiStatusMessage);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _peerSub?.cancel();
    _wifiStateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final critical = _packets
        .where(
          (p) =>
              p.status == MeshPacketStatus.created ||
              p.status == MeshPacketStatus.received ||
              p.status == MeshPacketStatus.forwarded ||
              p.status == MeshPacketStatus.forwarding,
        )
        .toList();
    final resolved = _packets
        .where(
          (p) =>
              p.status == MeshPacketStatus.delivered ||
              p.status == MeshPacketStatus.expired ||
              p.status == MeshPacketStatus.duplicateDropped,
        )
        .toList();

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
                        Text(
                          'Mesh Alerts',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Nearby rider communication',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: GuardianTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: GuardianTheme.meshBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: GuardianTheme.meshBlue.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.meshService.peerCount > 0
                                ? GuardianTheme.success
                                : GuardianTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${widget.meshService.peerCount} NODES',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: GuardianTheme.meshBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: widget.onOpenAdmin,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                    tooltip: 'Open Admin View',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey.shade100,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            widget.meshService.isWifiDirectActive
                                ? Icons.wifi_tethering
                                : Icons.wifi_tethering_off,
                            size: 18,
                            color: widget.meshService.isWifiDirectActive
                                ? GuardianTheme.success
                                : GuardianTheme.danger,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.meshService.isWifiDirectActive
                                ? 'Wi‑Fi Direct active'
                                : 'Wi‑Fi Direct inactive',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          OutlinedButton(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              await widget.meshService.restartMesh();
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('Wi‑Fi Direct restarted'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              setState(() {});
                            },
                            child: const Text('Restart Scan'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _wifiStatusMessage,
                        style: const TextStyle(
                          color: GuardianTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _ownerDiagText,
                        style: const TextStyle(
                          color: GuardianTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.router_outlined, size: 18),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Wi‑Fi Direct Events',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Text(
                            '${_wifiEvents.length} events',
                            style: const TextStyle(
                              color: GuardianTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch.adaptive(
                            value: _showWifiEvents,
                            onChanged: (value) {
                              setState(() => _showWifiEvents = value);
                            },
                          ),
                        ],
                      ),
                      if (_showWifiEvents) ...[
                        const SizedBox(height: 8),
                        if (_wifiEvents.isEmpty)
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'No Wi‑Fi Direct events yet.',
                              style: TextStyle(
                                color: GuardianTheme.textSecondary,
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            height: 180,
                            child: ListView.builder(
                              itemCount: _wifiEvents.length,
                              itemBuilder: (context, index) {
                                final item = _wifiEvents[index];
                                final isProblem =
                                    item.contains('FAILED') ||
                                    item.contains('onDisconnected');
                                final stateColor = isProblem
                                    ? GuardianTheme.danger
                                    : GuardianTheme.success;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: stateColor.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: stateColor.withValues(
                                          alpha: 0.22,
                                        ),
                                      ),
                                    ),
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          isProblem
                                              ? 'ISSUE DETECTED'
                                              : 'STATUS UPDATE',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: stateColor,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          item,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: GuardianTheme.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _packets.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: GuardianTheme.meshBlue.withValues(
                                  alpha: 0.06,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.cell_tower,
                                size: 48,
                                color: GuardianTheme.meshBlue.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No mesh activity yet',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: GuardianTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Alerts from nearby riders will appear here\nwhen mesh peers are discovered.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: GuardianTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        children: [
                          if (critical.isNotEmpty) ...[
                            _SectionLabel(
                              icon: Icons.error,
                              text: 'ACTIVE (${critical.length})',
                              color: theme.colorScheme.error,
                            ),
                            ...critical.map(
                              (s) => _PacketCard(state: s, critical: true),
                            ),
                          ],
                          if (resolved.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _SectionLabel(
                              icon: Icons.check_circle,
                              text: 'RESOLVED (${resolved.length})',
                              color: Colors.green,
                            ),
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
  const _SectionLabel({
    required this.icon,
    required this.text,
    required this.color,
  });

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
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
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
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              packet.origin,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Hop: ${packet.hop}/${packet.ttl} • ${state.message ?? ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey.shade600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
