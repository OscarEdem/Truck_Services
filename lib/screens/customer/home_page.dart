// lib/screens/customer/home_page.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Map & location
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:geolocator/geolocator.dart';
import '../../services/directions_service.dart' as dirs;

import '../../routes/navRoutes.dart';
import '../../services/estimation_service.dart' as est; // estimator alias
import '../../services/delivery_helpers.dart';
import '../../screens/signature_screen.dart';
import '../../widgets/widgets.dart'; // for EmptyPlaceholder/ErrorPlaceholder if you use them

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

// UI enum only; mapped to estimator enum below
enum VehicleType { bike, van, truck }

class _HomePageState extends State<HomePage> {
  final _pickupCtrl = TextEditingController();
  final _dropoffCtrl = TextEditingController();
  VehicleType _vehicle = VehicleType.bike;

  // loaders UI (only for Cargo/Freight)
  bool _needsLoaders = false;
  int _loaderCount = 1;

  bool _loadingPrice = false;
  String? _quotedPrice;

  // route drawing
  List<ll.LatLng> _routePoints = const [];
  // ignore: unused_field
  bool _routeLoading = false;
  bool _routeFromFallback = false;

  // coords from map picker
  double? _pLat, _pLng, _dLat, _dLng;
  est.FareQuote? _quoteObj;

  // planned (kept for your schedule flow)
  DateTime? _plannedAt;

  // Scaffold / Drawer
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Map / Location
  final MapController _map = MapController();
  ll.LatLng? _userLatLng;
  bool _locating = false;

  String _fmtGhs(num v) => 'GHS ${v.toStringAsFixed(0)}';

  double? _baseEstimateGhs() {
    // Prefer estimator output if available
    if (_quoteObj?.priceCents != null) {
      return _quoteObj!.priceCents / 100.0;
    }
    // Otherwise compute from distance * vehicle rate when coords exist
    if (_pLat != null && _pLng != null && _dLat != null && _dLng != null) {
      final km =
          _quoteObj?.distanceKm ??
          _haversineKm(ll.LatLng(_pLat!, _pLng!), ll.LatLng(_dLat!, _dLng!));
      final rate = _vehicleBaseRate(_vehicle);
      return km * rate;
    }
    return null;
  }

  double _currentLoadersFee() {
    if (!(_vehicle == VehicleType.van || _vehicle == VehicleType.truck)) {
      return 0.0;
    }
    if (!_needsLoaders) return 0.0;
    return _loaderCount * _vehicleLoaderRate(_vehicle);
  }

  @override
  void initState() {
    super.initState();
    _locateMe(initial: true);
  }

  @override
  void dispose() {
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    super.dispose();
  }

  // ===== helpers (rates, distance fallback) =====

  double _vehicleBaseRate(VehicleType v) {
    switch (v) {
      case VehicleType.truck:
        return 15.0;
      case VehicleType.van:
        return 8.0;
      case VehicleType.bike:
        return 5.0;
    }
  }

  double _vehicleLoaderRate(VehicleType v) {
    switch (v) {
      case VehicleType.truck:
        return 30.0;
      case VehicleType.van:
        return 20.0;
      case VehicleType.bike:
        return 10.0;
    }
  }

  double _deg2rad(double deg) => deg * math.pi / 180.0;

