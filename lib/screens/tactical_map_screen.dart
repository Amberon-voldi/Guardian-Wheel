import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../controller/alert_controller.dart';
import '../service/location_service.dart';

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
  GoogleMapController? _mapController;
  StreamSubscription<LocationPoint>? _locationSub;

  LatLng _currentPosition = const LatLng(12.9716, 77.5946);
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

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
      _mapController?.animateCamera(CameraUpdate.newLatLng(_currentPosition));
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

  @override
  void didUpdateWidget(covariant TacticalMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.incomingRoute != oldWidget.incomingRoute) {
      _updateRoute();
    }
  }

  void _updateRoute() {
    _polylines.clear();
    _markers.removeWhere((m) => m.markerId.value.startsWith('route_'));

    final route = widget.incomingRoute;
    if (route != null && route.waypoints.length >= 2) {
      final points = route.waypoints
          .map((wp) => LatLng(wp.lat, wp.lng))
          .toList();

      _polylines.add(
        Polyline(
          polylineId: const PolylineId('help_route'),
          points: points,
          color: Colors.deepOrange,
          width: 4,
        ),
      );

      // Add destination marker
      final dest = points.last;
      _markers.add(
        Marker(
          markerId: const MarkerId('route_dest'),
          position: dest,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Rider in Need',
            snippet: '${route.distanceKm.toStringAsFixed(1)} km away',
          ),
        ),
      );

      // Zoom to fit route
      if (_mapController != null) {
        final bounds = LatLngBounds(
          southwest: LatLng(
            points.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
            points.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
          ),
          northeast: LatLng(
            points.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
            points.map((p) => p.longitude).reduce((a, b) => a > b ? a : b),
          ),
        );
        _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
      }
    }

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = widget.incomingRoute;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Google Map
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _currentPosition,
                zoom: 15,
              ),
              onMapCreated: (controller) {
                _mapController = controller;
                setState(() => _mapReady = true);
                _updateRoute();
              },
              markers: _markers,
              polylines: _polylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
            ),

            // Offline banner if map not ready
            if (!_mapReady)
              Container(
                color: const Color(0xFFF5F5F7),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.map_outlined, size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('Loading Map...', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ),
              ),

            // My location button
            Positioned(
              right: 12,
              bottom: route != null ? 110 : 80,
              child: FloatingActionButton.small(
                heroTag: 'myLocation',
                onPressed: () {
                  _mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(_currentPosition, 16),
                  );
                },
                backgroundColor: Colors.white,
                foregroundColor: theme.colorScheme.primary,
                child: const Icon(Icons.my_location),
              ),
            ),

            // Report hazard FAB
            Positioned(
              right: 12,
              bottom: route != null ? 160 : 130,
              child: FloatingActionButton(
                heroTag: 'reportHazard',
                onPressed: widget.onReportHazard,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add_alert),
              ),
            ),

            // Route info card
            if (route != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.route, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Help route: ${route.distanceKm.toStringAsFixed(1)} km • ${route.estimatedMinutes} min',
                            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}