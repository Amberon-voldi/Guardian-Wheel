import 'dart:async';
import 'package:appwrite/appwrite.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../config/env_config.dart';
import 'local_database.dart';

/// Watches connectivity and pushes unsynced local records to Appwrite
/// whenever the device comes back online.
class SyncService {
  SyncService({
    required Databases databases,
    Connectivity? connectivity,
  })  : _databases = databases,
        _connectivity = connectivity ?? Connectivity();

  final Databases _databases;
  final Connectivity _connectivity;
  final LocalDatabase _localDb = LocalDatabase.instance;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicSync;
  bool _syncing = false;

  void start() {
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        syncAll();
      }
    });
    // Also run a periodic sync every 30 seconds as a safety net.
    _periodicSync = Timer.periodic(const Duration(seconds: 30), (_) => syncAll());
  }

  Future<void> syncAll() async {
    if (_syncing) return;
    _syncing = true;

    try {
      await _syncTable('rides', EnvConfig.ridesCollection);
      await _syncTable('alerts', EnvConfig.alertsCollection);
      await _syncTable('potholes', EnvConfig.potholesCollection);
      await _syncTable('connectivity_zones', EnvConfig.connectivityZonesCollection);
      await _syncTable('puncture_shops', EnvConfig.punctureShopsCollection);
    } catch (_) {
      // Ignore – will retry on next cycle.
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncTable(String localTable, String collectionId) async {
    final rows = await _localDb.getUnsynced(localTable);
    for (final row in rows) {
      final id = row['id'] as String;
      final data = _toRemoteData(localTable, row);

      // Convert SQLite ints back to booleans for Appwrite
      _fixBooleans(data);

      try {
        await _databases.createDocument(
          databaseId: EnvConfig.appwriteDatabaseId,
          collectionId: collectionId,
          documentId: id,
          data: data,
        );
        await _localDb.markSynced(localTable, id);
      } on AppwriteException catch (e) {
        // 409 = document already exists – treat as success
        if (e.code == 409) {
          try {
            await _databases.updateDocument(
              databaseId: EnvConfig.appwriteDatabaseId,
              collectionId: collectionId,
              documentId: id,
              data: data,
            );
          } catch (_) {}
          await _localDb.markSynced(localTable, id);
        }
        // Other errors will be retried next cycle.
      } catch (_) {
        // Retry next cycle.
      }
    }
  }

  void _fixBooleans(Map<String, dynamic> data) {
    for (final key in data.keys.toList()) {
      final value = data[key];
      if (value is int &&
          (key.startsWith('is_') ||
              key == 'verified' ||
              key == 'resolved' ||
              key == 'notified_contacts' ||
              key == 'crash_detected')) {
        data[key] = value == 1;
      }
    }
  }

  Map<String, dynamic> _toRemoteData(String localTable, Map<String, dynamic> row) {
    final data = Map<String, dynamic>.from(row)
      ..remove('id')
      ..remove('synced')
      ..remove('created_at')
      ..remove('updated_at');

    switch (localTable) {
      case 'potholes':
        data.remove('created_at');
        data.remove('updated_at');
        data.remove('last_reported_at');
        break;
      case 'connectivity_zones':
      case 'puncture_shops':
      case 'rides':
      case 'alerts':
      default:
        break;
    }

    data.removeWhere((_, value) => value == null);
    return data;
  }

  Future<void> dispose() async {
    _periodicSync?.cancel();
    await _connectivitySub?.cancel();
  }
}
