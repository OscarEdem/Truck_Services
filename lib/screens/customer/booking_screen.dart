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
    final types = [
      ('bike', 'Bike', Icons.two_wheeler_rounded, 'Max 20kg'),
      ('van', 'Van', Icons.local_shipping_rounded, 'Max 500kg'),
      ('truck', 'Truck', Icons.fire_truck_rounded, 'Max 2000kg'),
    ];

    return Row(
      children: types.map((item) {
        final key = item.$1;
        final name = item.$2;
        final icon = item.$3;
        final cap = item.$4;
        final isSelected = _vehicle == key;

        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _vehicle = key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: const Color(0xFF2563EB).withOpacity(0.18),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 26,
                    color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: isSelected ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    cap,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPickup = _pickupCtl.text.trim().isNotEmpty;
    final hasDrop = _dropCtl.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'Book a Delivery',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            // ---------- LOCATION ROUTE CARD ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            const Text(
              'Locations',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2563EB),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 2,
                        height: 26,
                        color: const Color(0xFF93C5FD),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: const Color(0xFF4F46E5),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => _pickOnMap(isPickup: true),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'PICKUP LOCATION',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF2563EB),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  hasPickup ? _pickupCtl.text : 'Tap to select pickup location',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: hasPickup ? FontWeight.w700 : FontWeight.w500,
                                    color: hasPickup ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 12, thickness: 1, color: Color(0xFFF1F5F9)),
                        InkWell(
                          onTap: () => _pickOnMap(isPickup: false),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'DROP-OFF DESTINATION',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF4F46E5),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  hasDrop ? _dropCtl.text : 'Tap to select destination',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: hasDrop ? FontWeight.w700 : FontWeight.w500,
                                    color: hasDrop ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ---------- VEHICLE TYPE SELECTION ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            const Text(
              'Vehicle',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 10),
            _vehicleSegmented(),

            const SizedBox(height: 24),

            // ---------- LOADERS SECTION ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            const Text(
              'Loaders',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.groups_2_rounded,
                          color: Color(0xFF2563EB),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Need loaders for your item?',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      Switch.adaptive(
                        value: _needsLoaders,
                        activeColor: const Color(0xFF2563EB),
                        onChanged: (v) => setState(() => _needsLoaders = v),
                      ),
                    ],
                  ),
                  if (_needsLoaders) ...[
                    const Divider(height: 20, thickness: 1, color: Color(0xFFF1F5F9)),
                    Row(
                      children: [
                        const Text(
                          'Loader Count',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () {
                            if (_loaderCount > 1) {
                              setState(() => _loaderCount--);
                            }
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.remove_rounded, size: 18, color: Color(0xFF0F172A)),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Text(
                            '$_loaderCount',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF2563EB),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => setState(() => _loaderCount++),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.add_rounded, size: 18, color: Color(0xFF0F172A)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'GH₵ ${_vehicleLoaderRate(_vehicle).toStringAsFixed(0)} per loader',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 32),

            // ---------- GRADIENT CTA BUTTON ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            Container(
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(27),
                gradient: const LinearGradient(
                  colors: [Color(0xFF3D5AFE), Color(0xFF2563EB)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withOpacity(0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _onBookPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(27),
                  ),
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 22),
                label: Text(
                  _busy ? 'PROCESSING...' : 'BOOK DELIVERY NOW',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: Colors.white,
                    letterSpacing: 0.5,
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
