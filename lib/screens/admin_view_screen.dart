import 'package:flutter/material.dart';

import '../controller/admin_controller.dart';

class AdminViewScreen extends StatefulWidget {
  const AdminViewScreen({
    required this.controller,
    super.key,
  });

  final AdminController controller;

  @override
  State<AdminViewScreen> createState() => _AdminViewScreenState();
}

class _AdminViewScreenState extends State<AdminViewScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Admin View')),
      body: SafeArea(
        child: StreamBuilder<AdminDashboardState>(
          stream: widget.controller.stream,
          initialData: widget.controller.currentState,
          builder: (context, snapshot) {
            final state = snapshot.data ?? widget.controller.currentState;
            return RefreshIndicator(
              onRefresh: () async => widget.controller.start(),
              child: ListView(
                padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    title: Text('Active Emergencies', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    trailing: CircleAvatar(
                      backgroundColor: theme.colorScheme.errorContainer,
                      child: Text('${state.activeEmergencies}', style: TextStyle(color: theme.colorScheme.onErrorContainer, fontWeight: FontWeight.w700)),
                    ),
                    subtitle: Text(
                      state.updatedAt == null
                          ? 'Waiting for mesh packets...'
                          : 'Auto refreshed: ${_formatTimestamp(state.updatedAt!)}',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (state.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 36),
                    child: Center(
                      child: Text(
                        'No emergencies yet',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  )
                else
                  ...state.items.map(
                    (item) => Card(
                      child: ListTile(
                        leading: Icon(
                          item.resolved ? Icons.check_circle : Icons.warning,
                          color: item.resolved ? Colors.green : theme.colorScheme.error,
                        ),
                        title: Text('Rider: ${item.riderId}'),
                        subtitle: Text('Hop: ${item.hopCount} • ${_formatTimestamp(item.timestamp)}'),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: item.resolved
                                ? Colors.green.withValues(alpha: 0.15)
                                : theme.colorScheme.error.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            item.resolved ? 'RESOLVED' : 'OPEN',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: item.resolved ? Colors.green.shade700 : theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}