  /// Haversine distance in KM (fallback if routing/quote not available)
  double _haversineKm(ll.LatLng a, ll.LatLng b) {
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

  // ====== ROUTE (polyline) ======
  Future<void> _computeRoute() async {
    if (_pLat == null || _pLng == null || _dLat == null || _dLng == null) {
      return;
    }
    setState(() {
      _routeLoading = true;
      _routePoints = const [];
      _routeFromFallback = false;
    });
    try {
      final res = await dirs.DirectionsService.routePolyline(
        origin: ll.LatLng(_pLat!, _pLng!),
        destination: ll.LatLng(_dLat!, _dLng!),
        profile: 'driving',
        preferPolyline6: true,
        fallbackAvgSpeedKph: 30,
      );
      setState(() {
        _routePoints = res.points
            .map((p) => ll.LatLng(p.latitude, p.longitude))
            .toList();
        _routeFromFallback = res.fromFallback;
      });
    } catch (_) {
      // fallback to straight line if remote fails
      setState(() {
        _routePoints = [ll.LatLng(_pLat!, _pLng!), ll.LatLng(_dLat!, _dLng!)];
        _routeFromFallback = true;
      });
    } finally {
      if (mounted) setState(() => _routeLoading = false);
    }
  }

  // ===== Location helpers =====
  Future<void> _locateMe({bool initial = false}) async {
    try {
      setState(() => _locating = true);
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        setState(() => _locating = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _userLatLng = ll.LatLng(pos.latitude, pos.longitude);
      setState(() {});
      if (initial) {
        _map.move(_userLatLng!, 14);
      } else {
        _map.move(_userLatLng!, _map.camera.zoom);
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fitRouteIfReady() {
    if (_pLat == null || _dLat == null) return;
    final bounds = LatLngBounds.fromPoints([
      ll.LatLng(_pLat!, _pLng!),
      ll.LatLng(_dLat!, _dLng!),
    ]);
    _map.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(32, 120, 32, 32),
      ),
    );
  }

  // ===== Vehicle selector =====
  void _selectVehicle(VehicleType vt) {
    setState(() {
      _vehicle = vt;
      // Only show loaders for Cargo (van) & Freight (truck)
      if (_vehicle == VehicleType.bike) {
        _needsLoaders = false;
        _loaderCount = 1;
      }
    });
    _recalcDisplayedQuote();
  }

  // ===== Pickers (with explicit mode) =====
  Future<void> _onPick(bool isPickup) async {
    final res = await Navigator.pushNamed(
      context,
      NavRoutes.mapPicker,
      arguments: {'mode': isPickup ? 'pickup' : 'drop'},
    );
    if (res is Map) {
      final addr = (res['address'] ?? '').toString();
      final lat = (res['lat'] as num?)?.toDouble();
      final lng = (res['lng'] as num?)?.toDouble();

      setState(() {
        if (isPickup) {
          _pickupCtrl.text = addr;
          _pLat = lat;
          _pLng = lng;
        } else {
          _dropoffCtrl.text = addr;
          _dLat = lat;
          _dLng = lng;
        }
      });

      if (_pLat != null && _dLat != null) {
        _fitRouteIfReady();
        await _computeRoute();
      } else if (lat != null && lng != null) {
        _map.move(ll.LatLng(lat, lng), 14);
      }
    }
    _recalcDisplayedQuote();
  }

  // ===== Estimation & booking =====
  est.VehicleType _toEstVehicle(VehicleType v) {
    switch (v) {
      case VehicleType.bike:
        return est.VehicleType.bike;
      case VehicleType.van:
        return est.VehicleType.van;
      case VehicleType.truck:
        return est.VehicleType.truck;
    }
  }

  Future<void> _estimatePrice() async {
    if (_pickupCtrl.text.trim().isEmpty || _dropoffCtrl.text.trim().isEmpty) {
      _snack('Enter pickup & dropoff to estimate price');
      return;
    }
    if (_pLat == null || _dLat == null) {
      _snack('Pick locations on the map to get distance-based quote');
      return;
    }
    setState(() {
      _loadingPrice = true;
      _quotedPrice = null;
      _quoteObj = null;
    });

    await Future.delayed(const Duration(milliseconds: 200)); // spinner

    // estimate() returns a FareQuote
    final q = est.EstimationService.estimate(
      vehicle: _toEstVehicle(_vehicle),
      pickupLat: _pLat!,
      pickupLng: _pLng!,
      dropLat: _dLat!,
      dropLng: _dLng!,
    );
    setState(() {
      _loadingPrice = false;
      _quoteObj = q;
    });
    _recalcDisplayedQuote();
  }

  void _recalcDisplayedQuote() {
    final base = _baseEstimateGhs();
    if (base == null) {
      setState(() => _quotedPrice = null);
      return;
    }
    final total = base + _currentLoadersFee();
    setState(() => _quotedPrice = _fmtGhs(total));
  }

  void _startBooking() {
    // Guard
    if (_pickupCtrl.text.trim().isEmpty || _dropoffCtrl.text.trim().isEmpty) {
      _snack('Enter pickup & dropoff first');
      return;
    }
    if (_pLat == null || _pLng == null || _dLat == null || _dLng == null) {
      _snack('Choose locations on the map');
      return;
    }

    // Distance: prefer estimator’s distance, else haversine
    double distanceKm;
    if (_quoteObj?.distanceKm != null && _quoteObj!.distanceKm > 0) {
      distanceKm = _quoteObj!.distanceKm;
    } else {
      distanceKm = _haversineKm(
        ll.LatLng(_pLat!, _pLng!),
        ll.LatLng(_dLat!, _dLng!),
      );
      if (distanceKm <= 0) distanceKm = 1.0;
    }

    // Base price from simple rate table (aligns with BookingScreen)
    final baseRate = _vehicleBaseRate(_vehicle);
    final baseAmount = distanceKm * baseRate;

    // Loaders fee only for Cargo/Freight (UI limited already)
    final loaderRate = _vehicleLoaderRate(_vehicle);
    final loadersFee = _needsLoaders ? (_loaderCount * loaderRate) : 0.0;

    // If you want to prefer estimator’s cents as base when present, you could:
    // final double? estimatorGhs =
    //     _quoteObj?.priceCents != null ? _quoteObj!.priceCents / 100.0 : null;
    // final baseAmount = estimatorGhs ?? (distanceKm * baseRate);

    final totalInt = (baseAmount + loadersFee).round();

    // Build delivery map (like BookingScreen)
    final delivery = <String, dynamic>{
      'pickup_address': _pickupCtrl.text.trim(),
      'drop_address': _dropoffCtrl.text.trim(),
      'pickup_lat': _pLat!,
      'pickup_lng': _pLng!,
      'drop_lat': _dLat!,
      'drop_lng': _dLng!,
      'vehicle_type': _vehicle.name, // 'bike' | 'van' | 'truck'
      'distance_km': distanceKm,
      'used_fallback': _routeFromFallback,
      // pricing breakdown
      'price_base': baseAmount,
      'loaders_fee': loadersFee,
      'needs_loaders': _needsLoaders,
      'loaders_count': _needsLoaders ? _loaderCount : 0,
      'price': totalInt, // final total as int
      // meta
      'status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'planned_at': _plannedAt?.toIso8601String(),
    };

    // Provide polyline as simple list for the named route
    final polyline = _routePoints
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(growable: false);

    Navigator.pushNamed(
      context,
      NavRoutes.deliveryReview,
      arguments: {'delivery': delivery, 'polyline': polyline},
    );
    debugPrint(
      '[HOME] delivery keys=${delivery.keys} polyLen=${polyline.length}',
    );
  }

  Future<void> _repeatLast() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return _snack('Sign in to use Repeat');
    final q = await FirebaseFirestore.instance
        .collection('deliveries')
        .where('sender_id', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return _snack('No previous deliveries yet');

    final d = q.docs.first.data();
    setState(() {
      _pickupCtrl.text = (d['pickup_address'] ?? '').toString();
      _dropoffCtrl.text = (d['drop_address'] ?? '').toString();
      _pLat = (d['pickup_lat'] as num?)?.toDouble();
      _pLng = (d['pickup_lng'] as num?)?.toDouble();
      _dLat = (d['drop_lat'] as num?)?.toDouble();
      _dLng = (d['drop_lng'] as num?)?.toDouble();
      _vehicle = switch ((d['vehicle_type'] ?? 'bike').toString()) {
        'van' => VehicleType.van,
        'truck' => VehicleType.truck,
        _ => VehicleType.bike,
      };
      // loaders prefill (optional)
      _needsLoaders = (d['needs_loaders'] == true);
      _loaderCount = (d['loaders_count'] as num?)?.toInt() ?? 1;
      if (_vehicle == VehicleType.bike) {
        _needsLoaders = false;
        _loaderCount = 1;
      }
    });
    _fitRouteIfReady();
    await _computeRoute();
    _snack('Prefilled from last delivery');
  }

  Future<void> _shareLink() async {
    const text = 'Track my delivery: https://cargomate.page.link/track/DEMO123';
    await Clipboard.setData(const ClipboardData(text: text));
    _snack('Tracking link copied');
  }

  String _fmtPlanned(DateTime dt) {
    final t = TimeOfDay.fromDateTime(dt);
    final hh = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final mm = t.minute.toString().padLeft(2, '0');
    final ampm = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} • $hh:$mm $ampm';
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _go(String route) {
    if (ModalRoute.of(context)?.settings.name == route) return;
    Navigator.pushNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final canPlan =
        _pickupCtrl.text.trim().isNotEmpty &&
        _dropoffCtrl.text.trim().isNotEmpty;

    // Build markers for map
    final markers = <Marker>[
      if (_userLatLng != null)
        Marker(
          point: _userLatLng!,
          alignment: Alignment.center,
          child: const Icon(
            Icons.radio_button_checked,
            size: 28,
            color: Colors.blue,
          ),
        ),
      if (_pLat != null && _pLng != null)
        Marker(
          point: ll.LatLng(_pLat!, _pLng!),
          alignment: Alignment.bottomCenter,
          child: const Icon(Icons.room, size: 36, color: Colors.green),
        ),
      if (_dLat != null && _dLng != null)
        Marker(
          point: ll.LatLng(_dLat!, _dLng!),
          alignment: Alignment.bottomCenter,
          child: const Icon(Icons.location_on, size: 36, color: Colors.red),
        ),
    ];

    // Build polyline (prefer routed; else straight)
    final polylines = <Polyline>[
      if (_routePoints.isNotEmpty)
        Polyline(
          points: _routePoints,
          color: Theme.of(context).colorScheme.primary,
          strokeWidth: 4,
        )
      else if (_pLat != null && _dLat != null)
        Polyline(
          points: [ll.LatLng(_pLat!, _pLng!), ll.LatLng(_dLat!, _dLng!)],
          color: Theme.of(context).colorScheme.primary,
          strokeWidth: 4,
        ),
    ];

    final showLoadersSection =
        _vehicle == VehicleType.van || _vehicle == VehicleType.truck;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false, // no back button
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 15),
            Image.asset(
              'assets/icons/cargomatewhitelogo.png',
              height: 26,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            const Text(
              'cargomate',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 20,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
      endDrawer: const CustomerDrawer(),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // ===== Map header with floating address card =====
            Stack(
              children: [
                SizedBox(
                  height: 360,
                  child: FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter:
                          _userLatLng ??
                          const ll.LatLng(5.6037, -0.1870), // fallback
                      initialZoom: 12,
                      interactionOptions: const InteractionOptions(
                        flags:
                            InteractiveFlag.drag |
                            InteractiveFlag.flingAnimation |
                            InteractiveFlag.pinchZoom,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.cargomate',
                      ),
                      if (polylines.isNotEmpty)
                        PolylineLayer(polylines: polylines),
                      if (markers.isNotEmpty) MarkerLayer(markers: markers),
                    ],
                  ),
                ),
                // locate button
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    heroTag: 'locate',
                    onPressed: _locating ? null : () => _locateMe(),
                    child: _locating
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ),
                // floating address card
                Positioned(
                  left: 16,
                  right: 16,
                  top: 16,
                  child: _AddressOverlay(
                    pickupCtrl: _pickupCtrl,
                    dropoffCtrl: _dropoffCtrl,
                    onPickPickup: () => _onPick(true),
                    onPickDropoff: () => _onPick(false),
                  ),
                ),
              ],
            ),

            // ===== “Let’s move” section with vehicle tiles =====
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Text(
                "Let's move",
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _VehicleTile(
                    label: 'Parcel',
                    capacity: 'Max 50kg',
                    asset: 'assets/parcel.png',
                    selected: _vehicle == VehicleType.bike,
                    onTap: () => _selectVehicle(VehicleType.bike),
                  ),
                  _VehicleTile(
                    label: 'Cargo',
                    capacity: 'Max 1.5 Tons',
                    asset: 'assets/cargo.png',
                    selected: _vehicle == VehicleType.van,
                    onTap: () => _selectVehicle(VehicleType.van),
                  ),
                  _VehicleTile(
                    label: 'Freight',
                    capacity: 'Max 10 Tons',
                    asset: 'assets/freight.png',
                    selected: _vehicle == VehicleType.truck,
                    onTap: () => _selectVehicle(VehicleType.truck),
                  ),
                ],
              ),
            ),

