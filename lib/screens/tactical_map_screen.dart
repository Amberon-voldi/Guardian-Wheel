import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/env_config.dart';
import '../controller/alert_controller.dart';
import '../service/location_service.dart';
import '../service/places_service.dart';
import '../theme/guardian_theme.dart';

class TacticalMapScreen extends StatefulWidget {
  const TacticalMapScreen({
    required this.onReportHazard,
    this.incomingRoute,
    required this.locationService,
    super.key,
  });

  final VoidCallback onReportHazard;
  final AlertRoute? incomingRoute;
  final LocationService locationService;

  @override
  State<TacticalMapScreen> createState() => _TacticalMapScreenState();
}

class _TacticalMapScreenState extends State<TacticalMapScreen> {
  // ── Map ──
  GoogleMapController? _mapController;
  StreamSubscription<LocationPoint>? _locationSub;
  LatLng _currentPosition = const LatLng(12.9716, 77.5946);
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  bool _mapReady = false;

  // ── Search / Autocomplete ──
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<PlacePrediction> _suggestions = [];
  bool _showSuggestions = false;
  bool _loadingSuggestions = false;
  Timer? _debounce;
  String _autocompleteSessionToken = '';
  int _autocompleteRequestId = 0;

  // ── Search Route ──
  _FullRoute? _searchRoute;
  bool _resolvingRoute = false;
  bool _isNavigating = false;

  // ── Alert Route ──
  bool _resolvingAlertRoute = false;

  // ── Lifecycle ──

  @override
  void initState() {
    super.initState();
    _initLocation();
    _autocompleteSessionToken = _newAutocompleteSessionToken();
    _searchFocus.addListener(() {
      if (!mounted) return;
      setState(() {
        _showSuggestions = _searchFocus.hasFocus && _suggestions.isNotEmpty;
      });
    });
    _searchCtrl.addListener(_onSearchTextChanged);
  }

  @override
  void didUpdateWidget(covariant TacticalMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.incomingRoute != oldWidget.incomingRoute) {
      unawaited(_drawAlertRoute());
    }
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  // ── Location ──

