import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Centralised access to environment variables loaded from `.env`.
class EnvConfig {
  static String get appwriteEndpoint =>
      dotenv.env['APPWRITE_ENDPOINT'] ?? 'https://fra.cloud.appwrite.io/v1';

  static String get appwriteProjectId =>
      dotenv.env['APPWRITE_PROJECT_ID'] ?? '699166ea0002abced333';

  static String get appwriteDatabaseId =>
      dotenv.env['APPWRITE_DATABASE_ID'] ?? 'guardian-wheel-db';

  static String get googleMapsApiKey =>
      'AIzaSyAIuA7LFTgIjy1dZCOUYVikpMDuwh3L-P4';

  static String get appUserId =>
      dotenv.env['APP_USER_ID'] ?? '1';

  // Collection IDs matching the Appwrite schema
  static const String usersCollection = 'users';
  static const String ridesCollection = 'rides';
  static const String alertsCollection = 'alerts';
  static const String potholesCollection = 'potholes';
  static const String punctureShopsCollection = 'puncture_shops';
  static const String connectivityZonesCollection = 'connectivity_zones';
  static const String meshNodesCollection = 'mesh_nodes';
}
