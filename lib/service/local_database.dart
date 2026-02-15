import 'dart:async';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Offline-first local SQLite database.
/// Stores rides, alerts, hazards and mesh packets locally so the app
/// works fully without internet and syncs back when connectivity returns.
class LocalDatabase {
  LocalDatabase._();
  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = join(dir.path, 'guardian_wheel.db');
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE rides (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        start_lat REAL NOT NULL,
        start_lng REAL NOT NULL,
        end_lat REAL,
        end_lng REAL,
        status TEXT NOT NULL DEFAULT 'active',
        crash_detected INTEGER NOT NULL DEFAULT 0,
        avg_speed REAL,
        max_speed REAL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE alerts (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        ride_id TEXT,
        alert_type TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        notified_contacts INTEGER NOT NULL DEFAULT 0,
        resolved INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE potholes (
        id TEXT PRIMARY KEY,
        reported_by TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        severity TEXT DEFAULT 'medium',
        reports_count INTEGER DEFAULT 1,
        verified INTEGER DEFAULT 0,
        last_reported_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE connectivity_zones (
        id TEXT PRIMARY KEY,
        reported_by TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        signal_strength INTEGER,
        reports_count INTEGER DEFAULT 1,
        verified INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE puncture_shops (
        id TEXT PRIMARY KEY,
        added_by TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        shop_name TEXT,
        is_temporary INTEGER DEFAULT 1,
        verified INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE mesh_packets (
        id TEXT PRIMARY KEY,
        origin TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        hop INTEGER NOT NULL DEFAULT 0,
        ttl INTEGER NOT NULL DEFAULT 5,
        status TEXT NOT NULL,
        last_peer TEXT,
        delivered_at TEXT,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        record_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ── Rides ─────────────────────────────────────────

  Future<void> insertRide(Map<String, dynamic> ride) async {
    final db = await database;
    await db.insert('rides', ride, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateRide(String id, Map<String, dynamic> values) async {
    final db = await database;
    await db.update('rides', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, dynamic>?> getRide(String id) async {
    final db = await database;
    final rows = await db.query('rides', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getUnsynced(String table) async {
    final db = await database;
    return db.query(table, where: 'synced = 0');
  }

  Future<void> markSynced(String table, String id) async {
    final db = await database;
    await db.update(table, {'synced': 1}, where: 'id = ?', whereArgs: [id]);
  }

  // ── Alerts ────────────────────────────────────────

  Future<void> insertAlert(Map<String, dynamic> alert) async {
    final db = await database;
    await db.insert('alerts', alert, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getActiveAlerts() async {
    final db = await database;
    return db.query('alerts', where: 'resolved = 0', orderBy: 'created_at DESC');
  }

  Future<void> resolveAlert(String id) async {
    final db = await database;
    await db.update(
      'alerts',
      {'resolved': 1, 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── Hazards (potholes + connectivity zones) ───────

  Future<void> insertPothole(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert('potholes', data, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertConnectivityZone(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert('connectivity_zones', data, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getNearbyPotholes(
    double minLat,
    double maxLat,
    double minLng,
    double maxLng,
  ) async {
    final db = await database;
    return db.query(
      'potholes',
      where: 'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?',
      whereArgs: [minLat, maxLat, minLng, maxLng],
    );
  }

  Future<List<Map<String, dynamic>>> getNearbyConnectivityZones(
    double minLat,
    double maxLat,
    double minLng,
    double maxLng,
  ) async {
    final db = await database;
    return db.query(
      'connectivity_zones',
      where: 'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?',
      whereArgs: [minLat, maxLat, minLng, maxLng],
    );
  }

  // ── Puncture Shops ────────────────────────────────

  Future<void> insertPunctureShop(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert('puncture_shops', data, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getNearbyPunctureShops(
    double minLat,
    double maxLat,
    double minLng,
    double maxLng,
  ) async {
    final db = await database;
    return db.query(
      'puncture_shops',
      where: 'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?',
      whereArgs: [minLat, maxLat, minLng, maxLng],
    );
  }

  // ── Mesh Packets ──────────────────────────────────

  Future<void> insertMeshPacket(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert('mesh_packets', data, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getAllMeshPackets() async {
    final db = await database;
    return db.query('mesh_packets', orderBy: 'created_at DESC');
  }

  // ── Sync Queue ────────────────────────────────────

  Future<void> enqueueSync({
    required String tableName,
    required String recordId,
    required String operation,
    required String payload,
  }) async {
    final db = await database;
    await db.insert('sync_queue', {
      'table_name': tableName,
      'record_id': recordId,
      'operation': operation,
      'payload': payload,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'attempts': 0,
    });
  }

  Future<List<Map<String, dynamic>>> getPendingSyncItems() async {
    final db = await database;
    return db.query('sync_queue', orderBy: 'created_at ASC');
  }

  Future<void> deleteSyncItem(int id) async {
    final db = await database;
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementSyncAttempt(int id) async {
    final db = await database;
    await db.rawUpdate('UPDATE sync_queue SET attempts = attempts + 1 WHERE id = ?', [id]);
  }
}
