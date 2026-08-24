// lib/screens/booking_flow_screen.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:cargomate_v3/screens/customer/delivery_review_screen.dart';
import 'package:flutter/material.dart';

// 🗺️ OSM via flutter_map
import 'package:latlong2/latlong.dart';

import 'map_picker_screen.dart'; // returns {address, lat, lng}
import 'package:cargomate_v3/services/directions_service.dart';

/// Small route observer to see pushes/pops in logs
final RouteObserver<PageRoute<dynamic>> routeLoggerObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Formats useful info about the current navigation context
String _navInfo(BuildContext context) {
  final nav = Navigator.maybeOf(context);
  final canPop = nav?.canPop() ?? false;
  final route = ModalRoute.of(context);
  final routeName = route?.settings.name ?? '<unnamed>';
  return 'nav=${nav.hashCode} canPop=$canPop route=$route ($routeName)';
}

/// Safe push that logs before/after and catches “no route found” style errors
Future<T?> _safeRootPush<T>(BuildContext context, Widget page) async {
  debugPrint(
    '[NAV] will push page=${page.runtimeType} via rootNavigator '
    'ctx=${context.hashCode} ${_navInfo(context)}',
  );

  try {
    final result = await Navigator.of(context, rootNavigator: true).push<T>(
      MaterialPageRoute<T>(
        builder: (_) => page,
        settings: const RouteSettings(name: 'MaterialPageRoute'),
      ),
    );
    debugPrint('[NAV] did pop page=${page.runtimeType} result=$result');
    return result;
  } catch (e, st) {
    debugPrint('[NAV][ERROR] push failed for page=${page.runtimeType}: $e');
    debugPrint(st.toString());
    if (context.mounted) {
      _snack(context, 'Navigation error: $e');
    }
    rethrow;
  }
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );
}

/// ─────────────────────────────────────────────────────────────────────────
/// STEP 1: BOOKING (choose pickup/drop + vehicle + loaders)
/// ─────────────────────────────────────────────────────────────────────────
class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> with RouteAware {
  final _pickupCtl = TextEditingController();
  final _dropCtl = TextEditingController();

  LatLng? _pickupPos;
  LatLng? _dropPos;
  String _vehicle = 'bike';
  bool _busy = false;