            // ===== Loaders (only for Cargo / Freight) =====
            if (showLoadersSection) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Loaders',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Need loaders?'),
                      value: _needsLoaders,
                      onChanged: (v) {
                        setState(() => _needsLoaders = v);
                        _recalcDisplayedQuote();
                      },
                      secondary: const Icon(Icons.groups_2_outlined),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: !_needsLoaders
                          ? const SizedBox.shrink()
                          : Row(
                              key: const ValueKey('loaders-row'),
                              children: [
                                const Text(
                                  'Count',
                                  style: TextStyle(fontSize: 16),
                                ),
                                const SizedBox(width: 12),
                                FilledButton.tonalIcon(
                                  onPressed: () {
                                    if (_loaderCount > 1) {
                                      setState(() => _loaderCount--);
                                    }
                                    _recalcDisplayedQuote();
                                  },
                                  icon: const Icon(Icons.remove),
                                  label: const Text(''),
                                  style: const ButtonStyle(
                                    minimumSize: WidgetStatePropertyAll(
                                      Size(40, 40),
                                    ),
                                    padding: WidgetStatePropertyAll(
                                      EdgeInsets.symmetric(horizontal: 8),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Chip(
                                    label: Text('$_loaderCount'),
                                    avatar: const Icon(Icons.badge_outlined),
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: () {
                                    setState(() => _loaderCount++);
                                    _recalcDisplayedQuote();
                                  },
                                  icon: const Icon(Icons.add),
                                  label: const Text(''),
                                  style: const ButtonStyle(
                                    minimumSize: WidgetStatePropertyAll(
                                      Size(40, 40),
                                    ),
                                    padding: WidgetStatePropertyAll(
                                      EdgeInsets.symmetric(horizontal: 8),
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  'GHS ${_vehicleLoaderRate(_vehicle).toStringAsFixed(0)} each',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],

            // ===== Quote + CTA =====
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _PriceRow(
                quotedPrice: _quotedPrice,
                loading: _loadingPrice,
                onEstimate: _estimatePrice,
              ),
            ),
            if (_quotedPrice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(() {
                  final base = _baseEstimateGhs();
                  final loaders = _currentLoadersFee();
                  if (base == null) return '';
                  final parts = <String>[];
                  parts.add('Base ${_fmtGhs(base)}');
                  if (loaders > 0) parts.add('+ Loaders ${_fmtGhs(loaders)}');
                  return parts.join('  •  ');
                }(), style: Theme.of(context).textTheme.bodySmall),
              ),

            if (_quoteObj != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(
                  '≈ ${_quoteObj!.distanceKm.toStringAsFixed(2)} km • ETA ~ ${_quoteObj!.timeMin} min',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_plannedAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    label: Text('Planned: ${_fmtPlanned(_plannedAt!)}'),
                    onDeleted: () => setState(() => _plannedAt = null),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                width: double.infinity,
                height: 52,
                decoration: BoxDecoration(
                  gradient: canPlan
                      ? const LinearGradient(
                          colors: [Color(0xFF1D4ED8), Color(0xFF2563EB)],
                        )
                      : null,
                  color: canPlan ? null : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: canPlan
                      ? [
                          BoxShadow(
                            color: const Color(0xFF2563EB).withOpacity(0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          )
                        ]
                      : [],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: canPlan ? _startBooking : () => _onPick(true),
                    borderRadius: BorderRadius.circular(16),
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            canPlan ? Icons.local_shipping_rounded : Icons.add_location_alt_rounded,
                            color: canPlan ? Colors.white : const Color(0xFF64748B),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            canPlan ? 'REQUEST PICKUP NOW' : 'SELECT PICKUP ADDRESS',
                            style: TextStyle(
                              color: canPlan ? Colors.white : const Color(0xFF64748B),
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ===== Quick actions =====
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: _QuickActions(
                onSchedule: () => _go(NavRoutes.schedule),
                onRepeatLast: _repeatLast,
                onShareLink: _shareLink,
              ),
            ),

            // ===== Recent deliveries =====
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: _SectionHeader(
                title: 'Recent deliveries',
                action: 'View all',
                onTap: () => _go(NavRoutes.deliveries),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _RecentDeliveriesList(limit: 5),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: _TrustRow(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: MainBottomNav(
        currentRoute: ModalRoute.of(context)?.settings.name,
      ),
    );
  }
}

/* ---------- Header address overlay (map card) ---------- */

class _AddressOverlay extends StatelessWidget {
  final TextEditingController pickupCtrl;
  final TextEditingController dropoffCtrl;
  final VoidCallback onPickPickup;
  final VoidCallback onPickDropoff;

  const _AddressOverlay({
    required this.pickupCtrl,
    required this.dropoffCtrl,
    required this.onPickPickup,
    required this.onPickDropoff,
  });

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    );

    return Material(
      elevation: 10,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            _OverlayField(
              controller: pickupCtrl,
              hint: 'Enter pickup address',
              icon: Icons.location_pin,
              onTap: onPickPickup,
              border: border,
            ),
            const SizedBox(height: 10),
            _OverlayField(
              controller: dropoffCtrl,
              hint: 'Enter drop address',
              icon: Icons.crop_square_rounded,
              onTap: onPickDropoff,
              border: border,
            ),
          ],
        ),
      ),
    );
  }
}

class _OverlayField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final VoidCallback onTap;
  final InputBorder border;
  const _OverlayField({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.onTap,
    required this.border,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      onTap: onTap,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 12,
        ),
      ),
    );
  }
}

/* ---------- Vehicle tiles (“Let’s move”) ---------- */

class _VehicleTile extends StatelessWidget {
  final String label;
  final String capacity;
  final String asset;
  final bool selected;
  final VoidCallback onTap;

  const _VehicleTile({
    required this.label,
    required this.capacity,
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 145,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEFF6FF) : cs.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
              width: selected ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: selected ? const Color(0xFF2563EB).withOpacity(0.15) : const Color(0x0A000000),
                blurRadius: selected ? 10 : 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(child: Image.asset(asset, fit: BoxFit.contain)),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: selected ? const Color(0xFF1E40AF) : cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                capacity,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: selected ? const Color(0xFF2563EB) : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------- Quick actions / Price row / Recent deliveries (kept) ---------- */

class _PriceRow extends StatelessWidget {
  final String? quotedPrice;
  final bool loading;
  final VoidCallback onEstimate;

  const _PriceRow({
    required this.quotedPrice,
    required this.loading,
    required this.onEstimate,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: loading
                ? const Row(
                    key: ValueKey('loading'),
                    children: [
                      SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Getting price…'),
                    ],
                  )
                : Text(
                    quotedPrice == null
                        ? 'No quote yet'
                        : 'Estimated: $quotedPrice',
                    key: ValueKey(quotedPrice ?? 'none'),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: loading ? null : onEstimate,
          icon: const Icon(Icons.attach_money),
          label: const Text('Estimate'),
        ),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  final VoidCallback onSchedule;
  final VoidCallback onRepeatLast;
  final VoidCallback onShareLink;

  const _QuickActions({
    required this.onSchedule,
    required this.onRepeatLast,
    required this.onShareLink,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        _ActionPill(
          icon: Icons.event_repeat,
          label: 'Schedule',
          onTap: onSchedule,
          color: cs.surfaceContainerHighest,
        ),
        const SizedBox(width: 8),
        _ActionPill(
          icon: Icons.history,
          label: 'Repeat last',
          onTap: onRepeatLast,
          color: cs.surfaceContainerHighest,
        ),
        const SizedBox(width: 8),
        _ActionPill(
          icon: Icons.ios_share,
          label: 'Share link',
          onTap: onShareLink,
          color: cs.surfaceContainerHighest,
        ),
      ],
    );
  }
}

class _ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _ActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: color,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onTap;

  const _SectionHeader({required this.title, this.action, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (action != null) TextButton(onPressed: onTap, child: Text(action!)),
      ],
    );
  }
}

class _TrustRow extends StatelessWidget {
  const _TrustRow();

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).colorScheme.onSurfaceVariant;
    TextStyle label = Theme.of(
      context,
    ).textTheme.bodyMedium!.copyWith(color: dim);

    Widget item(IconData i, String t) => Expanded(
      child: Column(
        children: [
          Icon(i, size: 22, color: dim),
          const SizedBox(height: 6),
          Text(t, textAlign: TextAlign.center, style: label),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          item(Icons.security_outlined, 'Secure payments'),
          item(Icons.verified_outlined, 'Verified drivers'),
          item(Icons.support_agent_outlined, '24/7 support'),
        ],
      ),
    );
  }
}

