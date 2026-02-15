import 'dart:convert';
import 'dart:io';

import '../config/env_config.dart';

/// A single autocomplete prediction from Google Places API.
class PlacePrediction {
  const PlacePrediction({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
  });

  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;
}

/// Lightweight wrapper around the Google Places Autocomplete API.
/// Falls back gracefully when the API is not enabled – callers should
/// treat an empty result list as "no suggestions available".
class PlacesService {
  /// Fetch autocomplete predictions for [input] biased towards [lat],[lng].
  static Future<List<PlacePrediction>> autocomplete({
    required String input,
    required double lat,
    required double lng,
    String? sessionToken,
    int radius = 50000,
  }) async {
    final key = EnvConfig.googleMapsApiKey.trim();
    if (key.isEmpty || input.trim().length < 2) return const [];

    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json'
      '?input=${Uri.encodeComponent(input)}'
      '&location=$lat,$lng'
      '&radius=$radius'
      '&language=en'
      '${sessionToken != null && sessionToken.isNotEmpty ? '&sessiontoken=$sessionToken' : ''}'
      '&key=$key',
    );

    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) return const [];

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final status = (json['status'] ?? '').toString();
      if (status == 'ZERO_RESULTS') return const [];
      if (status != 'OK') return const [];

      final predictions = json['predictions'] as List<dynamic>? ?? [];
      return predictions.map((p) {
        final map = p as Map<String, dynamic>;
        final structured =
            map['structured_formatting'] as Map<String, dynamic>? ?? {};
        return PlacePrediction(
          placeId: (map['place_id'] ?? '') as String,
          description: (map['description'] ?? '') as String,
          mainText: (structured['main_text'] ?? '') as String,
          secondaryText: (structured['secondary_text'] ?? '') as String,
        );
      }).toList();
    } catch (_) {
      return const [];
    } finally {
      client?.close(force: true);
    }
  }

  /// Get latitude/longitude for a place by its place ID using Place Details API.
  static Future<({double lat, double lng})?> getPlaceLatLng(
      String placeId) async {
    final key = EnvConfig.googleMapsApiKey.trim();
    if (key.isEmpty || placeId.isEmpty) return null;

    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json'
      '?place_id=$placeId'
      '&fields=geometry'
      '&key=$key',
    );

    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) return null;

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if ((json['status'] ?? '') != 'OK') return null;

      final result = json['result'] as Map<String, dynamic>?;
      final geometry = result?['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;
      if (location == null) return null;

      return (
        lat: (location['lat'] as num).toDouble(),
        lng: (location['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
