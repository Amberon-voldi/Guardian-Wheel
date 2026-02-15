import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/guardian_theme.dart';

class RedAlertScreen extends StatefulWidget {
  const RedAlertScreen({super.key, this.onCancel});

  final VoidCallback? onCancel;

  @override
  State<RedAlertScreen> createState() => _RedAlertScreenState();
}

class _RedAlertScreenState extends State<RedAlertScreen> {
  late final Stopwatch _stopwatch;
  Timer? _timer;
  String _elapsed = '00:00:00';

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final d = _stopwatch.elapsed;
      setState(() {
        _elapsed =
            '${d.inHours.toString().padLeft(2, '0')}:'
            '${(d.inMinutes % 60).toString().padLeft(2, '0')}:'
            '${(d.inSeconds % 60).toString().padLeft(2, '0')}';
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _badge(context, Icons.wifi_tethering, 'MESH: ACTIVE'),
                  _badge(context, Icons.battery_alert, '82%'),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: GuardianTheme.danger.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.notification_important, size: 64, color: theme.colorScheme.error),
              ),
              const SizedBox(height: 16),
              Text('HELP\nREQUESTED', textAlign: TextAlign.center, style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w900, letterSpacing: -0.5,
              )),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: GuardianTheme.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Emergency Beacon Active', style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.error, fontWeight: FontWeight.w700,
                )),
              ),
              const SizedBox(height: 24),
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.3))),
                color: Colors.white,
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text(_elapsed, style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: theme.colorScheme.error)),
                      const SizedBox(height: 12),
                      const Row(
                        children: [
                          Expanded(child: _MiniMetric(title: 'Riders Alerted', value: '3')),
                          SizedBox(width: 12),
                          Expanded(child: _MiniMetric(title: 'Signal', value: 'GOOD')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onHorizontalDragEnd: (_) {
                  widget.onCancel?.call();
                  Navigator.of(context).pop();
                },
                child: Container(
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Colors.grey.shade100,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 84,
                        margin: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: theme.colorScheme.error, borderRadius: BorderRadius.circular(999)),
                        child: const Icon(Icons.close, color: Colors.white, size: 30),
                      ),
                      Expanded(
                        child: Text(
                          'Slide to Cancel Alarm',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('ID: KA-05-9922 • SESSION: #E92-A1', style: theme.textTheme.labelSmall?.copyWith(color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade700),
          const SizedBox(width: 6),
          Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}