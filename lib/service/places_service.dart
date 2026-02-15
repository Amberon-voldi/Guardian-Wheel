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
  static void _applyAndroidIdentityHeaders(HttpClientRequest request) {
    final androidPackage = EnvConfig.googleAndroidPackage.trim();
    final androidSha1 = EnvConfig.googleAndroidSha1.trim();
    if (androidPackage.isNotEmpty && androidSha1.isNotEmpty) {
      request.headers.set('X-Android-Package', androidPackage);
      request.headers.set('X-Android-Cert', androidSha1);
    }
  }

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

    final normalizedInput = input.trim();

    final legacy = await _autocompleteLegacy(
      key: key,
      input: normalizedInput,
      lat: lat,
      lng: lng,
      radius: radius,
      sessionToken: sessionToken,
    );
    if (legacy.predictions.isNotEmpty) {
      return legacy.predictions;
    }

    final placesV1 = await _autocompletePlacesV1(
      key: key,
      input: normalizedInput,
      lat: lat,
      lng: lng,
      radius: radius,
      sessionToken: sessionToken,
    );
    if (placesV1.predictions.isNotEmpty) {
      return placesV1.predictions;
    }

    final geocode = await _autocompleteViaGeocoding(
      key: key,
      input: normalizedInput,
    );
    if (geocode.isNotEmpty) {
      return geocode;
    }

    final legacyErr = legacy.errorMessage?.isNotEmpty == true
        ? ' ${legacy.errorMessage}'
        : '';
    final v1Err = placesV1.errorMessage?.isNotEmpty == true
        ? ' ${placesV1.errorMessage}'
        : '';
    print(
      'Places autocomplete returned no suggestions. '
      'legacy=${legacy.status}$legacyErr; '
      'v1=${placesV1.status}$v1Err; '
      'query="$normalizedInput"',
    );
    return const [];
  }

  static Future<_AutocompleteResponse> _autocompleteLegacy({
    required String key,
    required String input,
    required double lat,
    required double lng,
    required int radius,
    String? sessionToken,
  }) async {
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
      _applyAndroidIdentityHeaders(req);
      final res = await req.close();
      if (res.statusCode != 200) {
        return _AutocompleteResponse(
          predictions: const [],
          status: 'HTTP_${res.statusCode}',
          errorMessage: 'Legacy autocomplete request failed',
        );
      }

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final status = (json['status'] ?? '').toString();
      if (status == 'ZERO_RESULTS') {
        return const _AutocompleteResponse(
          predictions: [],
          status: 'ZERO_RESULTS',
        );
      }
      if (status != 'OK') {
        return _AutocompleteResponse(
          predictions: const [],
          status: status,
          errorMessage: (json['error_message'] ?? '').toString(),
        );
      }

      final predictions = json['predictions'] as List<dynamic>? ?? [];
      return _AutocompleteResponse(
        status: 'OK',
        predictions: predictions.map((p) {
        final map = p as Map<String, dynamic>;
        final structured =
            map['structured_formatting'] as Map<String, dynamic>? ?? {};
        return PlacePrediction(
          placeId: (map['place_id'] ?? '') as String,
          description: (map['description'] ?? '') as String,
          mainText: (structured['main_text'] ?? '') as String,
          secondaryText: (structured['secondary_text'] ?? '') as String,
        );
      }).toList(),
      );
    } catch (error) {
      return _AutocompleteResponse(
        predictions: const [],
        status: 'EXCEPTION',
        errorMessage: error.toString(),
      );
    } finally {
      client?.close(force: true);
    }
  }

  static Future<_AutocompleteResponse> _autocompletePlacesV1({
    required String key,
    required String input,
    required double lat,
    required double lng,
    required int radius,
    String? sessionToken,
  }) async {
    final uri = Uri.parse('https://places.googleapis.com/v1/places:autocomplete');

    final payload = <String, dynamic>{
      'input': input,
      'languageCode': 'en',
      'locationBias': {
        'circle': {
          'center': {
            'latitude': lat,
            'longitude': lng,
          },
          'radius': radius.toDouble(),
        },
      },
    };
    if (sessionToken != null && sessionToken.isNotEmpty) {
      payload['sessionToken'] = sessionToken;
    }

    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('X-Goog-Api-Key', key);
      _applyAndroidIdentityHeaders(req);
      req.headers.set(
        'X-Goog-FieldMask',
        'suggestions.placePrediction.placeId,'
            'suggestions.placePrediction.text.text,'
            'suggestions.placePrediction.structuredFormat.mainText.text,'
            'suggestions.placePrediction.structuredFormat.secondaryText.text',
      );
      req.write(jsonEncode(payload));

      final res = await req.close();
      if (res.statusCode != 200) {
        final body = await res.transform(utf8.decoder).join();
        return _AutocompleteResponse(
          predictions: const [],
          status: 'HTTP_${res.statusCode}',
          errorMessage: body,
        );
      }

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final suggestions = json['suggestions'] as List<dynamic>? ?? const [];
      if (suggestions.isEmpty) {
        return const _AutocompleteResponse(
          predictions: [],
          status: 'ZERO_RESULTS',
        );
      }

      final predictions = <PlacePrediction>[];
      for (final item in suggestions) {
        final map = item as Map<String, dynamic>;
        final placePred = map['placePrediction'] as Map<String, dynamic>?;
        if (placePred == null) continue;

        final placeId = (placePred['placeId'] ?? '').toString();
        if (placeId.isEmpty) continue;

        final text = ((placePred['text'] as Map<String, dynamic>?)?['text'] ?? '')
            .toString();
        final structured =
            placePred['structuredFormat'] as Map<String, dynamic>? ?? {};
        final mainText =
            ((structured['mainText'] as Map<String, dynamic>?)?['text'] ?? '')
                .toString();
        final secondaryText =
            ((structured['secondaryText'] as Map<String, dynamic>?)?['text'] ?? '')
                .toString();

        predictions.add(
          PlacePrediction(
            placeId: placeId,
            description: text.isNotEmpty
                ? text
                : [mainText, secondaryText]
                    .where((s) => s.isNotEmpty)
                    .join(', '),
            mainText: mainText.isNotEmpty ? mainText : text,
            secondaryText: secondaryText,
          ),
        );
      }

      return _AutocompleteResponse(
        predictions: predictions,
        status: predictions.isEmpty ? 'ZERO_RESULTS' : 'OK',
      );
    } catch (error) {
      return _AutocompleteResponse(
        predictions: const [],
        status: 'EXCEPTION',
        errorMessage: error.toString(),
      );
    } finally {
      client?.close(force: true);
    }
  }

  static Future<List<PlacePrediction>> _autocompleteViaGeocoding({
    required String key,
    required String input,
  }) async {
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?address=${Uri.encodeComponent(input)}'
      '&key=$key',
    );

    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.getUrl(uri);
      _applyAndroidIdentityHeaders(req);
      final res = await req.close();
      if (res.statusCode != 200) return const [];

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final status = (json['status'] ?? '').toString();
      if (status != 'OK') return const [];

      final results = json['results'] as List<dynamic>? ?? const [];
      return results.take(5).map((entry) {
        final result = entry as Map<String, dynamic>;
        final placeId = (result['place_id'] ?? '').toString();
        final formatted = (result['formatted_address'] ?? '').toString();
        final parts = formatted.split(',').map((e) => e.trim()).toList();
        final mainText = parts.isNotEmpty ? parts.first : formatted;
        final secondary = parts.length > 1 ? parts.sublist(1).join(', ') : '';
        return PlacePrediction(
          placeId: placeId,
          description: formatted,
          mainText: mainText,
          secondaryText: secondary,
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
      _applyAndroidIdentityHeaders(req);
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

class _AutocompleteResponse {
  const _AutocompleteResponse({
    required this.predictions,
    required this.status,
    this.errorMessage,
  });

  final List<PlacePrediction> predictions;
  final String status;
  final String? errorMessage;
}
