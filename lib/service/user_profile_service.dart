import 'package:appwrite/appwrite.dart';

import '../config/env_config.dart';
import '../model/rider_profile.dart';

class UserProfileService {
  UserProfileService({required Databases databases}) : _databases = databases;

  final Databases _databases;

  Future<RiderProfile> fetchProfile(String userId) async {
    try {
      final doc = await _databases.getDocument(
        databaseId: EnvConfig.appwriteDatabaseId,
        collectionId: EnvConfig.usersCollection,
        documentId: userId,
      );
      return RiderProfile.fromMap(doc.$id, doc.data);
    } on AppwriteException catch (error) {
      if (error.code == 404) {
        final profile = RiderProfile.empty(userId);
        await _databases.createDocument(
          databaseId: EnvConfig.appwriteDatabaseId,
          collectionId: EnvConfig.usersCollection,
          documentId: userId,
          data: profile.toMap(),
        );
        return profile;
      }
      rethrow;
    }
  }

  Future<RiderProfile> saveProfile(RiderProfile profile) async {
    final data = profile.toMap();
    try {
      final doc = await _databases.updateDocument(
        databaseId: EnvConfig.appwriteDatabaseId,
        collectionId: EnvConfig.usersCollection,
        documentId: profile.id,
        data: data,
      );
      return RiderProfile.fromMap(doc.$id, doc.data);
    } on AppwriteException catch (error) {
      if (error.code == 404) {
        final doc = await _databases.createDocument(
          databaseId: EnvConfig.appwriteDatabaseId,
          collectionId: EnvConfig.usersCollection,
          documentId: profile.id,
          data: data,
        );
        return RiderProfile.fromMap(doc.$id, doc.data);
      }
      rethrow;
    }
  }
}
