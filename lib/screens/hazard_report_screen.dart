import 'package:appwrite/appwrite.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../config/env_config.dart';
import '../service/local_database.dart';
import '../service/location_service.dart';

class HazardReportScreen extends StatefulWidget {
  const HazardReportScreen({
    required this.databases,
    required this.userId,
    required this.locationService,
    super.key,
  });

  final Databases databases;
  final String userId;
  final LocationService locationService;

  @override
  State<HazardReportScreen> createState() => _HazardReportScreenState();
}

class _HazardReportScreenState extends State<HazardReportScreen> {
  final _types = const <(IconData, String, String)>[
    (Icons.add_road, 'Pothole', 'pothole'),
    (Icons.car_crash, 'Accident', 'accident'),
    (Icons.local_police, 'Theft Risk', 'theft_risk'),
    (Icons.lightbulb, 'No Lights', 'no_lights'),
    (Icons.water_drop, 'Slippery', 'slippery'),
    (Icons.signal_wifi_off, 'No Signal', 'no_signal'),
  ];

  int selected = 0;
  final _detailsController = TextEditingController();
  bool _submitting = false;
  double? _lat;
  double? _lng;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  Future<void> _loadLocation() async {
    final loc = await widget.locationService.getCurrentLocation();
    if (mounted) setState(() { _lat = loc.lat; _lng = loc.lng; });
  }

  Future<void> _submit() async {
    if (_lat == null || _lng == null) return;
    setState(() => _submitting = true);

    final type = _types[selected];
    final now = DateTime.now().toUtc();
    final id = const Uuid().v4();

    final isSignalReport = type.$3 == 'no_signal';
    final table = isSignalReport ? 'connectivity_zones' : 'potholes';

    final localData = isSignalReport
        ? {
            'id': id,
            'reported_by': widget.userId,
            'lat': _lat!,
            'lng': _lng!,
            'signal_strength': 0,
            'reports_count': 1,
            'verified': 0,
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
            'synced': 0,
          }
        : {
            'id': id,
            'reported_by': widget.userId,
            'lat': _lat!,
            'lng': _lng!,
            'severity': 'medium',
            'reports_count': 1,
            'verified': 0,
            'last_reported_at': now.toIso8601String(),
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
            'synced': 0,
          };

    final db = LocalDatabase.instance;
    if (isSignalReport) {
      await db.insertConnectivityZone(localData);
    } else {
      await db.insertPothole(localData);
    }

    // Try remote sync
    try {
      final collectionId = isSignalReport
          ? EnvConfig.connectivityZonesCollection
          : EnvConfig.potholesCollection;
      final remoteData = Map<String, dynamic>.from(localData)
        ..remove('id')
        ..remove('synced');
      // Convert int booleans
      if (remoteData.containsKey('verified')) {
        remoteData['verified'] = false;
      }

      await widget.databases.createDocument(
        databaseId: EnvConfig.appwriteDatabaseId,
        collectionId: collectionId,
        documentId: id,
        data: remoteData,
      );
      await db.markSynced(table, id);
    } catch (_) {
      // Will sync later
    }

    if (mounted) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${type.$2} reported successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Report Hazard')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    Text('Select Hazard Type', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    GridView.builder(
                      itemCount: _types.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 1.15,
                      ),
                      itemBuilder: (context, index) {
                        final item = _types[index];
                        final isSelected = selected == index;
                        return InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => setState(() => selected = index),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected ? theme.colorScheme.primary : const Color(0xFFE0E0E0),
                                width: isSelected ? 2 : 1,
                              ),
                              color: Colors.white,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(item.$1, size: 40, color: isSelected ? theme.colorScheme.primary : Colors.grey.shade600),
                                const SizedBox(height: 8),
                                Text(item.$2, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _detailsController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Details (Optional)',
                        hintText: 'Describe the issue...',
                        prefixIcon: Icon(Icons.edit_note),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.add_location_alt),
                label: Text(_submitting ? 'Submitting...' : 'CONFIRM MARKER'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
              const SizedBox(height: 10),
              Text(
                _lat != null
                    ? 'LOC: ${_lat!.toStringAsFixed(4)}° N / ${_lng!.toStringAsFixed(4)}° E'
                    : 'Getting location...',
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}