  Future<void> _initLocation() async {
    final loc = await widget.locationService.getCurrentLocation();
    setState(() {
      _currentPosition = LatLng(loc.lat, loc.lng);
      _updateMyMarker();
    });

    _locationSub = widget.locationService.locationStream.listen((point) {
      if (!mounted) return;
      setState(() {
        _currentPosition = LatLng(point.lat, point.lng);
        _updateMyMarker();
      });

      if (_isNavigating) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
                target: _currentPosition, zoom: 17, tilt: 50, bearing: 0),
          ),
        );
      } else if (widget.incomingRoute == null && _searchRoute == null) {
        _mapController?.animateCamera(CameraUpdate.newLatLng(_currentPosition));
      }
    });
  }

  void _updateMyMarker() {
    _markers.removeWhere((m) => m.markerId.value == 'me');
    _markers.add(
      Marker(
        markerId: const MarkerId('me'),
        position: _currentPosition,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'You'),
      ),
    );
  }

  // ── Search / Autocomplete ──

  void _onSearchTextChanged() {
    final text = _searchCtrl.text;
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (text.trim().isEmpty) {
      _autocompleteSessionToken = _newAutocompleteSessionToken();
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
        _loadingSuggestions = false;
      });
      return;
    }
    if (text.trim().length < 2) {
      if (_showSuggestions) {
        setState(() {
          _suggestions = [];
          _showSuggestions = false;
          _loadingSuggestions = false;
        });
      }
      return;
    }
    _debounce = Timer(
        const Duration(milliseconds: 400), () => _fetchSuggestions(text));
  }

  Future<void> _fetchSuggestions(String input) async {
    final requestId = ++_autocompleteRequestId;
    if (mounted) {
      setState(() {
        _loadingSuggestions = true;
        _showSuggestions = _searchFocus.hasFocus;
      });
    }

    final results = await PlacesService.autocomplete(
      input: input,
      lat: _currentPosition.latitude,
      lng: _currentPosition.longitude,
      sessionToken: _autocompleteSessionToken,
    );

    if (requestId != _autocompleteRequestId) {
      return;
    }

    if (mounted) {
      setState(() {
        _suggestions = results;
        _loadingSuggestions = false;
        _showSuggestions = _searchFocus.hasFocus &&
            (_suggestions.isNotEmpty || _searchCtrl.text.trim().length >= 2);
      });
    }
  }

  Future<void> _selectPlace(PlacePrediction place) async {
    // Update text without re-triggering autocomplete
    _searchCtrl.removeListener(_onSearchTextChanged);
    _searchCtrl.text = place.mainText;
    _searchCtrl.addListener(_onSearchTextChanged);

    _searchFocus.unfocus();
    setState(() {
      _showSuggestions = false;
      _resolvingRoute = true;
    });
    _autocompleteSessionToken = _newAutocompleteSessionToken();

    final latLng = await PlacesService.getPlaceLatLng(place.placeId);
    if (!mounted) return;

    if (latLng != null) {
      await _buildRouteToCoordinates(
        destination: LatLng(latLng.lat, latLng.lng),
        name: place.mainText,
        address: place.secondaryText,
      );
    } else {
      await _buildRouteByQuery(
          query: place.description, name: place.mainText);
    }

    if (mounted) setState(() => _resolvingRoute = false);
  }

  Future<void> _onSearchSubmitted() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;

    _searchFocus.unfocus();
    setState(() {
      _showSuggestions = false;
      _resolvingRoute = true;
    });
    _autocompleteSessionToken = _newAutocompleteSessionToken();
    await _buildRouteByQuery(query: query, name: query);
    if (mounted) setState(() => _resolvingRoute = false);
  }

  String _newAutocompleteSessionToken() =>
      DateTime.now().microsecondsSinceEpoch.toString();

  // ── Route Building ──

  Future<void> _buildRouteToCoordinates({
    required LatLng destination,
    required String name,
    String address = '',
  }) async {
    final result = await _fetchDirections(
        origin: _currentPosition, destination: destination);
    if (result == null || result.points.isEmpty) {
      _showRouteError();
      return;
    }
    _applySearchRoute(_FullRoute(
      points: result.points,
      steps: result.steps,
      distanceKm: result.distanceKm,
      durationMinutes: result.durationMinutes,
      destinationName: name,
      destinationAddress: address.isNotEmpty ? address : result.destinationAddress,
      destinationLatLng: destination,
    ));
  }

  Future<void> _buildRouteByQuery(
      {required String query, String name = ''}) async {
    final result = await _fetchDirectionsByQuery(
        origin: _currentPosition, destinationQuery: query);
    if (result == null || result.points.isEmpty) {
      _showRouteError();
      return;
    }
    _applySearchRoute(_FullRoute(
      points: result.points,
      steps: result.steps,
      distanceKm: result.distanceKm,
      durationMinutes: result.durationMinutes,
      destinationName: name.isNotEmpty ? name : query,
      destinationAddress: result.destinationAddress,
      destinationLatLng: result.points.last,
    ));
  }

  void _applySearchRoute(_FullRoute route) {
    _clearSearchRoute(notify: false);

    _polylines.add(Polyline(
      polylineId: const PolylineId('search_route'),
      points: route.points,
      color: GuardianTheme.accentBlue,
      width: 5,
    ));
    _markers.add(Marker(
      markerId: const MarkerId('search_dest'),
      position: route.destinationLatLng,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: InfoWindow(title: route.destinationName),
    ));

    _searchRoute = route;
    _focusRoute(route.points);
    if (mounted) setState(() {});
  }

  void _clearSearchRoute({bool notify = true}) {
    _polylines.removeWhere((p) => p.polylineId.value == 'search_route');
    _markers.removeWhere((m) => m.markerId.value.startsWith('search_'));
    _searchRoute = null;
    _isNavigating = false;
    if (notify && mounted) setState(() {});
  }

  void _startNavigation() {
    setState(() => _isNavigating = true);
    _mapController?.animateCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: _currentPosition, zoom: 17, tilt: 50),
    ));
  }

  void _endNavigation() {
    setState(() => _isNavigating = false);
    if (_searchRoute != null) _focusRoute(_searchRoute!.points);
  }

  void _showRouteError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Unable to find a route to that destination.'),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Alert Route (Mesh) ──

  Future<void> _drawAlertRoute() async {
    _polylines.removeWhere((p) => p.polylineId.value == 'help_route');
    _markers.removeWhere((m) => m.markerId.value.startsWith('route_'));

    final route = widget.incomingRoute;
    if (route == null || route.waypoints.length < 2) {
      if (mounted) setState(() {});
      return;
    }

    setState(() => _resolvingAlertRoute = true);

    var points =
        route.waypoints.map((wp) => LatLng(wp.lat, wp.lng)).toList();
    final resolved =
        await _fetchDirectionsPolyline(points.first, points.last);
    if (resolved.isNotEmpty) points = resolved;

    if (!mounted) return;
    setState(() => _resolvingAlertRoute = false);

    _polylines.add(Polyline(
      polylineId: const PolylineId('help_route'),
      points: points,
      color: Colors.deepOrange,
      width: 5,
    ));
    _markers.add(Marker(
      markerId: const MarkerId('route_start'),
      position: points.first,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      infoWindow: const InfoWindow(title: 'Your Position'),
    ));
    _markers.add(Marker(
      markerId: const MarkerId('route_dest'),
      position: points.last,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: InfoWindow(
        title: 'Rider in Need',
        snippet: '${route.distanceKm.toStringAsFixed(1)} km away',
      ),
    ));

    await _focusRoute(points);
    if (mounted) setState(() {});
  }

  // ── Directions API ──

  Future<_DirectionsResult?> _fetchDirections({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final key = EnvConfig.googleMapsApiKey.trim();
    if (key.isEmpty) return null;
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${destination.latitude},${destination.longitude}'
      '&mode=driving&key=$key',
    );
    return _parseDirectionsResponse(uri);
  }

  Future<_DirectionsResult?> _fetchDirectionsByQuery({
    required LatLng origin,
    required String destinationQuery,
  }) async {
    final key = EnvConfig.googleMapsApiKey.trim();
    if (key.isEmpty) return null;
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${Uri.encodeComponent(destinationQuery)}'
      '&mode=driving&key=$key',
    );
    return _parseDirectionsResponse(uri);
  }

  Future<_DirectionsResult?> _parseDirectionsResponse(Uri uri) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) return null;

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if ((json['status'] ?? '') != 'OK') return null;

      final routes = (json['routes'] as List<dynamic>?) ?? [];
      if (routes.isEmpty) return null;

      final firstRoute = routes.first as Map<String, dynamic>;
      final overview =
          firstRoute['overview_polyline'] as Map<String, dynamic>?;
      final encoded = (overview?['points'] ?? '').toString();
      if (encoded.isEmpty) return null;

      final legs = (firstRoute['legs'] as List<dynamic>?) ?? [];
      final firstLeg =
          legs.isNotEmpty ? legs.first as Map<String, dynamic> : null;
      final distanceM =
          ((firstLeg?['distance'] as Map<String, dynamic>?)?['value']
                      as num?)
                  ?.toDouble() ??
              0;
      final durationS =
          ((firstLeg?['duration'] as Map<String, dynamic>?)?['value']
                      as num?)
                  ?.toDouble() ??
              0;
      final destAddress = (firstLeg?['end_address'] ?? '').toString();

      // Parse steps
      final stepsJson = (firstLeg?['steps'] as List<dynamic>?) ?? [];
      final steps = stepsJson.map((s) {
        final step = s as Map<String, dynamic>;
        final dist = step['distance'] as Map<String, dynamic>? ?? {};
        final dur = step['duration'] as Map<String, dynamic>? ?? {};
        final startLoc =
            step['start_location'] as Map<String, dynamic>? ?? {};
        final endLoc =
            step['end_location'] as Map<String, dynamic>? ?? {};
        return _RouteStep(
          instruction:
              _stripHtml((step['html_instructions'] ?? '').toString()),
          distanceText: (dist['text'] ?? '').toString(),
          distanceMeters: (dist['value'] as num?)?.toDouble() ?? 0,
          durationText: (dur['text'] ?? '').toString(),
          startLocation: LatLng(
            (startLoc['lat'] as num?)?.toDouble() ?? 0,
            (startLoc['lng'] as num?)?.toDouble() ?? 0,
          ),
          endLocation: LatLng(
            (endLoc['lat'] as num?)?.toDouble() ?? 0,
            (endLoc['lng'] as num?)?.toDouble() ?? 0,
          ),
          maneuver: (step['maneuver'] ?? '').toString(),
        );
      }).toList();

      return _DirectionsResult(
        points: _decodePolyline(encoded),
        steps: steps,
        distanceKm: distanceM / 1000,
        durationMinutes: (durationS / 60).round(),
        destinationAddress: destAddress,
      );
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<List<LatLng>> _fetchDirectionsPolyline(
      LatLng origin, LatLng dest) async {
    final result =
        await _fetchDirections(origin: origin, destination: dest);
    return result?.points ?? [];
  }

  // ── Utility ──

  static String _stripHtml(String html) =>
      html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      var result = 0, shift = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      result = 0;
      shift = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  Future<void> _focusRoute(List<LatLng> points) async {
    if (_mapController == null || points.isEmpty) return;
    if (points.length == 1) {
      await _mapController!
          .animateCamera(CameraUpdate.newLatLngZoom(points.first, 16));
      return;
    }

    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    final minLat = lats.reduce((a, b) => a < b ? a : b);
    final maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLng = lngs.reduce((a, b) => a < b ? a : b);
    final maxLng = lngs.reduce((a, b) => a > b ? a : b);

    if ((maxLat - minLat).abs() < 0.0001 &&
        (maxLng - minLng).abs() < 0.0001) {
      await _mapController!
          .animateCamera(CameraUpdate.newLatLngZoom(points.last, 16));
      return;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    await _mapController!
        .animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  static IconData _maneuverIcon(String maneuver) {
    return switch (maneuver) {
      'turn-left' ||
      'turn-slight-left' ||
      'turn-sharp-left' =>
        Icons.turn_left,
      'turn-right' ||
      'turn-slight-right' ||
      'turn-sharp-right' =>
        Icons.turn_right,
      'uturn-left' => Icons.u_turn_left,
      'uturn-right' => Icons.u_turn_right,
      'straight' => Icons.straight,
      'merge' => Icons.merge,
      'fork-left' || 'ramp-left' || 'keep-left' => Icons.fork_left,
      'fork-right' || 'ramp-right' || 'keep-right' => Icons.fork_right,
      'roundabout-left' || 'roundabout-right' => Icons.roundabout_left,
      _ => Icons.arrow_upward,
    };
  }

  // ══════════════════════════════════════════
  // ── BUILD ──
  // ══════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topPad = MediaQuery.of(context).padding.top;
    final alertRoute = widget.incomingRoute;
    final hasBottomPanel = _searchRoute != null || alertRoute != null;

    return Stack(
      children: [
        // ── Google Map ──
        GoogleMap(
          initialCameraPosition:
              CameraPosition(target: _currentPosition, zoom: 15),
          onMapCreated: (c) {
            _mapController = c;
            setState(() => _mapReady = true);
            unawaited(_drawAlertRoute());
          },
          markers: _markers,
          polylines: _polylines,
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          compassEnabled: _isNavigating,
          onTap: (_) {
            _searchFocus.unfocus();
            if (_showSuggestions) setState(() => _showSuggestions = false);
          },
        ),

        // ── Loading overlay ──
        if (!_mapReady)
          Container(
            color: GuardianTheme.surface,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: GuardianTheme.primaryOrange.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Loading Map...',
                      style: TextStyle(
                          color: GuardianTheme.textSecondary, fontSize: 15)),
                ],
              ),
            ),
          ),

        // ── Search bar + autocomplete ──
        Positioned(
          top: topPad + 12,
          left: 16,
          right: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSearchBar(theme),
              if (_showSuggestions && _suggestions.isNotEmpty)
                _buildSuggestions(theme),
            ],
          ),
        ),

        // ── Navigation banner (top, during nav mode) ──
        if (_isNavigating && _searchRoute != null)
          Positioned(
            top: topPad + 80,
            left: 16,
            right: 16,
            child: _buildNavigationBanner(theme),
          ),

        // ── FABs ──
        if (!_showSuggestions)
          Positioned(
            right: 16,
            bottom: hasBottomPanel ? 300 : 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'reportHazard',
                  onPressed: widget.onReportHazard,
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 4,
                  child: const Icon(Icons.warning_amber_rounded),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.small(
                  heroTag: 'myLocation',
                  onPressed: () => _mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(_currentPosition, 16)),
                  backgroundColor: Colors.white,
                  foregroundColor: theme.colorScheme.primary,
                  elevation: 4,
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ),

        // ── Route panel (search route) ──
        if (_searchRoute != null && alertRoute == null)
          _buildRoutePanel(theme),

        // ── Alert route card ──
        if (alertRoute != null) _buildAlertRouteCard(theme, alertRoute),
      ],
    );
  }

  // ══════════════════════════════════════════
  // ── BUILD HELPERS ──
  // ══════════════════════════════════════════

  Widget _buildSearchBar(ThemeData theme) {
    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        child: Row(
          children: [
            const Icon(Icons.search,
                color: GuardianTheme.textSecondary, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Where are you heading?',
                  hintStyle: TextStyle(
                      color: GuardianTheme.textSecondary, fontSize: 15),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
                style: const TextStyle(fontSize: 15),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _onSearchSubmitted(),
              ),
            ),
            if (_resolvingRoute)
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else if (_loadingSuggestions)
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else if (_searchCtrl.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  _clearSearchRoute();
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close,
                      color: GuardianTheme.textSecondary, size: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestions(ThemeData theme) {
    if (_loadingSuggestions && _suggestions.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: const Row(
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text(
              'Searching places...',
              style: TextStyle(color: GuardianTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_suggestions.isEmpty && _searchCtrl.text.trim().length >= 2) {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: const Text(
          'No place suggestions found',
          style: TextStyle(color: GuardianTheme.textSecondary),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _suggestions.take(5).indexed.map((entry) {
          final (i, place) = entry;
          return Column(
            children: [
              InkWell(
                onTap: () => _selectPlace(place),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: GuardianTheme.accentBlue
                              .withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.place_outlined,
                            color: GuardianTheme.accentBlue, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(place.mainText,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14)),
                            if (place.secondaryText.isNotEmpty)
                              Text(place.secondaryText,
                                  style: const TextStyle(
                                      color: GuardianTheme.textSecondary,
                                      fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      const Icon(Icons.north_west,
                          color: GuardianTheme.textSecondary, size: 16),
                    ],
                  ),
                ),
              ),
              if (i < _suggestions.take(5).length - 1)
                Divider(
                    height: 1,
                    indent: 62,
                    color: Colors.grey.shade200),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRoutePanel(ThemeData theme) {
    final route = _searchRoute!;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, -4)),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),

              // Destination header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color:
                            GuardianTheme.accentBlue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.place,
                          color: GuardianTheme.accentBlue, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(route.destinationName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17)),
                          if (route.destinationAddress.isNotEmpty)
                            Text(route.destinationAddress,
                                style: const TextStyle(
                                    color: GuardianTheme.textSecondary,
                                    fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        _clearSearchRoute();
                        _searchCtrl.clear();
                      },
                      icon: const Icon(Icons.close, size: 20),
                      style: IconButton.styleFrom(
                          backgroundColor: Colors.grey.shade100),
                    ),
                  ],
                ),
              ),

              // Stats row
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(
                  children: [
                    _StatChip(
                        icon: Icons.timer_outlined,
                        label: '${route.durationMinutes} min',
                        color: GuardianTheme.accentBlue),
                    const SizedBox(width: 10),
                    _StatChip(
                        icon: Icons.straighten,
                        label:
                            '${route.distanceKm.toStringAsFixed(1)} km',
                        color: GuardianTheme.success),
                    const SizedBox(width: 10),
                    _StatChip(
                        icon: Icons.directions_car,
                        label: 'Driving',
                        color: GuardianTheme.textSecondary),
                  ],
                ),
              ),

              // Route steps preview (max 3)
              if (route.steps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Column(
                    children: route.steps
                        .take(3)
                        .map((step) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: GuardianTheme.accentBlue
                                          .withValues(alpha: 0.08),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                        _maneuverIcon(step.maneuver),
                                        size: 16,
                                        color: GuardianTheme.accentBlue),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(step.instruction,
                                          style: const TextStyle(
                                              fontSize: 13),
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis)),
                                  Text(step.distanceText,
                                      style: const TextStyle(
                                          color:
                                              GuardianTheme.textSecondary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ),

              if (route.steps.length > 3)
                Padding(
                  padding: const EdgeInsets.only(left: 20, top: 2),
                  child: GestureDetector(
                    onTap: () => _showAllSteps(context, route.steps),
                    child: Text(
                        'View all ${route.steps.length} steps  \u2192',
                        style: const TextStyle(
                            color: GuardianTheme.accentBlue,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ),
                ),

              // Action buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isNavigating
                            ? _endNavigation
                            : () => _focusRoute(route.points),
                        icon: Icon(
                            _isNavigating
                                ? Icons.close
                                : Icons.fit_screen,
                            size: 18),
                        label: Text(
                            _isNavigating ? 'End Nav' : 'Overview'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            _isNavigating ? null : _startNavigation,
                        icon: const Icon(Icons.navigation, size: 18),
                        label: const Text('Navigate'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAllSteps(BuildContext context, List<_RouteStep> steps) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.route, color: GuardianTheme.accentBlue),
                      const SizedBox(width: 10),
                      Text('Route Steps (${steps.length})',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 18)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: steps.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: Colors.grey.shade200),
                    itemBuilder: (_, i) {
                      final step = steps[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: GuardianTheme.accentBlue
                                    .withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                  _maneuverIcon(step.maneuver),
                                  color: GuardianTheme.accentBlue,
                                  size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(step.instruction,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500)),
                                  const SizedBox(height: 4),
                                  Text(
                                      '${step.distanceText} \u2022 ${step.durationText}',
                                      style: const TextStyle(
                                          color:
                                              GuardianTheme.textSecondary,
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('${i + 1}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: GuardianTheme.textSecondary)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildNavigationBanner(ThemeData theme) {
    final route = _searchRoute;
    if (route == null || route.steps.isEmpty) return const SizedBox.shrink();
    final step = route.steps.first;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: GuardianTheme.accentBlue,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_maneuverIcon(step.maneuver),
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(step.instruction,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(
                      '${route.distanceKm.toStringAsFixed(1)} km \u2022 ${route.durationMinutes} min remaining',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertRouteCard(ThemeData theme, AlertRoute route) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.deepOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child:
                        const Icon(Icons.route, color: Colors.deepOrange, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _resolvingAlertRoute
                              ? 'Resolving optimal route...'
                              : 'Help Route',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${route.distanceKm.toStringAsFixed(1)} km \u2022 ~${route.estimatedMinutes} min',
                          style: const TextStyle(
                              color: GuardianTheme.textSecondary,
                              fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final waypoints = route.waypoints
                            .map((wp) => LatLng(wp.lat, wp.lng))
                            .toList();
                        _focusRoute(waypoints);
                      },
                      icon: const Icon(Icons.fit_screen, size: 18),
                      label: const Text('Focus Route'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        final dest = route.waypoints.last;
                        _searchCtrl.text = 'Rider in Need';
                        _buildRouteToCoordinates(
                          destination: LatLng(dest.lat, dest.lng),
                          name: 'Rider in Need',
                          address:
                              '${dest.lat.toStringAsFixed(4)}, ${dest.lng.toStringAsFixed(4)}',
                        );
                      },
                      icon: const Icon(Icons.navigation, size: 18),
                      label: const Text('Navigate'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════
// ── Private Models ──
// ══════════════════════════════════════════

class _DirectionsResult {
  const _DirectionsResult({
    required this.points,
    required this.steps,
    required this.distanceKm,
    required this.durationMinutes,
    this.destinationAddress = '',
  });

  final List<LatLng> points;
  final List<_RouteStep> steps;
  final double distanceKm;
  final int durationMinutes;
  final String destinationAddress;
}

class _FullRoute {
  const _FullRoute({
    required this.points,
    required this.steps,
    required this.distanceKm,
    required this.durationMinutes,
    required this.destinationName,
    required this.destinationAddress,
    required this.destinationLatLng,
  });

  final List<LatLng> points;
  final List<_RouteStep> steps;
  final double distanceKm;
  final int durationMinutes;
  final String destinationName;
  final String destinationAddress;
  final LatLng destinationLatLng;
}

class _RouteStep {
  const _RouteStep({
    required this.instruction,
    required this.distanceText,
    required this.distanceMeters,
    required this.durationText,
    required this.startLocation,
    required this.endLocation,
    required this.maneuver,
  });

  final String instruction;
  final String distanceText;
  final double distanceMeters;
  final String durationText;
  final LatLng startLocation;
  final LatLng endLocation;
  final String maneuver;
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        ],
      ),
    );
  }
}