class _RecentDeliveryTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onRepeat;

  const _RecentDeliveryTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.onRepeat,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        onTap: onTap,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          tooltip: 'Repeat',
          icon: const Icon(Icons.refresh),
          onPressed: onRepeat,
        ),
      ),
    );
  }
}

class _RecentDeliveriesList extends StatelessWidget {
  final int limit;
  const _RecentDeliveriesList({required this.limit});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const EmptyPlaceholder(
        title: 'Sign in to see your deliveries',
        message: 'Your recent deliveries will appear here after you book.',
      );
    }

    final q = FirebaseFirestore.instance
        .collection('deliveries')
        .where('sender_id', isEqualTo: uid)
        .limit(50)
        .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: q,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          return ErrorPlaceholder(message: 'Error: ${snap.error}');
        }

        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const EmptyPlaceholder(
            title: 'No recent deliveries',
            message: 'Book your first delivery to see it here.',
          );
        }

        List<Map<String, dynamic>> data = docs.map((d) {
          final m = {'id': d.id, ...(d.data() as Map<String, dynamic>)};
          return _normalizeDelivery(m);
        }).toList();

        data.sort((a, b) {
          final da = a['created_at_dt'] as DateTime?;
          final db = b['created_at_dt'] as DateTime?;
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });

        data = data.take(limit).toList();

        return Column(
          children: [
            for (final d in data)
              _RecentDeliveryTile(
                title:
                    '${(d['pickup_address'] ?? 'Unknown')} → ${(d['drop_address'] ?? 'Unknown')}',
                subtitle:
                    '${(d['vehicle_type'] ?? 'vehicle')} • ${(d['status'] ?? 'pending')} • ${_whenText(d['created_at_dt'] as DateTime?)}',
                onTap: () => _openDeliveryActions(context, d),
                onRepeat: () {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Rebooked!')));
                },
              ),
          ],
        );
      },
    );
  }

  static void _openDeliveryActions(
    BuildContext context,
    Map<String, dynamic> d,
  ) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final isDriver =
        (d['driver_id']?.toString() == uid) ||
        (d['biker_id']?.toString() == uid);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.call_outlined),
                  title: const Text('Call'),
                  subtitle: const Text('Confirm phones then open dialer'),
                  onTap: () async {
                    Navigator.pop(context);
                    await DeliveryHelpers.confirmAndCallCounterpart(
                      context,
                      delivery: d,
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.draw_outlined),
                  title: const Text('Sign'),
                  subtitle: const Text(
                    'Open signature and auto-complete if both signed',
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SignatureScreen(delivery: d),
                      ),
                    );
                    final id = d['id']?.toString();
                    if (id != null && id.isNotEmpty) {
                      await DeliveryHelpers.checkAutoCompleteAndMarkDelivered(
                        context,
                        deliveryDocId: id,
                      );
                    }
                  },
                ),
                if (isDriver)
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('Complete with Proof (Driver)'),
                    subtitle: const Text(
                      'Take photo, preview, upload & complete',
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      final id = d['id']?.toString();
                      if (id == null || id.isEmpty) return;
                      final pod =
                          await DeliveryHelpers.takePodWithPreviewAndUpload(
                            context,
                            deliveryId: id,
                          );
                      if (pod != null) {
                        await FirebaseFirestore.instance
                            .collection('deliveries')
                            .doc(id)
                            .update({
                              'status': 'delivered',
                              'pod_path': pod['path'],
                              'pod_url': pod['url'],
                              'delivered_at': FieldValue.serverTimestamp(),
                            });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Delivery completed')),
                        );
                      }
                    },
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('View details'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(
                      context,
                      NavRoutes.deliveryDetails,
                      arguments: d,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Map<String, dynamic> _normalizeDelivery(Map<String, dynamic> d) {
    final created = d['created_at'];
    DateTime? createdAt;
    if (created is Timestamp) {
      createdAt = created.toDate();
    } else if (created is DateTime) {
      createdAt = created;
    } else if (created is String) {
      createdAt = DateTime.tryParse(created);
    }

    String? pickup = (d['pickup_address'] as String?)?.trim();
    String? drop = (d['drop_address'] as String?)?.trim();
    if ((pickup == null || pickup.isEmpty) &&
        d['pickup_lat'] != null &&
        d['pickup_lng'] != null) {
      pickup = '${d['pickup_lat']}, ${d['pickup_lng']}';
    }
    if ((drop == null || drop.isEmpty) &&
        d['drop_lat'] != null &&
        d['drop_lng'] != null) {
      drop = '${d['drop_lat']}, ${d['drop_lng']}';
    }
    return {
      ...d,
      'pickup_address': pickup ?? 'Unknown',
      'drop_address': drop ?? 'Unknown',
      'created_at_dt': createdAt,
    };
  }

  static String _whenText(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';

    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final y = local.year.toString();
    final m = two(local.month);
    final d = two(local.day);
    final hh = two(local.hour);
    final mm = two(local.minute);
    return '$y-$m-$d $hh:$mm';
  }
}