  // 👇 loaders options
  bool _needsLoaders = false;
  int _loaderCount = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeLoggerObserver.subscribe(this, route);
    }
    debugPrint('[BOOK] didChangeDependencies: ${_navInfo(context)}');
  }

  @override
  void dispose() {
    debugPrint('[BOOK] dispose');
    routeLoggerObserver.unsubscribe(this);
    _pickupCtl.dispose();
    _dropCtl.dispose();
    super.dispose();
  }

  @override
  void didPush() => debugPrint('[ROUTE] BookingScreen didPush');
  @override
  void didPop() => debugPrint('[ROUTE] BookingScreen didPop');
  @override
  void didPopNext() =>
      debugPrint('[ROUTE] BookingScreen didPopNext (returned to)');
  @override
  void didPushNext() =>
      debugPrint('[ROUTE] BookingScreen didPushNext (moved away)');

  Future<void> _pickOnMap({required bool isPickup}) async {
    debugPrint(
      '[BOOK] _pickOnMap(isPickup=$isPickup) start ${_navInfo(context)}',
    );
    final res = await _safeRootPush<Map<String, dynamic>?>(
      context,
      MapPickerScreen(mode: isPickup ? 'pickup' : 'drop'),
    );
    debugPrint('[BOOK] _pickOnMap got res=$res');

    if (res is Map) {
      final address = (res!['address'] ?? '').toString();
      final lat = (res['lat'] as num?)?.toDouble();
      final lng = (res['lng'] as num?)?.toDouble();

      if (address.isNotEmpty && lat != null && lng != null) {
        if (!mounted) return;
        setState(() {
          if (isPickup) {
            _pickupCtl.text = address;
            _pickupPos = LatLng(lat, lng);
          } else {
            _dropCtl.text = address;
            _dropPos = LatLng(lat, lng);
          }
        });
        debugPrint('[BOOK] set state pickup=$_pickupPos drop=$_dropPos');
      } else {
        debugPrint('[BOOK][WARN] invalid picker payload: $res');
      }
    }
  }

  // ---------- Non-null bridge for onPressed (avoids VoidCallback? issues)
  void _onBookPressed() {
    debugPrint('[BOOK] onBookPressed busy=$_busy ${_navInfo(context)}');
    if (_busy) return; // internal disable
    _proceedToReview();
  }

  /// Haversine distance in KM (fallback if Directions API fails)
  double _haversineKm(LatLng a, LatLng b) {
    const earthRadiusKm = 6371.0;
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);

    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadiusKm * c;
  }

  double _deg2rad(double deg) => deg * math.pi / 180.0;

  double _vehicleBaseRate(String vehicle) {
    switch (vehicle) {
      case 'truck':
        return 15.0;
      case 'van':
        return 8.0;
      default:
        return 5.0; // bike
    }
  }

  double _vehicleLoaderRate(String vehicle) {
    // per-loader fee; tune as needed
    switch (vehicle) {
      case 'truck':
        return 30.0;
      case 'van':
        return 20.0;
      default:
        return 10.0; // bike
    }
  }

  Future<void> _proceedToReview() async {
    debugPrint(
      '[BOOK] _proceedToReview start pickup=$_pickupPos drop=$_dropPos',
    );

    if (_pickupPos == null || _dropPos == null) {
      _snack(context, 'Please choose pickup and drop locations');
      debugPrint('[BOOK] blocked: missing pickup/drop');
      return;
    }

    setState(() => _busy = true);
    try {
      List<LatLng> routePoints = const <LatLng>[];
      double distanceKm;
      bool usingFallback = false;

      try {
        debugPrint('[BOOK] calling DirectionsService.routePolyline...');
        final dir = await DirectionsService.routePolyline(
          origin: _pickupPos!,
          destination: _dropPos!,
        );
        distanceKm = dir.distanceKm;
        routePoints = dir.points; // List<LatLng> from latlong2
        debugPrint(
          '[BOOK] route OK, distanceKm=$distanceKm, points=${routePoints.length}',
        );
      } catch (e, st) {
        // Fallback: estimated distance + straight polyline
        usingFallback = true;
        distanceKm = _haversineKm(_pickupPos!, _dropPos!);
        routePoints = <LatLng>[_pickupPos!, _dropPos!];
        debugPrint('[BOOK][WARN] Directions failed: $e');
        debugPrint(st.toString());
        if (mounted) {
          _snack(context, 'Could not fetch route; using estimated distance.');
        }
      }

      // Guard against zero distance due to identical points / rounding
      if (distanceKm <= 0) {
        distanceKm = 1.0; // minimal distance to avoid zero pricing
        debugPrint('[BOOK][WARN] distanceKm<=0, forcing to 1.0km');
      }

      final baseRate = _vehicleBaseRate(_vehicle);
      final baseAmount = distanceKm * baseRate;

      final loaderRate = _vehicleLoaderRate(_vehicle);
      final loadersFee = _needsLoaders ? (_loaderCount * loaderRate) : 0.0;

      final total = (baseAmount + loadersFee).round(); // total as int

      debugPrint(
        '[BOOK] price: base=$baseAmount loaders=$loadersFee total=$total '
        'vehicle=$_vehicle km=$distanceKm fallback=$usingFallback',
      );

      if (!mounted) return;
      debugPrint('[BOOK] pushing _DeliveryReviewScreen...');
      final reviewResult = await _safeRootPush<Map<String, dynamic>?>(
        context,
        DeliveryReviewScreen(
          delivery: {
            // not yet in DB — we insert after successful payment
            'pickup_address': _pickupCtl.text.trim(),
            'drop_address': _dropCtl.text.trim(),
            'pickup_lat': _pickupPos!.latitude,
            'pickup_lng': _pickupPos!.longitude,
            'drop_lat': _dropPos!.latitude,
            'drop_lng': _dropPos!.longitude,
            'vehicle_type': _vehicle,
            'distance_km': distanceKm,
            'used_fallback': usingFallback,
            // 👇 pricing breakdown
            'price_base': baseAmount,
            'loaders_fee': loadersFee,
            'needs_loaders': _needsLoaders,
            'loaders_count': _needsLoaders ? _loaderCount : 0,
            'price': total, // total
            // meta
            'status': 'pending',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
          polyline: routePoints,
        ),
      );

      debugPrint('[BOOK] returned from review with $reviewResult');
      if (!mounted) return;
      if (reviewResult != null) {
        _snack(context, 'Delivery created (ID: ${reviewResult['id']})');
        debugPrint('[BOOK] popping BookingScreen with result...');
        Navigator.pop(context, reviewResult); // bubble up if needed
      }
    } catch (e, st) {
      debugPrint('[BOOK][ERROR] $e');
      debugPrint(st.toString());
      if (mounted) _snack(context, 'Error: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      debugPrint('[BOOK] _proceedToReview done');
    }
  }

  Widget _vehicleSegmented() {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment<String>(
          value: 'bike',
          label: Text('Bike'),
          icon: Icon(Icons.pedal_bike),
        ),
        ButtonSegment<String>(
          value: 'van',
          label: Text('Van'),
          icon: Icon(Icons.local_shipping_outlined),
        ),
        ButtonSegment<String>(
          value: 'truck',
          label: Text('Truck'),
          icon: Icon(Icons.fire_truck_outlined),
        ),
      ],
      selected: {_vehicle},
      onSelectionChanged: (s) => setState(() => _vehicle = s.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[BOOK] build ${_navInfo(context)}');
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Book a Delivery'), centerTitle: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          children: [
            // Pickers
            Text('Locations', style: textTheme.titleMedium),
            const SizedBox(height: 8),

            // Pickup (readonly TextField – opens map)
            TextField(
              controller: _pickupCtl,
              readOnly: true,
              onTap: () => _pickOnMap(isPickup: true),
              decoration: InputDecoration(
                labelText: 'Pickup',
                hintText: 'Choose on map',
                prefixIcon: const Icon(Icons.place_outlined),
                suffixIcon: IconButton(
                  tooltip: 'Pick on map',
                  onPressed: () => _pickOnMap(isPickup: true),
                  icon: const Icon(Icons.map_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Drop (readonly)
            TextField(
              controller: _dropCtl,
              readOnly: true,
              onTap: () => _pickOnMap(isPickup: false),
              decoration: InputDecoration(
                labelText: 'Drop',
                hintText: 'Choose on map',
                prefixIcon: const Icon(Icons.flag_outlined),
                suffixIcon: IconButton(
                  tooltip: 'Pick on map',
                  onPressed: () => _pickOnMap(isPickup: false),
                  icon: const Icon(Icons.map_outlined),
                ),
              ),
            ),

            const SizedBox(height: 20),
            Text('Vehicle', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            _vehicleSegmented(),

            const SizedBox(height: 20),
            Text('Loaders', style: textTheme.titleMedium),
            const SizedBox(height: 8),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Need loaders?'),
              value: _needsLoaders,
              onChanged: (v) => setState(() => _needsLoaders = v),
              secondary: const Icon(Icons.groups_2_outlined),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: !_needsLoaders
                  ? const SizedBox.shrink()
                  : Row(
                      key: const ValueKey('loaders-row'),
                      children: [
                        const Text('Count', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 12),
                        FilledButton.tonalIcon(
                          onPressed: () {
                            if (_loaderCount > 1) {
                              setState(() => _loaderCount--);
                            }
                          },
                          icon: const Icon(Icons.remove),
                          label: const Text(''),
                          style: const ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(Size(40, 40)),
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Chip(
                            label: Text('$_loaderCount'),
                            avatar: const Icon(Icons.badge_outlined),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => setState(() => _loaderCount++),
                          icon: const Icon(Icons.add),
                          label: const Text(''),
                          style: const ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(Size(40, 40)),
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'GHS ${_vehicleLoaderRate(_vehicle).toStringAsFixed(0)} each',
                          style: textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
            ),

            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _onBookPressed,
              icon: const Icon(Icons.check),
              label: const Text('Book delivery'),
            ),
          ],
        ),
      ),
    );
  }
}
